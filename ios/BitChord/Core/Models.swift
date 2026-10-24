import Foundation

/** One credited artist, with the page it links to when YouTube gave one. */
struct ArtistRef: Codable, Hashable, Sendable {
    var name: String
    var browseId: String?
}

/** A thumbs rating, as YouTube states it. */
enum LikeStatus: String, Codable, Sendable {
    case like = "LIKE"
    case dislike = "DISLIKE"
    case indifferent = "INDIFFERENT"
}

/** A playable track — the shared Kotlin `Song`, as far as this app reads it. */
struct Song: Codable, Hashable, Identifiable, Sendable {
    var videoId: String
    var title: String
    var artist: String
    var thumbnailUrl: String?
    var durationText: String?
    var artistId: String?
    var artists: [ArtistRef] = []
    var albumId: String?
    var albumName: String?
    /** Only on a playlist's own rows: the slot "Remove from this playlist" names. */
    var setVideoId: String?
    var isVideo: Bool = false
    var isExplicit: Bool = false

    var id: String { videoId }

    /** Seconds, from "4:59" or "1:02:03". */
    var duration: TimeInterval? {
        guard let durationText else { return nil }
        let parts = durationText.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count == durationText.split(separator: ":").count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    func artwork(_ px: Int) -> URL? { Artwork.url(thumbnailUrl, px: px) }
}

enum BrowseType: String, Codable, Hashable, Sendable {
    case album, artist, playlist, other

    /** What a browse id leads to, read off its prefix when the page type isn't stated. */
    init(browseId: String) {
        if browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
            self = .album
        } else if browseId.hasPrefix("UC") || browseId.hasPrefix("MPLA") {
            self = .artist
        } else if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") || browseId.hasPrefix("RD") {
            self = .playlist
        } else {
            self = .other
        }
    }

    init(pageType: String, browseId: String) {
        if pageType.contains("ALBUM") {
            self = .album
        } else if pageType.contains("ARTIST") {
            self = .artist
        } else if pageType.contains("PLAYLIST") {
            self = .playlist
        } else {
            self = BrowseType(browseId: browseId)
        }
    }
}

/** An album, artist or playlist a row or card opens. */
struct BrowseItem: Codable, Hashable, Identifiable, Sendable {
    var browseId: String
    var title: String
    var subtitle: String
    var thumbnailUrl: String?
    var type: BrowseType

    var id: String { browseId }
}

/** One card on a shelf: either a track to play or a page to open. */
struct ShelfItem: Hashable, Identifiable, Sendable {
    var title: String
    var subtitle: String
    var thumbnailUrl: String?
    var videoId: String?
    var browseId: String?
    /** The track behind a card that plays, when the card came from a full row. */
    var song: Song?
    /** A music-video upload: drawn 16:9 rather than square. */
    var isVideo = false

    var id: String { browseId ?? videoId ?? title }
    var type: BrowseType? { browseId.map(BrowseType.init(browseId:)) }

    var browseItem: BrowseItem? {
        guard let browseId else { return nil }
        return BrowseItem(browseId: browseId, title: title, subtitle: subtitle, thumbnailUrl: thumbnailUrl,
                          type: BrowseType(browseId: browseId))
    }

    /** The card as a track, credited as InnertubeParser.artistFromSubtitle reads it. */
    var asSong: Song? {
        if let song { return song }
        guard let videoId else { return nil }
        return Song(videoId: videoId, title: title, artist: InnertubeParser.artistFromSubtitle(subtitle),
                    thumbnailUrl: thumbnailUrl)
    }
}

/** How a shelf is drawn (ShelfLayout). */
enum ShelfLayout: Sendable {
    /** Square cards in one scrolling row. */
    case cards
    /** Track rows, four to a column — Quick picks, Listen again, Recents. */
    case list
    /** Widescreen cards for music videos. */
    case video

    /**
     * shelfLayoutFor: rows when YouTube listed tracks as rows (or it's Listen
     * again), widescreen when most of it is videos.
     */
    static func of(title: String, items: [ShelfItem], fromList: Bool) -> ShelfLayout {
        guard let first = items.first else { return .cards }
        if fromList, first.videoId != nil { return .list }
        if title.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Listen again") == .orderedSame { return .list }
        if items.filter(\.isVideo).count * 2 > items.count { return .video }
        return .cards
    }
}

struct HomeShelf: Identifiable, Hashable, Sendable {
    var title: String
    var items: [ShelfItem]
    var strapline: String = ""
    var moreBrowseId: String?
    var moreParams: String?
    var layout: ShelfLayout = .cards

    var id: String { title + (items.first?.id ?? "") }

    private var browseKeys: Set<String> { Set(items.compactMap(\.browseId)) }

    /**
     * These shelves minus any that mostly repeat one already shown (60% of
     * the smaller one's albums/playlists/artists): New releases and Explore
     * serve the same releases under different headings.
     */
    static func withoutRepeats(_ shelves: [HomeShelf], of existing: [HomeShelf]) -> [HomeShelf] {
        var shown = existing
        return shelves.filter { shelf in
            let keys = shelf.browseKeys
            let repeats = !keys.isEmpty && shown.contains { other in
                let shared = other.browseKeys.intersection(keys).count
                return shared > 0 && Double(shared) >= 0.6 * Double(min(shelf.items.count, other.items.count))
            }
            if !repeats { shown.append(shelf) }
            return !repeats
        }
    }
}

/** A watch queue to start: an artist's radio or shuffle, a mix. */
struct WatchTarget: Hashable, Codable, Sendable {
    var playlistId: String
    var videoId: String?
    var params: String?
}

enum SearchResult: Hashable, Identifiable, Sendable {
    case topTrack(Song)
    case track(Song)
    case browse(BrowseItem)

    var id: String {
        switch self {
        case .topTrack(let song), .track(let song): return "v:" + song.videoId
        case .browse(let item): return "b:" + item.browseId
        }
    }
}

enum SearchFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case songs = "Songs"
    case albums = "Albums"
    case artists = "Artists"
    case playlists = "Playlists"

    var id: String { rawValue }

    /** The `params` YouTube Music's own filter chips send (Models.kt SearchFilter). */
    var params: String? {
        switch self {
        case .all: return nil
        case .songs: return "EgWKAQIIAWoKEAkQChAFEAMQBA=="
        case .albums: return "EgWKAQIYAWoKEAkQChAFEAMQBA=="
        case .artists: return "EgWKAQIgAWoKEAkQChAFEAMQBA=="
        case .playlists: return "EgWKAQIoAWoKEAkQChAFEAMQBA=="
        }
    }
}

struct ArtistPage: Sendable {
    var name: String?
    var thumbnailUrl: String?
    var songs: [Song]
    /** The playlist behind "Top songs", when the shelf links to the full list. */
    var moreSongsBrowseId: String?
    var shelves: [HomeShelf]
    var description: String?
    var subscriberCountText: String?
    var monthlyListenerCount: String?
    var subscription: Subscription?
    var radio: WatchTarget?
    var shuffle: WatchTarget?

    struct Subscription: Sendable {
        var channelId: String
        var subscribed: Bool
    }
}

/** An album or playlist page. */
struct CollectionPage: Sendable {
    var title: String
    var subtitle: String
    var thumbnailUrl: String?
    var description: String?
    var songs: [Song]
    /** The playlist that backs an album, and that a playlist page plays. */
    var playlistId: String?
    var continuation: String?
    /** "More by this artist" and similar carousels under an album. */
    var shelves: [HomeShelf] = []
    /** The artist the header credits, for the credit line to open. */
    var artistId: String?
}

struct MoodGenre: Hashable, Identifiable, Sendable {
    var title: String
    var browseId: String
    var params: String?
    var stripeColor: UInt32?

    var id: String { browseId + (params ?? "") }
}

struct MoodGenreSection: Hashable, Identifiable, Sendable {
    var title: String
    var items: [MoodGenre]

    var id: String { title }
}

/** The size-hint rewriting of Models.kt's `artworkAt`. */
enum Artwork {
    private static let sizeHint = NSRegularExpression(#"w\d+-h\d+"#)
    private static let paramSizeHint = NSRegularExpression(#"=s\d+"#)

    static func url(_ string: String?, px: Int) -> URL? {
        guard var string else { return nil }
        if string.hasPrefix("//") { string = "https:" + string }
        let range = NSRange(string.startIndex..., in: string)
        var sized = sizeHint.stringByReplacingMatches(in: string, range: range, withTemplate: "w\(px)-h\(px)")
        if let host = URL(string: string)?.host?.lowercased(),
           host.hasSuffix("ggpht.com") || host.hasSuffix("googleusercontent.com") {
            let range = NSRange(sized.startIndex..., in: sized)
            sized = paramSizeHint.stringByReplacingMatches(in: sized, range: range, withTemplate: "=s\(px)")
        }
        return URL(string: sized)
    }
}

/** Row artwork (about 52pt at 3x) and shelf cards, as ROW_ART_PX / CARD_ART_PX. */
let rowArtPx = 160
let cardArtPx = 480
let playerArtPx = 1080

/**
 * The moves that turn one running order into another (PlaylistOrder.kt): the
 * longest run already in order stays put, and every other row is moved in
 * front of its successor, last first.
 */
enum PlaylistOrder {
    static func moves(current: [String], target: [String]) -> [(setVideoId: String, before: String?)] {
        guard current != target, current.count == target.count, Set(current) == Set(target), Set(current).count == current.count else { return [] }
        let position = Dictionary(uniqueKeysWithValues: current.enumerated().map { ($1, $0) })
        let stay = Set(longestIncreasingRun(target.map { position[$0]! }).map { target[$0] })
        var moves: [(String, String?)] = []
        for index in target.indices.reversed() where !stay.contains(target[index]) {
            moves.append((target[index], index + 1 < target.count ? target[index + 1] : nil))
        }
        return moves
    }

    /** Indices of one longest strictly increasing subsequence. */
    private static func longestIncreasingRun(_ values: [Int]) -> [Int] {
        guard !values.isEmpty else { return [] }
        var tails = [Int](repeating: 0, count: values.count)
        var previous = [Int](repeating: -1, count: values.count)
        var length = 0
        for i in values.indices {
            var low = 0, high = length
            while low < high {
                let mid = (low + high) / 2
                if values[tails[mid]] < values[i] { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[i] = tails[low - 1] }
            tails[low] = i
            if low == length { length += 1 }
        }
        var out: [Int] = []
        var k = tails[length - 1]
        while k >= 0 {
            out.append(k)
            k = previous[k]
        }
        return out.reversed()
    }
}
