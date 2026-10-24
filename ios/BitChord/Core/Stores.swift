import Foundation
import Observation

/** A small JSON file in Application Support, written off the main thread. */
private enum Disk {
    static func url(_ name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func write<T: Encodable & Sendable>(_ value: T, to name: String) {
        let url = url(name)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
        }
    }
}

/** Tracks played on this phone, newest first — what the History page lists. */
@MainActor
@Observable
final class History {
    static let shared = History()
    static let limit = 200

    private(set) var songs: [Song]

    private init() {
        songs = Disk.read([Song].self, from: "history.json") ?? []
    }

    func record(_ song: Song) {
        songs.removeAll { $0.videoId == song.videoId }
        songs.insert(song, at: 0)
        if songs.count > Self.limit { songs.removeLast(songs.count - Self.limit) }
        Disk.write(songs, to: "history.json")
    }

    func clear() {
        songs = []
        Disk.write(songs, to: "history.json")
    }
}

/**
 * Recent searches (SearchHistory.kt): the results the user tapped, not the
 * queries typed — at most 20, newest first, one per id.
 */
@MainActor
@Observable
final class SearchHistory {
    static let shared = SearchHistory()
    static let limit = 20

    struct Entry: Codable, Hashable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable { case track, album, artist, playlist }
        var id: String
        var title: String
        var subtitle: String
        var artworkUrl: String?
        var kind: Kind
        /** The whole track, so tapping it plays without another lookup. */
        var song: Song?

        var typeLabel: String {
            switch kind {
            case .track: return "Track"
            case .album: return "Album"
            case .artist: return "Artist"
            case .playlist: return "Playlist"
            }
        }
    }

    private(set) var entries: [Entry]

    private init() {
        entries = Disk.read([Entry].self, from: "search-history.json") ?? []
    }

    func record(song: Song) {
        record(Entry(id: song.videoId, title: song.title, subtitle: song.artist, artworkUrl: song.thumbnailUrl, kind: .track, song: song))
    }

    func record(item: BrowseItem) {
        let kind: Entry.Kind = item.type == .artist ? .artist : item.type == .album ? .album : .playlist
        record(Entry(id: item.browseId, title: item.title, subtitle: item.subtitle, artworkUrl: item.thumbnailUrl, kind: kind))
    }

    private func record(_ entry: Entry) {
        entries.removeAll { $0.id.caseInsensitiveCompare(entry.id) == .orderedSame }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        Disk.write(entries, to: "search-history.json")
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        Disk.write(entries, to: "search-history.json")
    }

    func clear() {
        entries = []
        Disk.write(entries, to: "search-history.json")
    }
}
