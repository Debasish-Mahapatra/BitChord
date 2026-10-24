import Foundation

/** The sources offered, in the phone's default order (LyricsSource), for the ones plain HTTPS reaches. */
enum LyricsSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case lrcRed, biniLyrics, betterLyrics, lyricsPlus, unison, lrclib, youTubeMusic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lrcRed: return "lrc.red"
        case .biniLyrics: return "BiniLyrics"
        case .betterLyrics: return "BetterLyrics"
        case .lyricsPlus: return "LyricsPlus"
        case .unison: return "Unison"
        case .lrclib: return "LRCLIB"
        case .youTubeMusic: return "YouTube Music"
        }
    }
}

/** What a lookup is about: the cleaned title and artist, the length and the album. */
struct LyricsQuery: Sendable {
    var videoId: String
    var title: String
    var artist: String
    var album: String?
    var durationSeconds: Double

    init(song: Song, duration: Double) {
        videoId = song.videoId
        title = LyricsQuery.forLyricsSearch(song.title)
        artist = song.artist.replacingOccurrences(of: #"\s+-\s+Topic$"#, with: "", options: .regularExpression)
        album = song.albumName
        durationSeconds = duration
    }

    private static let cleaners = [
        #"\s*[(\[]\s*(feat|ft|featuring|with)\b[^)\]]*[)\]]"#,
        #"\s+(feat|ft|featuring)\.?\s+.*$"#,
        #"\s*[(\[]\s*(official\s*)?(music\s*)?(video|audio|visuali[sz]er|lyrics?\s*video|lyrics?|m/?v|hd|hq|4k|full\s*song)\s*[)\]]"#,
        #"\s*[(\[]\s*official\s*[)\]]"#,
    ].map { NSRegularExpression($0, caseInsensitive: true) }

    /** forLyricsSearch(): featuring credits and video words out, version words (Remix, Live…) kept. */
    static func forLyricsSearch(_ title: String) -> String {
        var out = title
        for regex in cleaners {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: " ")
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",-–— "))
        return out.isEmpty ? title : out
    }
}

/** The providers' requests (LyricsProviders.kt and friends). */
enum LyricsProviders {
    private static let userAgent = "BitChord (https://github.com/bitchord)"

    static func fetch(_ source: LyricsSource, _ query: LyricsQuery) async -> [LyricLine]? {
        do {
            let lines: [LyricLine]?
            switch source {
            case .lrcRed: lines = try await lrcRed(query)
            case .biniLyrics: lines = try await biniLyrics(query)
            case .betterLyrics: lines = try await betterLyrics(query)
            case .lyricsPlus: lines = try await lyricsPlus(query)
            case .unison: lines = try await unison(query)
            case .lrclib: lines = try await lrclib(query)
            case .youTubeMusic: lines = try await youTubeMusic(query)
            }
            guard let lines, !lines.isEmpty, lines.contains(where: { !$0.isGap }) else { return nil }
            return LyricsPost.withBackgroundVocals(lines)
        } catch {
            return nil
        }
    }

    private static func get(_ base: String, _ params: [(String, String?)] = [], timeout: TimeInterval = 6, accept: Bool = true) async throws -> Data? {
        var components = URLComponents(string: base)!
        let items = params.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        if !items.isEmpty { components.queryItems = (components.queryItems ?? []) + items }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if accept { request.setValue("application/json", forHTTPHeaderField: "Accept") }
        let (data, response) = try await HTTP.session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return nil }
        return data
    }

    private static func seconds(_ query: LyricsQuery) -> String? {
        query.durationSeconds > 0 ? String(Int(query.durationSeconds.rounded())) : nil
    }

    // MARK: lrc.red

    /**
     * Searches lrc.red and takes the closest-length hit that is the same
     * recording: same core title, same version words, a shared artist, and
     * within 3 s.
     */
    private static func lrcRed(_ query: LyricsQuery) async throws -> [LyricLine]? {
        guard let data = try await get("https://lrc.red/search.json", [("q", "\(query.title) \(query.artist)")]) else { return nil }
        let hits = try JSON(data: data)["hits"].array
        let wantCore = coreTitle(query.title)
        let wantVersion = versionWords(query.title)
        let wantArtists = artistSet(query.artist)
        let matches = hits.filter { hit in
            guard let title = hit["title"].string, let artist = hit["artist"].string else { return false }
            guard coreTitle(title) == wantCore, versionWords(title) == wantVersion else { return false }
            guard !artistSet(artist).isDisjoint(with: wantArtists) else { return false }
            guard let duration = hit["duration"].double, query.durationSeconds > 0 else { return false }
            return abs(duration - query.durationSeconds) <= 3
        }
        guard let best = matches.min(by: { abs(($0["duration"].double ?? 0) - query.durationSeconds) < abs(($1["duration"].double ?? 0) - query.durationSeconds) }),
              let isrc = best["isrc"].string?.uppercased(), isrc.wholeMatch(isrcPattern),
              let ttml = try await get("https://lrc.red/s/\(isrc).ttml", accept: false),
              let text = String(data: ttml, encoding: .utf8) else { return nil }
        return TTMLParser.parse(text)
    }

    private static let isrcPattern = NSRegularExpression(#"[A-Z]{2}[A-Z0-9]{3}\d{7}"#)

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }

    private static func coreTitle(_ title: String) -> String {
        var core = title.replacingOccurrences(of: #"[(\[][^)\]]*[)\]]"#, with: " ", options: .regularExpression)
        if let dash = core.range(of: " - ") { core = String(core[..<dash.lowerBound]) }
        return fold(core).filter { $0.isLetter || $0.isNumber }
    }

    private static let versionVocabulary: Set<String> = [
        "live", "remix", "remixed", "mix", "acoustic", "unplugged", "instrumental", "karaoke", "cappella", "acapella", "demo",
        "edit", "version", "cover", "sped", "slowed", "reverb", "nightcore", "lofi", "orchestral", "extended",
    ]

    private static func versionWords(_ title: String) -> Set<String> {
        var extra = ""
        let range = NSRange(title.startIndex..., in: title)
        for match in NSRegularExpression(#"[(\[]([^)\]]*)[)\]]"#).matches(in: title, range: range) {
            extra += " " + (title as NSString).substring(with: match.range(at: 1))
        }
        if let dash = title.range(of: " - ") { extra += " " + title[dash.upperBound...] }
        let words = fold(extra).components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(words.filter(versionVocabulary.contains))
    }

    private static func artistSet(_ raw: String) -> Set<String> {
        let parts = fold(raw).replacingOccurrences(of: #",|&|;|/| and | x | with | feat\.? | ft\.? "#, with: "|", options: .regularExpression)
        return Set(parts.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    // MARK: The rest

    private static func biniLyrics(_ query: LyricsQuery) async throws -> [LyricLine]? {
        guard let data = try await get("https://lyrics-api.binimum.org/", [
            ("track", query.title), ("artist", query.artist), ("album", query.album), ("duration", seconds(query)),
        ]), let url = try JSON(data: data)["results"].first["lyricsUrl"].string,
            let body = try await get(url, accept: false), let text = String(data: body, encoding: .utf8) else { return nil }
        return ProviderLyrics.parse(text)
    }

    private static func betterLyrics(_ query: LyricsQuery) async throws -> [LyricLine]? {
        guard let data = try await get("https://lyrics-api.boidu.dev/getLyrics", [
            ("s", query.title), ("a", query.artist), ("d", seconds(query)), ("al", query.album),
        ]), let text = String(data: data, encoding: .utf8) else { return nil }
        return ProviderLyrics.parse(text)
    }

    /** The live mirrors raced; the first non-empty answer wins. */
    private static func lyricsPlus(_ query: LyricsQuery) async throws -> [LyricLine]? {
        let hosts = ["https://lyricsplus.prjktla.my.id", "https://lyricsplus.binimum.org"]
        let params: [(String, String?)] = [("title", query.title), ("artist", query.artist), ("duration", seconds(query)), ("album", query.album)]
        return await withTaskGroup(of: [LyricLine]?.self) { group in
            for host in hosts {
                group.addTask {
                    guard let data = try? await get("\(host)/v2/lyrics/get", params), let json = try? JSON(data: data) else { return nil }
                    let lines = ProviderLyrics.lyricsPlus(json)
                    return lines.isEmpty ? nil : lines
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    private static func unison(_ query: LyricsQuery) async throws -> [LyricLine]? {
        guard let data = try await get("https://unison.boidu.dev/lyrics", [
            ("song", query.title), ("artist", query.artist), ("album", query.album), ("duration", seconds(query)),
        ]) else { return nil }
        let json = try JSON(data: data)
        guard json["success"].bool == true, let lyrics = json["data"]["lyrics"].string else { return nil }
        if json["data"]["format"].string == "ttml" { return TTMLParser.parse(lyrics) }
        if json["data"]["syncType"].string == "plain" { return ProviderLyrics.plain(lyrics) }
        return LRCParser.parse(lyrics)
    }

    private static let lrclibNoise = NSRegularExpression(
        #"\((?:from|feat\.?|official|lyrical|video|audio|remix)[^)]*\)|\[[^\]]*\]|\b(?:official (?:video|audio|music video)|lyrical|full song|4k video)\b"#,
        caseInsensitive: true)

    /** `get` by title, artist and length, then `search` for the closest synced hit. */
    private static func lrclib(_ query: LyricsQuery) async throws -> [LyricLine]? {
        var title = lrclibNoise.stringByReplacingMatches(in: query.title, range: NSRange(query.title.startIndex..., in: query.title), withTemplate: "")
        if let bar = title.range(of: " | ") { title = String(title[..<bar.lowerBound]) }
        title = title.trimmingCharacters(in: .whitespaces)
        if let data = try await get("https://lrclib.net/api/get", [
            ("track_name", title), ("artist_name", query.artist), ("duration", seconds(query)),
        ], timeout: 20, accept: false),
           let synced = try? JSON(data: data)["syncedLyrics"].string, !synced.isEmpty {
            return LRCParser.parse(synced)
        }
        guard let data = try await get("https://lrclib.net/api/search", [("track_name", title), ("artist_name", query.artist)], timeout: 20, accept: false) else { return nil }
        let hits = try JSON(data: data).array.filter { ($0["syncedLyrics"].string ?? "").nonBlank != nil }
        let best = hits.min { abs(($0["duration"].double ?? 0) - query.durationSeconds) < abs(($1["duration"].double ?? 0) - query.durationSeconds) }
        return best?["syncedLyrics"].string.map(LRCParser.parse)
    }

    /** The lyrics tab of YouTube Music's own watch page: plain text. */
    private static func youTubeMusic(_ query: LyricsQuery) async throws -> [LyricLine]? {
        let next = try await Innertube.shared.next(videoId: query.videoId)
        guard let browseId = InnertubeParser.lyricsBrowseId(next) else { return nil }
        let page = try await Innertube.shared.browse(browseId)
        guard let plain = InnertubeParser.parsePlainLyrics(page) else { return nil }
        return plain.text.components(separatedBy: .newlines).map { LyricLine(time: 0, text: $0.trimmingCharacters(in: .whitespaces)) }
    }
}
