import AVFoundation
import Foundation
import Observation
import UIKit

enum RepeatMode: String, Codable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/**
 * The player as the UI sees it: the queue (QueueTimeline's rules), the engine
 * playing it, AutoPlay keeping it going, and the media session. One instance,
 * like the phone's PlaybackService behind MainViewModel.
 */
@MainActor
@Observable
final class PlayerModel {
    static let shared = PlayerModel()

    private(set) var timeline: [QueueEntry] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var durationSeconds: TimeInterval = 0
    /** Bumped on every seek or track change: the lyric clock's "announced jump". */
    private(set) var seekCount = 0

    var shuffle = false {
        didSet { if shuffle != oldValue { applyShuffle() } }
    }
    var repeatMode: RepeatMode = .off {
        didSet { if repeatMode != oldValue { applyRepeat(from: oldValue) } }
    }
    var autoplay = true {
        didSet { if autoplay != oldValue { applyAutoplay() } }
    }

    /** The queue notice above the mini player ("Song will play next"), shown for 3 s. */
    private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?

    private let engine = PlaybackEngine()
    private let session = NowPlayingCenter()
    private var engineUpcomingId: UUID?
    private var stashedAutoplay: [QueueEntry] = []
    private var preShuffleOrder: [UUID] = []
    private var autoplaySeeds: Set<String> = []
    /** Played or suggested since launch, for "Don't repeat songs". */
    private var sessionSeen = Set<String>()
    private var autoplayTask: Task<Void, Never>?
    private var recoveries: [UUID: Int] = [:]
    /** Copies other sources had of a track, kept five minutes; nil is "looked, nothing". */
    private var substitutes: [String: (at: Date, stream: SourceStream?)] = [:]
    /** Tracks a substitute broke once: YouTube is the answer that hasn't failed. */
    private var refusedSubstitutes: Set<String> = []
    private var substituteTask: Task<Void, Never>?
    private var upcomingSubstituteTask: Task<Void, Never>?
    /** Another source's copy is playing in YouTube's place. */
    private(set) var playingSubstitute: SourceStream?
    /** A lossless copy is still being looked for while YouTube's plays. */
    private(set) var upgradingQuality = false
    private var timeObserver: Any?

    static let maxQueuedAutoplay = 10
    static let radioSize = 24

    var current: QueueEntry? { timeline.indices.contains(index) ? timeline[index] : nil }
    var song: Song? { current?.song }
    var hasNext: Bool { index + 1 < timeline.count || (repeatMode == .all && !timeline.isEmpty) }
    var hasPrevious: Bool { index > 0 }

    /** The live position, read straight off AVPlayer (it interpolates between frames itself). */
    var position: TimeInterval { engine.position }

    var duration: TimeInterval {
        if durationSeconds > 0 { return durationSeconds }
        return song?.duration ?? 0
    }

    /** "Playing from …" / "Playing X Radio", for the caption over the player. */
    var sourceCaption: String? {
        guard let current else { return nil }
        if let source = current.source, source.kind == .radio { return "Playing \(source.title) Radio" }
        let name = current.source?.title ?? current.song.albumName ?? "Queue"
        return "Playing from \(name)"
    }

    private init() {
        UserDefaults.standard.register(defaults: ["player.autoplay": true])
        shuffle = UserDefaults.standard.bool(forKey: "player.shuffle")
        repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "player.repeat") ?? "") ?? .off
        autoplay = UserDefaults.standard.bool(forKey: "player.autoplay")

        engine.onAdvance = { [weak self] _ in self?.engineAdvanced() }
        engine.onEnded = { [weak self] in self?.engineEnded() }
        engine.onFailed = { [weak self] song, error in self?.engineFailed(song, error) }
        engine.onStateChange = { [weak self] in self?.syncState() }
        timeObserver = engine.player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        session.install(.init(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlay() },
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() },
            seek: { [weak self] in self?.seek(to: $0) },
            like: { [weak self] in if let song = self?.song { Likes.shared.toggleLike(song) } }
        ))
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.persist() }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated {
                if type == .ended, options?.contains(.shouldResume) == true { self?.play() }
            }
        }
        restore()
    }

    // MARK: Starting playback

    /** An album, playlist or artist's songs, from [start]. */
    func play(_ songs: [Song], from start: Int = 0, source: QueueSource, shuffled: Bool = false) {
        guard !songs.isEmpty else { return }
        var (timeline, at) = QueueTimeline.contextQueue(self.timeline, current: index, songs: songs, selected: start, source: source)
        let canonical = timeline.map(\.id)
        let shuffling = shuffled || shuffle
        if shuffling {
            // The picked track leads; the canonical order is kept for turning shuffle off.
            timeline = QueueTimeline.shuffledStartingOrder(timeline, start: at)
            at = 0
            if !shuffle { shuffleSilently(true) }
        }
        replace(timeline, index: at, canonical: shuffling ? canonical : [])
    }

    /** A one-off song (Search, Home): the song, then the user's queue kept. */
    func playOne(_ song: Song, source: QueueSource) {
        replace(QueueTimeline.oneOffQueue(timeline, current: index, song: song, source: source), index: 0)
    }

    /**
     * A radio from [song] — what tapping a song card does. The song plays at
     * once; YouTube's radio for it fills in behind it, 24 tracks.
     */
    func startRadio(_ song: Song) {
        let source = QueueSource(title: song.title, kind: .radio, id: song.videoId)
        // Marked before the queue is replaced: for that moment the seed is the last track, and AutoPlay
        // would otherwise fetch this same station and append it again once it landed.
        autoplaySeeds.insert(song.videoId)
        replace([QueueEntry(song, tier: .context, source: source)] + QueueTimeline.upcomingUserQueue(timeline, index), index: 0)
        let seedEntry = timeline.first?.id
        Task {
            guard let response = try? await Innertube.shared.next(videoId: song.videoId) else { return }
            let radio = InnertubeParser.parseWatchQueue(response).filter { $0.videoId != song.videoId }
            let picked = StationBuilder.extend([song], candidates: radio, limit: Self.radioSize)
            guard timeline.first?.id == seedEntry else { return }
            // Checked against the queue as it is now, not as it was when the station was asked for.
            let queued = Set(timeline.map(\.song.videoId))
            let entries = picked.filter { !queued.contains($0.videoId) }.map { QueueEntry($0, tier: .context, source: source) }
            let insertAt = timeline.firstIndex { $0.tier == .autoplay } ?? timeline.count
            timeline.insert(contentsOf: entries, at: insertAt)
            if shuffle { preShuffleOrder = timeline.map(\.id) }
            syncUpcoming()
            persist()
        }
    }

    func playNext(_ song: Song) {
        insertUser(song, next: true)
        showNotice("Song will play next")
    }

    func addToQueue(_ song: Song) {
        insertUser(song, next: false)
        showNotice("Song added to queue")
    }

    private func insertUser(_ song: Song, next: Bool) {
        let entry = QueueEntry(song, tier: .user, source: current?.source)
        if timeline.isEmpty {
            replace([entry], index: 0)
            return
        }
        timeline.insert(entry, at: QueueTimeline.userInsertionIndex(timeline, current: index, next: next))
        syncUpcoming()
        persist()
    }

    // MARK: Transport

    func play() {
        guard song != nil else { return }
        activateSession()
        if engine.current == nil { load(at: lastRestoredPosition, play: true) } else { engine.play() }
    }

    func pause() { engine.pause() }

    func togglePlay() {
        if engine.isPlaying { pause() } else { play() }
    }

    func next() {
        guard !timeline.isEmpty else { return }
        if index + 1 < timeline.count {
            moveTo(index + 1)
        } else if repeatMode == .all {
            moveTo(0)
        }
    }

    /** Within the first 10 s, the previous track; after that (or with none), the start of this one. */
    func previous() {
        if position > QueueTimeline.backRestartsAfter || index == 0 {
            seek(to: 0)
        } else {
            moveTo(index - 1)
        }
    }

    func seek(to seconds: TimeInterval) {
        seekCount += 1
        engine.seek(to: seconds) { [weak self] in self?.updateSession() }
        updateSession()
    }

    /** Tapping a row in Up Next. */
    func jump(to target: Int) {
        guard let (edited, newIndex) = QueueTimeline.jump(timeline, current: index, target: target) else { return }
        timeline = edited
        moveTo(newIndex)
    }

    func remove(at position: Int) {
        guard timeline.indices.contains(position), position != index else { return }
        timeline.remove(at: position)
        if position < index { index -= 1 }
        syncUpcoming()
        maybeExtendAutoplay()
        persist()
    }

    /** Reorders within one section; the UI only offers moves inside a section. */
    func move(from source: Int, to destination: Int) {
        guard timeline.indices.contains(source), source != index, destination > index, destination < timeline.count else { return }
        let entry = timeline.remove(at: source)
        timeline.insert(entry, at: destination)
        syncUpcoming()
        persist()
    }

    /** Removes only the upcoming hand-queued rows. */
    func clearUserQueue() {
        timeline = timeline.enumerated().filter { $0.offset <= index || $0.element.tier != .user }.map(\.element)
        syncUpcoming()
        maybeExtendAutoplay()
        persist()
    }

    // MARK: Queue edits and the engine

    private var lastRestoredPosition: TimeInterval = 0

    private func replace(_ newTimeline: [QueueEntry], index newIndex: Int, canonical: [UUID]? = nil) {
        timeline = newTimeline
        preShuffleOrder = canonical ?? (shuffle ? newTimeline.map(\.id) : [])
        moveTo(newIndex)
    }

    private func moveTo(_ newIndex: Int) {
        guard timeline.indices.contains(newIndex) else { return }
        index = newIndex
        pruneUserHistory()
        load(at: 0, play: true)
        maybeExtendAutoplay()
        persist()
    }

    private func load(at position: TimeInterval, play: Bool) {
        guard let current else { return }
        if play { activateSession() }
        durationSeconds = 0
        seekCount += 1
        engineUpcomingId = nil
        let song = current.song
        let known = freshSubstitute(song)
        engine.load(song, at: position, play: play, substitute: known)
        playingSubstitute = known
        if known == nil { raceSubstitute(for: song, entry: current.id) }
        lastRestoredPosition = 0
        sessionSeen.insert(current.song.videoId)
        History.shared.record(current.song)
        syncUpcoming()
        updateSession()
    }

    /** What the engine should buffer behind the current track. */
    private func syncUpcoming() {
        let upcoming: QueueEntry?
        if repeatMode == .one {
            upcoming = nil
        } else if index + 1 < timeline.count {
            upcoming = timeline[index + 1]
        } else if repeatMode == .all, !timeline.isEmpty, timeline.count > 1 {
            upcoming = timeline[0]
        } else {
            upcoming = nil
        }
        if upcoming?.id == engineUpcomingId, engine.upcoming != nil || upcoming == nil { return }
        engineUpcomingId = upcoming?.id
        engine.setUpcoming(upcoming?.song)
        prefetchSubstitute(for: upcoming?.song)
    }

    // MARK: Other sources (SourceResolver)

    private func canSubstitute(_ song: Song) -> Bool {
        !song.isVideo && !refusedSubstitutes.contains(song.videoId) && !SourceRegistry.shared.substitutes.isEmpty
    }

    private func freshSubstitute(_ song: Song) -> SourceStream? {
        guard canSubstitute(song), let cached = substitutes[song.videoId], Date().timeIntervalSince(cached.at) < 300 else { return nil }
        return cached.stream
    }

    /** The sources above YouTube asked for this track, at most twenty seconds; remembered either way. */
    private func substitute(for song: Song) async -> SourceStream? {
        if let cached = substitutes[song.videoId], Date().timeIntervalSince(cached.at) < 300 { return cached.stream }
        let registry = SourceRegistry.shared
        let sources = registry.substitutes
        let clients = Dictionary(sources.filter { $0.kind == .addon }.map { ($0.id, registry.client(for: $0)) }, uniquingKeysWith: { a, _ in a })
        let target = TrackMatcher.Target(song)
        let request = SourceResolver.requestForNow()
        let found = await withTaskGroup(of: SourceStream??.self) { group in
            group.addTask { .some(await SourceResolver.best(for: target, in: sources, request: request, clients: clients)) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
        substitutes[song.videoId] = (Date(), found)
        return found
    }

    /**
     * YouTube starts at once, and the other sources are asked alongside. One
     * that answers before the first note plays the track; one that answers
     * later is swapped in where the music is, if it's the same cut and worth it.
     */
    private func raceSubstitute(for song: Song, entry: UUID) {
        substituteTask?.cancel()
        upgradingQuality = false
        guard canSubstitute(song) else { return }
        upgradingQuality = SourceResolver.requestForNow() == .lossless && SourceRegistry.shared.substitutes.contains { $0.kind == .addon }
        substituteTask = Task {
            let found = await substitute(for: song)
            guard !Task.isCancelled, self.current?.id == entry, self.engine.current?.song.videoId == song.videoId else { return }
            self.upgradingQuality = false
            guard let found, SourceResolver.worthSwapping(found.format, over: 128) else { return }
            let started = self.engine.position > 0.5
            if started {
                // Mid-song only for the same cut, within two seconds of what's playing.
                guard let foundSec = found.durationSec, let playingSec = self.engine.duration ?? song.duration,
                      abs(Double(foundSec) - playingSec) <= Double(SourceResolver.upgradeDriftSec) else { return }
            }
            Log.d("playing \(found.sourceName)'s copy at \(found.format.summary)", about: song.videoId)
            self.engine.swapCurrent(to: found)
            self.playingSubstitute = found
        }
    }

    /** The next track's copy looked for while this one plays, so it can start on it. */
    private func prefetchSubstitute(for song: Song?) {
        upcomingSubstituteTask?.cancel()
        guard let song, canSubstitute(song) else { return }
        upcomingSubstituteTask = Task {
            guard let found = await substitute(for: song), !Task.isCancelled,
                  self.engine.upcoming?.song.videoId == song.videoId, self.engine.upcoming?.substitute == nil,
                  SourceResolver.worthSwapping(found.format, over: 128) else { return }
            self.engine.replaceUpcoming(with: found)
        }
    }

    private func engineAdvanced() {
        guard let id = engineUpcomingId, let newIndex = timeline.firstIndex(where: { $0.id == id }) else { return }
        index = newIndex
        engineUpcomingId = nil
        durationSeconds = 0
        seekCount += 1
        playingSubstitute = engine.current?.substitute
        upgradingQuality = false
        sessionSeen.insert(timeline[newIndex].song.videoId)
        History.shared.record(timeline[newIndex].song)
        pruneUserHistory()
        syncUpcoming()
        maybeExtendAutoplay()
        updateSession()
        persist()
    }

    private func engineEnded() {
        if repeatMode == .one {
            seek(to: 0)
            engine.play()
        } else if index + 1 < timeline.count {
            moveTo(index + 1)
        } else {
            // The end of the line: stay on the last track, paused at its start.
            engine.pause()
            engine.seek(to: 0)
            syncState()
        }
    }

    /**
     * A failed item: the client that minted it is excluded and the track picks
     * up on the next one at the same position. Twice, then it's skipped.
     */
    private func engineFailed(_ song: Song, _ error: Error?) {
        guard let current, current.song.videoId == song.videoId else { return }
        if engine.current?.substitute != nil {
            // The other source's copy broke: back to YouTube's from here, and not again for this track.
            Log.w("substitute failed: \(error?.localizedDescription ?? "unknown")", about: song.videoId)
            refusedSubstitutes.insert(song.videoId)
            substitutes[song.videoId] = nil
            load(at: position, play: true)
            return
        }
        let attempts = recoveries[current.id, default: 0]
        let at = position
        Log.w("playback failed at \(Int(at))s: \(error?.localizedDescription ?? "unknown")", about: song.videoId)
        if attempts < 2 {
            recoveries[current.id] = attempts + 1
            let clientId = engine.current?.loader.clientId
            Task {
                if let clientId { await StreamResolver.shared.exclude(song.videoId, clientId: clientId, why: "playback failed") }
                guard self.current?.id == current.id else { return }
                self.load(at: at, play: true)
            }
            return
        }
        let reason = (error as? StreamError)?.errorDescription ?? "Couldn't play “\(song.title)”"
        showNotice(reason)
        if index + 1 < timeline.count { moveTo(index + 1) } else { engine.pause() }
    }

    /** Played hand-queued rows go once playback is back in the context. */
    private func pruneUserHistory() {
        let played = QueueTimeline.playedUserQueueIndices(timeline, current: index)
        guard !played.isEmpty else { return }
        let drop = Set(played)
        timeline = timeline.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        index -= played.count
    }

    // MARK: Shuffle, repeat, AutoPlay

    private var applyingShuffle = false

    private func shuffleSilently(_ value: Bool) {
        applyingShuffle = true
        shuffle = value
        applyingShuffle = false
        UserDefaults.standard.set(value, forKey: "player.shuffle")
    }

    /**
     * On: history and the current track stay; what's still to come becomes
     * user + shuffled context + AutoPlay. Off: the canonical order comes back
     * around the current track, the user queue still pinned behind it.
     */
    private func applyShuffle() {
        UserDefaults.standard.set(shuffle, forKey: "player.shuffle")
        guard !applyingShuffle, !timeline.isEmpty else { return }
        let upcoming = Array(timeline[(index + 1)...])
        if shuffle {
            preShuffleOrder = timeline.map(\.id)
            let user = upcoming.filter { $0.tier == .user }
            let context = upcoming.filter { $0.tier == .context }
            let shuffledContext = QueueTimeline.avoidIdentity(Array(context.indices), Array(context.indices).shuffled()).map { context[$0] }
            timeline = Array(timeline[...index]) + user + shuffledContext + upcoming.filter { $0.tier == .autoplay }
        } else if !preShuffleOrder.isEmpty, let current {
            let rank = Dictionary(uniqueKeysWithValues: preShuffleOrder.enumerated().map { ($1, $0) })
            let context = timeline.filter { $0.tier == .context && $0.id != current.id && rank[$0.id] != nil }
                .sorted { rank[$0.id]! < rank[$1.id]! }
            let user = upcoming.filter { $0.tier == .user }
            let autoplay = upcoming.filter { $0.tier == .autoplay }
            if current.tier == .context, let here = rank[current.id] {
                let before = context.filter { rank[$0.id]! < here }
                let after = context.filter { rank[$0.id]! > here }
                timeline = before + [current] + user + after + autoplay
                index = before.count
            } else {
                let upcomingContext = context.filter { upcoming.map(\.id).contains($0.id) }
                timeline = Array(timeline[...index]) + user + upcomingContext + autoplay
            }
            preShuffleOrder = []
        }
        syncUpcoming()
        persist()
    }

    /** Entering repeat-all stashes AutoPlay's tracks; leaving it brings them back. */
    private func applyRepeat(from old: RepeatMode) {
        UserDefaults.standard.set(repeatMode.rawValue, forKey: "player.repeat")
        if repeatMode == .all {
            stashedAutoplay = timeline.enumerated().filter { $0.offset > index && $0.element.tier == .autoplay }.map(\.element)
            let stashed = Set(stashedAutoplay.map(\.id))
            timeline.removeAll { stashed.contains($0.id) }
        } else if old == .all, !stashedAutoplay.isEmpty {
            timeline += stashedAutoplay
            stashedAutoplay = []
        }
        syncUpcoming()
        maybeExtendAutoplay()
        persist()
    }

    private func applyAutoplay() {
        UserDefaults.standard.set(autoplay, forKey: "player.autoplay")
        if !autoplay {
            // Toggling off removes the unplayed AutoPlay tracks.
            timeline = timeline.enumerated().filter { $0.offset <= index || $0.element.tier != .autoplay }.map(\.element)
            autoplayTask?.cancel()
            syncUpcoming()
            persist()
        } else {
            autoplaySeeds.removeAll()
            maybeExtendAutoplay()
        }
    }

    /**
     * Keeps ten AutoPlay tracks queued once the list the user started has run
     * out — seeded on the current track, once per seed, never during repeat-all.
     */
    private func maybeExtendAutoplay(retrying: Bool = false) {
        guard autoplay, repeatMode != .all, let current else { return }
        let upcoming = timeline[(index + 1)...]
        guard !upcoming.contains(where: { $0.tier != .autoplay }) else { return }
        let queued = upcoming.count
        guard queued < Self.maxQueuedAutoplay else { return }
        let seed = current.song
        guard retrying || !autoplaySeeds.contains(seed.videoId) else { return }
        autoplaySeeds.insert(seed.videoId)
        autoplayTask = Task {
            let response = try? await Innertube.shared.next(videoId: seed.videoId)
            guard !Task.isCancelled, self.current?.song.videoId == seed.videoId else { return }
            var candidates = response.map { InnertubeParser.parseWatchQueue($0) }?.filter { $0.videoId != seed.videoId } ?? []
            // "Don't repeat songs": nothing already played or suggested this session.
            if AppSettings.shared.dontRepeatSongs { candidates.removeAll { self.sessionSeen.contains($0.videoId) } }
            let picked = StationBuilder.extend(self.timeline.map(\.song), candidates: candidates, limit: Self.maxQueuedAutoplay - queued)
            if picked.isEmpty {
                // One retry after 2 s, and only if this is still the last track.
                if !retrying {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if self.index == self.timeline.count - 1 { self.maybeExtendAutoplay(retrying: true) }
                }
                return
            }
            let source = current.source
            self.sessionSeen.formUnion(picked.map(\.videoId))
            self.timeline += picked.map { QueueEntry($0, tier: .autoplay, source: source) }
            self.syncUpcoming()
            self.persist()
            // A queue that ran dry while this loaded carries on.
            if !self.engine.isPlaying, self.engine.position >= max(0, self.duration - 1), self.index + 1 < self.timeline.count {
                self.moveTo(self.index + 1)
            }
        }
    }

    // MARK: State and the media session

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func tick() {
        if let duration = engine.duration, abs(duration - durationSeconds) > 0.5 { durationSeconds = duration }
        applyLoudness()
        updateSession()
    }

    /** Stats for nerds: the playing stream's codec, bitrate and where it came from. */
    var streamDescription: String? {
        if let substitute = playingSubstitute { return "\(substitute.format.summary) · \(substitute.sourceName)" }
        return engine.current?.loader.streamDescription
    }

    /** The label under the scrubber (LosslessOrStats): what is playing, or that something better is being found. */
    var qualityLabel: String {
        if let format = playingSubstitute?.format {
            if format.isLossless == true {
                return (format.bitDepth ?? 0) > 16 || (format.sampleRateHz ?? 0) > 48_000 ? "Hi-Res Lossless" : "Lossless"
            }
            return "High quality"
        }
        return upgradingQuality ? "Upgrading quality" : "High quality"
    }

    /**
     * Loudness normalisation (loudnessGainFor): YouTube's own figure for the
     * track, as a gain — bounded at -15 dB, and at unity above, since a
     * player's volume can only take sound away. Off on the phone's speaker
     * by default, and off when nothing is known yet.
     */
    private func applyLoudness() {
        let settings = AppSettings.shared
        var gain: Float = 1
        let onSpeaker = [.builtInSpeaker, .builtInReceiver].contains(AudioOutput.shared.port)
        if settings.loudnessNormalization, !(settings.loudnessOffOnSpeaker && onSpeaker),
           let db = engine.current?.loader.loudnessDb {
            gain = Float(pow(10, min(3, max(-15, -db)) / 20))
        }
        let volume = min(1, gain)
        if abs(engine.player.volume - volume) > 0.001 { engine.player.volume = volume }
    }

    private func syncState() {
        isPlaying = engine.isPlaying
        isBuffering = engine.isBuffering
        if let duration = engine.duration { durationSeconds = duration }
        updateSession()
        if !isPlaying { persist() }
    }

    private func updateSession() {
        session.update(song: song, position: position, duration: duration > 0 ? duration : nil,
                       playing: engine.player.rate > 0, liked: song.map { Likes.shared.isLiked($0.videoId) } ?? false)
    }

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { notice = nil }
        }
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var timeline: [QueueEntry]
        var index: Int
        var position: TimeInterval
    }

    private static var savedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("queue.json")
    }

    /** The queue and position, so the next launch opens where this one left off (paused). */
    func persist() {
        let saved = Saved(timeline: timeline, index: index, position: engine.current == nil ? lastRestoredPosition : position)
        let url = Self.savedURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.savedURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.timeline.indices.contains(saved.index) else { return }
        timeline = saved.timeline
        index = saved.index
        lastRestoredPosition = saved.position
        if shuffle { preShuffleOrder = timeline.map(\.id) }
    }
}
