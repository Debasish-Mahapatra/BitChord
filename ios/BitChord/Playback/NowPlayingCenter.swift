import AVFoundation
import MediaPlayer
import UIKit

/** The lock screen, Control Center and headphone controls: the phone's media session. */
@MainActor
final class NowPlayingCenter {
    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var next: () -> Void
        var previous: () -> Void
        var seek: (TimeInterval) -> Void
        var like: () -> Void
    }

    private var artworkFor: String?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    func install(_ handlers: Handlers) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in handlers.play(); return .success }
        center.pauseCommand.addTarget { _ in handlers.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { _ in handlers.toggle(); return .success }
        center.nextTrackCommand.addTarget { _ in handlers.next(); return .success }
        center.previousTrackCommand.addTarget { _ in handlers.previous(); return .success }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            handlers.seek(event.positionTime)
            return .success
        }
        center.likeCommand.addTarget { _ in handlers.like(); return .success }
        center.likeCommand.localizedTitle = "Favorite"
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    func update(song: Song?, position: TimeInterval, duration: TimeInterval?, playing: Bool, liked: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        guard let song else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = song.albumName { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration = duration ?? song.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if artworkFor == song.videoId, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = playing ? .playing : .paused
        MPRemoteCommandCenter.shared().likeCommand.isActive = liked
        if artworkFor != song.videoId { loadArtwork(for: song) }
    }

    /** Outside the main actor: MediaPlayer calls the image closure from its own queue. */
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func loadArtwork(for song: Song) {
        artworkFor = song.videoId
        artwork = nil
        artworkTask?.cancel()
        guard let url = song.artwork(playerArtPx) else { return }
        artworkTask = Task {
            guard let (data, _) = try? await HTTP.session.data(from: url), let image = UIImage(data: data), !Task.isCancelled else { return }
            let artwork = Self.makeArtwork(image)
            guard self.artworkFor == song.videoId else { return }
            self.artwork = artwork
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
