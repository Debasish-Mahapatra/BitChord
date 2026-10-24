import Foundation
import Observation

/** What Song Info shows (SongInfoRepository.kt). Counts belong to this exact upload, never a search match. */
struct SongInfo: Sendable {
    var album: String?
    var releaseYear: String?
    var releaseDate: String?
    var views: String?
    var likes: String?
    var comments: String?
    var failed = false

    /**
     * YouTube's short form of a raw count: 950, 1.2K, 100K, 2.3M. Truncated
     * rather than rounded, as YouTube does, so 999999 never shows as "1000K".
     * Text that isn't a plain number comes back unchanged.
     */
    static func compactCount(_ raw: String) -> String {
        guard let n = Int64(raw), n >= 0 else { return raw }
        let (unit, suffix): (Int64, String)
        switch n {
        case 1_000_000_000...: (unit, suffix) = (1_000_000_000, "B")
        case 1_000_000...: (unit, suffix) = (1_000_000, "M")
        case 1_000...: (unit, suffix) = (1_000, "K")
        default: return String(n)
        }
        let whole = n / unit
        if whole >= 10 { return "\(whole)\(suffix)" }
        let tenth = n % unit * 10 / unit
        let separator = Locale.current.decimalSeparator ?? "."
        return tenth == 0 ? "\(whole)\(suffix)" : "\(whole)\(separator)\(tenth)\(suffix)"
    }

    static func load(_ song: Song) async -> SongInfo {
        guard song.videoId.wholeMatch(NSRegularExpression("[A-Za-z0-9_-]{11}")) else { return SongInfo(album: song.albumName) }
        async let statistics = try? watchPageInfo(song.videoId)
        var album = song.albumName
        var year: String?
        var releaseFailed = false
        do {
            var albumId = song.albumId
            if albumId == nil, let linked = try await Innertube.shared.trackLinks(song.videoId) {
                album = album ?? linked.albumName
                albumId = linked.albumId
            }
            if let albumId {
                let header = InnertubeParser.parseBrowseHeader(try await Innertube.shared.browse(albumId))
                album = album ?? header?.title
                year = header?.subtitle.components(separatedBy: "•").map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { $0.wholeMatch(NSRegularExpression("(?:19|20)[0-9]{2}")) }
            }
        } catch {
            releaseFailed = true
        }
        var info = await statistics ?? SongInfo(failed: true)
        info.album = album
        info.releaseYear = year
        info.failed = info.failed || releaseFailed
        return info
    }

    /** The watch page's player response and initial data, read for this upload's own counts. */
    private static func watchPageInfo(_ videoId: String) async throws -> SongInfo {
        var components = URLComponents(string: "https://www.youtube.com/watch")!
        components.queryItems = [.init(name: "v", value: videoId), .init(name: "hl", value: Locale.current.language.languageCode?.identifier ?? "en")]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        // Without a consent answer an EU request lands on consent.youtube.com. SOCS=CAI is "reject all".
        request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
        let (data, response) = try await HTTP.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
            throw InnertubeError.badResponse
        }
        guard let player = extract(html, "ytInitialPlayerResponse") else { throw InnertubeError.badResponse }
        let details = player["videoDetails"]
        guard details["videoId"].string == videoId else { throw InnertubeError.badResponse }
        let initial = extract(html, "ytInitialData")
        // Only the current video's primary renderer: recommendations carry counts too.
        let primary = initial?.collect("videoPrimaryInfoRenderer").first
        let oldLike = primary?.collect("toggleButtonRenderer")
            .first { $0["defaultIcon"]["iconType"].string == "LIKE" }
            .flatMap { text($0["defaultText"]) }
        let newLike = primary?.collect("likeButtonViewModel").first?.collect("buttonViewModel").first?["title"].string
        let comments = initial?.collect("commentsHeaderRenderer").lazy.compactMap { text($0["countText"]).flatMap(withCount) }.first
            ?? initial?.collect("commentsEntryPointHeaderRenderer").first.flatMap { text($0["commentCount"]) }.flatMap(withCount)
            ?? initial?.collect("engagementPanelSectionListRenderer").first {
                $0["targetId"].string == "engagement-panel-comments-section" || $0["panelIdentifier"].string == "engagement-panel-comments-section"
            }?.collect("engagementPanelTitleHeaderRenderer").first.flatMap { text($0["contextualInfo"]) }.flatMap(withCount)
        let views = details["viewCount"].string.flatMap { (Int64($0) ?? -1) >= 0 ? $0 : nil }
        return SongInfo(releaseDate: releaseDate(details["shortDescription"].string), views: views,
                        likes: (newLike ?? oldLike).flatMap(withCount), comments: comments, failed: initial == nil)
    }

    /** Catalogue uploads state "Released on: YYYY-MM-DD"; an upload date never stands in for it. */
    private static func releaseDate(_ description: String?) -> String? {
        description?.components(separatedBy: .newlines).lazy.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: #"^Released on:\s*(\d{4}-\d{2}-\d{2})$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
            return String(trimmed[range].suffix(10))
        }.first
    }

    private static func withCount(_ text: String) -> String? { text.contains(where: \.isNumber) ? text : nil }

    private static func text(_ node: JSON) -> String? {
        node.runs.nonBlank
    }

    /** Balanced extraction of `name = {…}`, tolerating braces inside strings and trailing statements. */
    private static func extract(_ html: String, _ name: String) -> JSON? {
        guard let assignment = html.range(of: "(?:var\\s+)?\(name)\\s*=\\s*", options: .regularExpression) else { return nil }
        let bytes = Array(html.utf8[assignment.upperBound...])
        guard bytes.first == UInt8(ascii: "{") else { return nil }
        var depth = 0, quoted = false, escaped = false
        for (i, c) in bytes.enumerated() {
            if quoted {
                if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true } else if c == UInt8(ascii: "\"") { quoted = false }
            } else if c == UInt8(ascii: "\"") {
                quoted = true
            } else if c == UInt8(ascii: "{") {
                depth += 1
            } else if c == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(bytes[0...i])) else { return nil }
                    return JSON(object)
                }
            }
        }
        return nil
    }
}

/**
 * A row's album and artist when it didn't arrive with them, read off the
 * track's own watch entry (trackLinks) the first time a menu asks.
 */
@MainActor
@Observable
final class TrackLinks {
    static let shared = TrackLinks()

    private(set) var links: [String: Song] = [:]
    private(set) var resolving: Set<String> = []

    /** A different listener: what they can open is read afresh. */
    func reset() { links = [:] }

    func resolve(_ song: Song) async {
        guard song.albumId == nil || (song.artistId == nil && song.artists.first?.browseId == nil),
              links[song.videoId] == nil, !resolving.contains(song.videoId) else { return }
        resolving.insert(song.videoId)
        defer { resolving.remove(song.videoId) }
        if let linked = try? await Innertube.shared.trackLinks(song.videoId) { links[song.videoId] = linked }
    }
}
