import Foundation
import Observation

/**
 * The signed-in account's thumbs ratings, as far as this session has read or
 * set them. Read off each track's own row in its watch queue, set
 * optimistically and put back if YouTube refuses.
 */
@MainActor
@Observable
final class Likes {
    static let shared = Likes()

    private(set) var ratings: [String: LikeStatus] = [:]
    private var asked: Set<String> = []

    func rating(_ videoId: String) -> LikeStatus? { ratings[videoId] }

    func isLiked(_ videoId: String) -> Bool { ratings[videoId] == .like }

    /** Asks once per track per session; signed out there is nothing to ask. */
    func load(_ videoId: String) async {
        guard Account.shared.isSignedIn, !asked.contains(videoId) else { return }
        asked.insert(videoId)
        guard let response = try? await Innertube.shared.next(videoId: videoId),
              let status = InnertubeParser.parseLikeStatus(response, videoId: videoId) else { return }
        ratings[videoId] = status
    }

    func toggleLike(_ song: Song) {
        set(song, ratings[song.videoId] == .like ? .indifferent : .like)
    }

    /** Disliking the track that's playing also skips it. */
    func toggleDislike(_ song: Song) {
        let disliking = ratings[song.videoId] != .dislike
        set(song, disliking ? .dislike : .indifferent)
        if disliking, PlayerModel.shared.song?.videoId == song.videoId { PlayerModel.shared.next() }
    }

    private func set(_ song: Song, _ status: LikeStatus) {
        let before = ratings[song.videoId]
        ratings[song.videoId] = status
        Task {
            do {
                try await Innertube.shared.rate(song.videoId, status)
            } catch {
                ratings[song.videoId] = before
                PlayerModel.shared.showNotice("Couldn’t update the rating")
            }
        }
    }

    func reset() {
        ratings = [:]
        asked = []
    }
}
