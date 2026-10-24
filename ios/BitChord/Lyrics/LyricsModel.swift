import Foundation
import Observation

/**
 * The current track's lyrics (LyricsRepository + the ViewModel around it):
 * every source starts at once, answers are taken in priority order, and the
 * first with synced lines wins; an unsynced sheet is kept only as a fallback.
 */
@MainActor
@Observable
final class LyricsModel {
    static let shared = LyricsModel()

    enum ProviderState: Equatable { case notFetched, fetching, found, notFound }

    private(set) var videoId: String?
    private(set) var lyrics: Lyrics?
    private(set) var loading = false
    private(set) var states: [LyricsSource: ProviderState] = [:]
    /** Positive shows lyrics later, −5000…5000 ms. */
    var offsetMs: Int = UserDefaults.standard.integer(forKey: "lyrics.offset") {
        didSet { UserDefaults.standard.set(offsetMs, forKey: "lyrics.offset") }
    }

    private var found: [LyricsSource: [LyricLine]] = [:]
    private var task: Task<Void, Never>?
    private var query: LyricsQuery?

    var order: [LyricsSource] { LyricsSource.allCases }

    /** Looks lyrics up for [song] once its length is known; a no-op for the track already loaded. */
    func load(for song: Song?, duration: Double) {
        guard let song else {
            reset(nil)
            return
        }
        guard song.videoId != videoId else { return }
        // Switched off in Settings: none are looked for, rather than found missing.
        guard AppSettings.shared.syncedLyrics else {
            reset(nil)
            return
        }
        let length = duration > 0 ? duration : (song.duration ?? 0)
        guard length > 0 else { return }
        reset(song.videoId)
        let query = LyricsQuery(song: song, duration: length)
        self.query = query
        loading = true
        for source in order { states[source] = .fetching }
        task = Task { await race(query) }
    }

    private func reset(_ id: String?) {
        task?.cancel()
        videoId = id
        lyrics = nil
        loading = false
        found = [:]
        states = [:]
    }

    private func race(_ query: LyricsQuery) async {
        let sources = order
        let tasks = sources.map { source in Task { await LyricsProviders.fetch(source, query) } }
        defer { tasks.forEach { $0.cancel() } }
        var fallback: Lyrics?
        for (i, source) in sources.enumerated() {
            let lines = await tasks[i].value
            guard !Task.isCancelled, videoId == query.videoId else { return }
            states[source] = lines == nil ? .notFound : .found
            guard let lines else { continue }
            found[source] = lines
            let result = Lyrics(lines: lines, source: source)
            if result.isWordSynced || result.isSynced {
                finish(result)
                // The losers are cancelled and read as not fetched, for the picker to ask again.
                for later in sources[(i + 1)...] where states[later] == .fetching { states[later] = .notFetched }
                return
            }
            if fallback == nil { fallback = result }
        }
        finish(fallback)
    }

    private func finish(_ result: Lyrics?) {
        lyrics = result
        loading = false
    }

    /** The provider sheet's choice: switch to a source that answered, or fetch one that hasn't. */
    func choose(_ source: LyricsSource) {
        if let lines = found[source] {
            lyrics = Lyrics(lines: lines, source: source)
            return
        }
        guard let query, states[source] != .fetching else { return }
        states[source] = .fetching
        Task {
            let lines = await LyricsProviders.fetch(source, query)
            guard videoId == query.videoId else { return }
            states[source] = lines == nil ? .notFound : .found
            if let lines {
                found[source] = lines
                lyrics = Lyrics(lines: lines, source: source)
            }
        }
    }
}
