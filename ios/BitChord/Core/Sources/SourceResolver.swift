import Foundation

/**
 * Turning a YouTube track into another source's copy of it (SourceResolver):
 * each source ranked above YouTube is searched with the matcher's queries,
 * its rows ranked, and its best few asked for a stream at the tier the
 * connection allows. The first source with an answer settles it, unless a
 * later one is better.
 */
enum SourceResolver {
    /** What one source found: its id for the track, the matcher's view of the row, and the tier its row advertises. */
    private struct Hit: Sendable {
        var id: String
        var candidate: TrackMatcher.Candidate
        var tier: String?
        var streamURL: String?
    }

    private static let matchCandidates = 15
    private static let streamAttempts = 3
    private static let sameRecordingSec = 3
    /** A swap mid-song has to be the same cut: within two seconds of what is playing. */
    static let upgradeDriftSec = 2

    /** Codecs this phone's player can open from a URL; Opus, Vorbis and WebM it can't. */
    private static let playableCodecs: Set<String> = ["flac", "alac", "wav", "aiff", "mp3", "aac", "he-aac", "m4a", "mp4"]
    private static let audioCodecs: Set<String> = ["flac", "alac", "wav", "aiff", "mp3", "aac", "he-aac", "m4a", "mp4", "ogg", "opus", "vorbis", "webm", "eac3-joc", "ec3-joc"]

    @MainActor
    static func requestForNow() -> StreamRequest {
        switch AppSettings.shared.audioQuality {
        case .lossless: return .lossless
        case .low: return .capped(64)
        case .medium, .high: return .best
        }
    }

    /**
     * The best copy across [sources] (bestAcross): all asked at once, the first
     * answer taken unless one that arrives with it is better.
     */
    static func best(for target: TrackMatcher.Target, in sources: [SourceConfig], request: StreamRequest,
                     clients: [String: AddonClient]) async -> SourceStream? {
        guard !target.title.isEmpty, !target.isVideo, !sources.isEmpty else { return nil }
        return await withTaskGroup(of: SourceStream?.self) { group in
            for source in sources {
                group.addTask { await matchAndStream(source, client: clients[source.id], target: target, request: request) }
            }
            var best: SourceStream?
            for await found in group {
                guard let found else { continue }
                if isBetter(found.format, than: best?.format) { best = found }
                if best != nil {
                    group.cancelAll()
                    break
                }
            }
            return best
        }
    }

    private static func matchAndStream(_ source: SourceConfig, client: AddonClient?, target: TrackMatcher.Target,
                                       request: StreamRequest) async -> SourceStream? {
        for query in TrackMatcher.queries(target) {
            guard !Task.isCancelled else { return nil }
            let hits = await search(source, client: client, query: query, request: request)
            let byKey = Dictionary(hits.map { (key($0.candidate), $0) }, uniquingKeysWith: { a, _ in a })
            var matches = TrackMatcher.ranked(hits.map(\.candidate), target)
            if source.kind == .jioSaavn, TrackMatcher.hasConflictingAlbums(matches, target) {
                // A catalogue that can't agree which album this is: refuse to guess, unless one credit is uniquely fullest.
                guard let canonical = TrackMatcher.uniquelyMostCreditedCloseMatch(matches, target) else { continue }
                matches = [canonical]
            }
            let ranked = matches.compactMap { byKey[key($0)] }
            guard !ranked.isEmpty else { continue }
            return await streamBest(source, client: client, ranked, target: target, request: request)
        }
        return nil
    }

    private static func key(_ candidate: TrackMatcher.Candidate) -> String {
        "\(candidate.title)|\(candidate.artist)|\(candidate.album ?? "")|\(candidate.durationSec ?? -1)"
    }

    /** Same-length rows first, and the lossless-tier rows first among those when lossless is asked for. */
    private static func streamBest(_ source: SourceConfig, client: AddonClient?, _ hits: [Hit], target: TrackMatcher.Target,
                                   request: StreamRequest) async -> SourceStream? {
        let wantsLossless = request == .lossless
        let sameLength = hits.filter { TrackMatcher.withinSeconds($0.candidate, target, sameRecordingSec) }
        var eligible = sameLength.isEmpty ? hits : sameLength
        if wantsLossless { eligible = eligible.filter { $0.tier == "LOSSLESS" } + eligible.filter { $0.tier != "LOSSLESS" } }
        var settleFor: SourceStream?
        for hit in eligible.prefix(streamAttempts) {
            guard !Task.isCancelled else { return settleFor }
            guard var stream = await stream(source, client: client, hit, request: request) else { continue }
            stream.durationSec = hit.candidate.durationSec
            stream.sourceName = source.displayName
            let format = stream.format
            if !wantsLossless || format.isLossless == true || (format.isLossless == nil && format.kbps == nil) {
                Log.d("\(source.displayName) matched '\(hit.candidate.title)' by '\(hit.candidate.artist)' → \(format.summary)")
                return stream
            }
            stream.belowRequest = true
            if settleFor == nil || isBetter(format, than: settleFor?.format) { settleFor = stream }
        }
        return settleFor
    }

    static func isBetter(_ candidate: StreamFormat, than current: StreamFormat?) -> Bool {
        guard let current else { return true }
        if candidate.isDolbyAtmos != current.isDolbyAtmos { return candidate.isDolbyAtmos }
        if candidate.isLossless != current.isLossless { return candidate.isLossless == true }
        return (candidate.kbps ?? 0) > (current.kbps ?? 0)
    }

    /** Lossless or Atmos always; otherwise only for a real gain (96 kbps) over what's playing. */
    static func worthSwapping(_ candidate: StreamFormat, over playingKbps: Int?) -> Bool {
        if candidate.isLossless == true || candidate.isDolbyAtmos { return true }
        guard let kbps = candidate.kbps, let playing = playingKbps else { return false }
        return kbps - playing >= 96
    }

    // MARK: Per kind

    private static func search(_ source: SourceConfig, client: AddonClient?, query: String, request: StreamRequest) async -> [Hit] {
        switch source.kind {
        case .addon:
            guard let client, let tracks = try? await client.search(query, tier: request.tier) else { return [] }
            return tracks.filter { !$0.isAtmos }.prefix(matchCandidates).map { track in
                Hit(id: track.id,
                    candidate: .init(title: track.title, artist: track.artist, album: track.album.nonBlank, durationSec: track.durationSec, isExplicit: nil),
                    tier: qualityTier("\(track.audioQuality) \(track.format)"), streamURL: track.streamURL)
            }
        case .jioSaavn:
            return await JioSaavn.search(query).prefix(matchCandidates).map { row in
                Hit(id: row.id,
                    candidate: .init(title: row.title, artist: row.artist, album: row.album.nonBlank, durationSec: row.durationSec, isExplicit: row.isExplicit),
                    tier: "HIGH", streamURL: nil)
            }
        case .youtube:
            return []
        }
    }

    private static func stream(_ source: SourceConfig, client: AddonClient?, _ hit: Hit, request: StreamRequest) async -> SourceStream? {
        switch source.kind {
        case .addon:
            guard let client else { return nil }
            let answer = try? await client.stream(hit.id, tier: request.tier)
            let url = answer?.url.nonBlank ?? hit.streamURL
            guard let url, let link = URL(string: url), ["http", "https"].contains(link.scheme?.lowercased() ?? "") else { return nil }
            let json = answer?.json ?? JSON(["url": url])
            if let encrypted = json["encrypted"].string?.lowercased(), !["", "false", "none", "0"].contains(encrypted) { return nil }
            if json["encrypted"].bool == true { return nil }
            // A DASH manifest is something this phone's player can't open.
            let transport = (json["manifest"].string ?? json["mediaType"].string ?? json["format"].string ?? "").lowercased()
            if ["dash", "mpd", "application/dash+xml"].contains(transport) { return nil }
            let format = formatOf(json, url: url, tier: request.tier)
            if format.isDolbyAtmos { return nil }
            if let codec = format.codec, audioCodecs.contains(codec), !playableCodecs.contains(codec) {
                Log.w("\(source.displayName) answered with \(format.summary), which this phone can't play — passing")
                return nil
            }
            return SourceStream(url: link, format: format)
        case .jioSaavn:
            guard let found = await JioSaavn.stream(hit.id) else { return nil }
            if let kbps = found.kbps, kbps <= 96 { return nil }
            return SourceStream(url: found.url, format: StreamFormat(codec: "mp4", kbps: found.kbps))
        case .youtube:
            return nil
        }
    }

    /** What an addon's answer is, from what it states or failing that its labels and file name. */
    private static func formatOf(_ json: JSON, url: String, tier: String) -> StreamFormat {
        let qualityText = ["quality", "streamQuality", "audioQuality", "format"].compactMap { json[$0].string }.joined(separator: " ")
        let stated = (json["codec"].string?.nonBlank ?? json["fileCodec"].string?.nonBlank)?.lowercased()
        let container = (json["container"].string?.nonBlank ?? json["containerFormat"].string?.nonBlank)?.lowercased()
        let mime = json["mimeType"].string?.split(separator: "/").last?.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let ext = url.split(separator: "?").first?.split(separator: ".").last.map { String($0).lowercased() }
        let selfDescribing: Set<String> = ["flac", "wav", "mp3", "aiff"]
        let candidates: [String?] = [
            stated.flatMap { audioCodecs.contains($0) ? $0 : nil },
            container.flatMap { selfDescribing.contains($0) ? $0 : nil },
            mime.flatMap { audioCodecs.contains($0) ? $0 : nil },
            qualityTier(qualityText) == "LOSSLESS" ? "flac" : nil,
            ext.flatMap { audioCodecs.contains($0) ? $0 : nil },
        ]
        let codec: String? = candidates.compactMap { $0 }.first
        let bitrate: Double = json["bitrate"].double ?? 0
        let labelledKbps: Int? = firstNumber(#"(\d{2,4})\s*kbps"#, in: qualityText).map { Int($0) }
        let statedKbps: Int? = bitrate > 0 ? (bitrate > 3000 ? Int(bitrate / 1000) : Int(bitrate)) : labelledKbps
        let tierKbps = tier == "HIGH" ? 320 : tier == "LOW" ? 128 : nil
        let sampleRate: Double = json["sampleRate"].double ?? 0
        let labelledRate: Int? = firstNumber(#"([\d.]+)\s*kHz"#, in: qualityText).map { Int($0 * 1000) }
        let rate: Int? = sampleRate > 0 ? Int(sampleRate < 1000 ? sampleRate * 1000 : sampleRate) : labelledRate
        let depth: Double = json["bitDepth"].double ?? 0
        let labelledBits: Int? = firstNumber(#"(\d{1,2})\s*-?\s*bit"#, in: qualityText).map { Int($0) }
        let bits: Int? = depth > 0 ? Int(depth) : labelledBits.flatMap { (8...32).contains($0) ? $0 : nil }
        return StreamFormat(codec: codec, kbps: statedKbps ?? tierKbps, sampleRateHz: rate, bitDepth: bits)
    }

    private static func firstNumber(_ pattern: String, in text: String) -> Double? {
        let regex = NSRegularExpression(pattern, caseInsensitive: true)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }

    /** The three tiers every catalogue speaks, whatever it calls them. */
    static func qualityTier(_ label: String) -> String? {
        let text = label.uppercased()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if ["LOSSLESS", "FLAC", "ALAC", "HI-RES", "HI_RES", "HIRES", "24-BIT", "16-BIT", "WAV"].contains(where: text.contains) { return "LOSSLESS" }
        if ["LOW", "128", "96KBPS", "64"].contains(where: text.contains) { return "LOW" }
        if ["HIGH", "320", "MP3", "AAC", "M4A", "OPUS", "OGG"].contains(where: text.contains) { return "HIGH" }
        return nil
    }
}
