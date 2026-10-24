import AVFoundation
import Foundation

/**
 * AVFoundation's side of playback: one AVQueuePlayer holding the playing
 * track and, behind it, the next one already buffering, so a track change is
 * gapless the way the phone's ExoPlayer playlist window is. The queue's rules
 * live in PlayerModel; this only plays what it's told.
 */
@MainActor
final class PlaybackEngine {
    struct Entry {
        let song: Song
        /** YouTube's own stream; still primed under a substitute, for its loudness figure and as the fallback. */
        let loader: StreamLoader
        let item: AVPlayerItem
        /** Another source's copy playing in YouTube's place (an addon's FLAC, JioSaavn's 320). */
        var substitute: SourceStream?
    }

    let player = AVQueuePlayer()
    private(set) var current: Entry?
    private(set) var upcoming: Entry?

    var onAdvance: ((Song) -> Void)?
    var onEnded: (() -> Void)?
    var onFailed: ((Song, Error?) -> Void)?
    var onStateChange: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var statusObservations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .advance
        itemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.currentItemChanged() }
        }
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.onStateChange?() }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.itemEnded(item) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as? AVPlayerItem
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated { self?.itemFailed(item, error) }
        })
    }

    var isPlaying: Bool { player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate }
    var isBuffering: Bool { player.timeControlStatus == .waitingToPlayAtSpecifiedRate }

    var position: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    var duration: TimeInterval? {
        guard let item = current?.item else { return nil }
        let seconds = item.duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /** Plays [song] from [position], dropping whatever was loaded. */
    func load(_ song: Song, at position: TimeInterval = 0, play: Bool, substitute: SourceStream? = nil) {
        clear()
        let entry = makeEntry(song, substitute: substitute)
        current = entry
        player.insert(entry.item, after: nil)
        if position > 0 {
            entry.item.seek(to: CMTime(seconds: position, preferredTimescale: 600), completionHandler: nil)
        }
        if play { player.play() } else { player.pause() }
        onStateChange?()
    }

    /** What plays after the current track; nil to stop there. Replaces a different one already buffering. */
    func setUpcoming(_ song: Song?) {
        if upcoming?.song.videoId == song?.videoId, upcoming != nil || song == nil { return }
        if let upcoming {
            player.remove(upcoming.item)
            upcoming.loader.cancelAll()
            self.upcoming = nil
        }
        guard let song, let current else { return }
        let entry = makeEntry(song)
        upcoming = entry
        player.insert(entry.item, after: current.item)
    }

    /**
     * Swaps the playing track over to [substitute] where it is (QualityUpgrade):
     * a short break in the sound, for the better copy from here on.
     */
    func swapCurrent(to substitute: SourceStream) {
        guard let current else { return }
        let position = self.position
        let playing = isPlaying
        let entry = makeEntry(current.song, substitute: substitute, loader: current.loader)
        self.current = entry
        player.replaceCurrentItem(with: entry.item)
        if let upcoming { player.insert(upcoming.item, after: entry.item) }
        if position > 0.5 {
            entry.item.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        }
        if playing { player.play() }
        onStateChange?()
    }

    /** The track after this one, from [substitute] instead of YouTube, while it hasn't started. */
    func replaceUpcoming(with substitute: SourceStream) {
        guard let upcoming, let current else { return }
        player.remove(upcoming.item)
        let entry = makeEntry(upcoming.song, substitute: substitute, loader: upcoming.loader)
        self.upcoming = entry
        player.insert(entry.item, after: current.item)
    }

    func play() {
        if current == nil { return }
        player.play()
    }

    func pause() { player.pause() }

    func seek(to seconds: TimeInterval, completion: (() -> Void)? = nil) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in completion?() }
        }
    }

    func clear() {
        player.removeAllItems()
        current?.loader.cancelAll()
        upcoming?.loader.cancelAll()
        current = nil
        upcoming = nil
        statusObservations.removeAll()
    }

    private func makeEntry(_ song: Song, substitute: SourceStream? = nil, loader existing: StreamLoader? = nil) -> Entry {
        let loader = existing ?? StreamLoader(videoId: song.videoId)
        if existing == nil { loader.prime() }
        let asset: AVURLAsset
        if let substitute {
            asset = AVURLAsset(url: substitute.url, options: substitute.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": substitute.headers])
        } else {
            asset = loader.makeAsset()
        }
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30
        statusObservations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let error = item.error
            Task { @MainActor in self?.itemFailed(item, error) }
        })
        return Entry(song: song, loader: loader, item: item, substitute: substitute)
    }

    private func currentItemChanged() {
        guard let item = player.currentItem else { return }
        if let upcoming, item === upcoming.item {
            current?.loader.cancelAll()
            current = upcoming
            self.upcoming = nil
            onAdvance?(upcoming.song)
        }
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard let item, item === current?.item, upcoming == nil else { return }
        onEnded?()
    }

    private func itemFailed(_ item: AVPlayerItem?, _ error: Error?) {
        if let current, item === current.item {
            onFailed?(current.song, error)
        } else if let upcoming, item === upcoming.item {
            // Try again when it comes up rather than skipping it unheard.
            player.remove(upcoming.item)
            upcoming.loader.cancelAll()
            self.upcoming = nil
        }
    }
}
