import CommonCrypto
import Foundation
import Observation

// MARK: - What a source answers with

/** What a stream claims to be (StreamFormat). */
struct StreamFormat: Equatable, Sendable {
    var codec: String?
    var kbps: Int?
    var sampleRateHz: Int?
    var bitDepth: Int?

    private static let losslessCodecs: Set<String> = ["flac", "alac", "wav", "aiff", "ape", "wv", "dsf", "dff"]
    private static let atmosCodecs: Set<String> = ["eac3-joc", "ec3-joc", "dolby-atmos"]

    var isLossless: Bool? { codec.map(Self.losslessCodecs.contains) }
    var isDolbyAtmos: Bool { codec.map(Self.atmosCodecs.contains) ?? false }

    var summary: String {
        if isDolbyAtmos { return "Dolby Atmos" }
        let rate = sampleRateHz.map { hz -> String in
            let khz = String(format: "%.1f", Double(hz) / 1000)
            return (khz.hasSuffix(".0") ? String(khz.dropLast(2)) : khz) + " kHz"
        }
        let parts = [codec?.uppercased(), bitDepth.map { "\($0)-bit" }, rate, isLossless == true ? nil : kbps.map { "\($0) kbps" }]
        let joined = parts.compactMap { $0 }.joined(separator: " · ")
        return joined.isEmpty ? "Unknown format" : joined
    }
}

/** A URL the player can open, and what is expected to come out of it (SourceStream). */
struct SourceStream: Sendable {
    var url: URL
    var format = StreamFormat()
    var headers: [String: String] = [:]
    /** Less than was asked for, taken because nothing better turned up. */
    var belowRequest = false
    /** How long the catalogue says this recording is. */
    var durationSec: Int?
    var sourceName = ""
}

/** How much of the stream the caller will pay for (StreamRequest). */
enum StreamRequest: Equatable, Sendable {
    case lossless
    case capped(Int)
    case best

    /** An addon's tier names. */
    var tier: String {
        switch self {
        case .lossless: return "LOSSLESS"
        case .best: return "HIGH"
        case .capped(let kbps): return kbps <= 128 ? "LOW" : "HIGH"
        }
    }
}

// MARK: - Configured sources

/** The kinds of source this build speaks to (SourceKind); [rank] is the order they're tried in. */
enum SourceKind: String, Codable, Sendable {
    case addon = "ADDON"
    case jioSaavn = "JIOSAAVN"
    case youtube = "YOUTUBE"

    var label: String {
        switch self {
        case .addon: return "Addon"
        case .jioSaavn: return "JioSaavn"
        case .youtube: return "YouTube Music"
        }
    }

    var labels: [String] {
        switch self {
        case .addon: return ["FLAC", "Lossless", "Hi-Res"]
        case .jioSaavn: return ["High Quality", "320kbps"]
        case .youtube: return ["Lossy", "Full catalogue", "Radio"]
        }
    }

    var canServeLossless: Bool { self == .addon }
    var rank: Int { self == .addon ? 0 : self == .jioSaavn ? 2 : 3 }
}

/** One configured instance (SourceConfig). JioSaavn starts switched off. */
struct SourceConfig: Codable, Identifiable, Hashable, Sendable {
    var id = UUID().uuidString
    var kind: SourceKind
    var label = ""
    var baseUrl = ""
    var enabled: Bool

    init(kind: SourceKind, label: String = "", baseUrl: String = "", enabled: Bool? = nil) {
        self.kind = kind
        self.label = label
        self.baseUrl = baseUrl
        self.enabled = enabled ?? (kind != .jioSaavn)
    }

    var displayName: String {
        if !label.isEmpty { return label }
        if let host = URL(string: baseUrl)?.host, !host.isEmpty { return host }
        return kind.label
    }
}

enum SourceHealth: Sendable {
    case ok(String?)
    case unreachable(String)
    case rejected(String)
}

/**
 * The sources and their order (SourceRegistry): the addons the user added,
 * in their order, then JioSaavn, then YouTube Music, which can't be removed.
 */
@MainActor
@Observable
final class SourceRegistry {
    static let shared = SourceRegistry()

    private(set) var configs: [SourceConfig]
    private(set) var health: [String: SourceHealth] = [:]
    @ObservationIgnored private var clients: [String: AddonClient] = [:]

    private init() {
        let stored = UserDefaults.standard.data(forKey: "sources.configs").flatMap { try? JSONDecoder().decode([SourceConfig].self, from: $0) } ?? []
        var configs = stored
        if !configs.contains(where: { $0.kind == .jioSaavn }) { configs.append(SourceConfig(kind: .jioSaavn)) }
        if !configs.contains(where: { $0.kind == .youtube }) { configs.append(SourceConfig(kind: .youtube)) }
        self.configs = configs.map { $0.kind == .youtube ? { var c = $0; c.enabled = true; return c }($0) : $0 }
    }

    /** In the order they are tried. */
    var ordered: [SourceConfig] {
        configs.filter { $0.kind == .addon } + configs.filter { $0.kind != .addon }.sorted { $0.kind.rank < $1.kind.rank }
    }

    /** Enabled sources ranked above YouTube — the ones that can stand in for its copy. */
    var substitutes: [SourceConfig] {
        let ordered = ordered.filter(\.enabled)
        return Array(ordered.prefix { $0.kind != .youtube })
    }

    func client(for config: SourceConfig) -> AddonClient {
        if let client = clients[config.id], client.baseUrl == AddonClient.normalizeBase(config.baseUrl) { return client }
        let client = AddonClient(config.baseUrl)
        clients[config.id] = client
        return client
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = configs.firstIndex(where: { $0.id == id }), configs[index].kind != .youtube else { return }
        configs[index].enabled = enabled
        save()
    }

    func add(_ config: SourceConfig) {
        configs.insert(config, at: configs.lastIndex { $0.kind == .addon }.map { $0 + 1 } ?? 0)
        save()
        Task { await check(config) }
    }

    func update(_ config: SourceConfig) {
        guard let index = configs.firstIndex(where: { $0.id == config.id }) else { return }
        configs[index] = config
        clients[config.id] = nil
        save()
        Task { await check(config) }
    }

    func remove(_ id: String) {
        configs.removeAll { $0.id == id && $0.kind == .addon }
        clients[id] = nil
        health[id] = nil
        save()
    }

    func moveAddon(from source: IndexSet, to destination: Int) {
        var addons = configs.filter { $0.kind == .addon }
        addons.move(fromOffsets: source, toOffset: destination)
        configs = addons + configs.filter { $0.kind != .addon }
        save()
    }

    /** An addon already added at the same address. */
    func duplicate(of baseUrl: String, except id: String?) -> SourceConfig? {
        let base = AddonClient.normalizeBase(baseUrl)
        return configs.first { $0.kind == .addon && $0.id != id && AddonClient.normalizeBase($0.baseUrl) == base }
    }

    func checkAll() async {
        for config in configs where config.kind == .addon { await check(config) }
    }

    func check(_ config: SourceConfig) async {
        health[config.id] = await client(for: config).health()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(configs) { UserDefaults.standard.set(data, forKey: "sources.configs") }
    }
}

// MARK: - Addons

/**
 * One addon server (AddonClient): `/manifest.json`, `/search?q=`,
 * `/stream/<id>` — JSON both ways, nothing executed on this side. Answers are
 * kept a few minutes; a 429 quiets the whole client for as long as it asked.
 */
actor AddonClient {
    struct Manifest: Sendable {
        var id: String
        var name: String
        var version: String
        var resources: [String]
        /** key → (default, options) */
        var settings: [(key: String, defaultValue: String?, options: [String])]

        var displayName: String { name.isEmpty ? id : name }
        var isPlayable: Bool { resources.isEmpty || resources.contains { $0.caseInsensitiveCompare("search") == .orderedSame } }
    }

    struct Track: Sendable {
        var id: String
        var title: String
        var artist: String
        var album: String
        var durationSec: Int?
        var artwork: String?
        var format: String
        var audioQuality: String
        var streamURL: String?
        var isAtmos: Bool
    }

    struct Stream: Sendable {
        var url: String
        var json: JSON
    }

    enum Failure: Error, LocalizedError {
        case notFound
        case rejected(String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .notFound: return "Not held by this addon"
            case .rejected(let reason), .unavailable(let reason): return reason
            }
        }
    }

    nonisolated let baseUrl: String
    private var manifestCache: (Date, Manifest)?
    private var searches: [String: (Date, [Track])] = [:]
    private var streams: [String: (Date, Stream)] = [:]
    private var quietUntil = Date.distantPast

    init(_ rawBaseUrl: String) {
        baseUrl = Self.normalizeBase(rawBaseUrl)
    }

    /** Trailing slashes and a pasted `/manifest.json` off. */
    nonisolated static func normalizeBase(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        let last = trimmed.split(separator: "/").last.map(String.init) ?? ""
        if last.lowercased().hasSuffix(".json"), trimmed.contains("://") {
            trimmed.removeLast(last.count)
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
        }
        return trimmed
    }

    func manifest() async throws -> Manifest {
        if let (at, cached) = manifestCache, Date().timeIntervalSince(at) < 600 { return cached }
        let json: JSON
        do {
            json = try await fetch(baseUrl + "/manifest.json")
        } catch Failure.notFound {
            throw Failure.rejected("No manifest at that URL")
        }
        let manifest = Manifest(
            id: json["id"].string ?? "", name: json["name"].string ?? "", version: json["version"].string ?? "",
            resources: json["resources"].array.compactMap(\.string),
            settings: json["settings"].array.compactMap { setting in
                guard let key = setting["key"].string, !key.isEmpty else { return nil }
                return (key, setting["default"].string?.nonBlank, setting["options"].array.compactMap { $0["value"].string?.nonBlank })
            })
        guard !manifest.id.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure.rejected("That URL answered, but not with an addon manifest") }
        guard manifest.isPlayable else {
            throw Failure.rejected("This addon declares \(manifest.resources.joined(separator: ", ")) — BitChord needs search")
        }
        manifestCache = (Date(), manifest)
        return manifest
    }

    func health() async -> SourceHealth {
        guard !baseUrl.isEmpty else { return .rejected("An addon URL is required") }
        do {
            let manifest = try await manifest()
            let detail = [manifest.displayName.nonBlank, manifest.version.nonBlank.map { "v\($0)" }].compactMap { $0 }.joined(separator: " ")
            return .ok(detail.nonBlank)
        } catch {
            // The manifest describes an addon; the endpoints are the addon.
            if (try? await fetch(endpoint(["search"], ["q": "music"]))) != nil { return .ok("No manifest · search works") }
            if case Failure.rejected(let reason) = error { return .rejected(reason) }
            return .unreachable(error.localizedDescription)
        }
    }

    func search(_ query: String, tier: String) async throws -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let params = await settings(for: tier)
        let key = trimmed + "|" + params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        if let (at, cached) = searches[key], Date().timeIntervalSince(at) < 600 { return cached }
        let json = try await fetch(endpoint(["search"], params.merging(["q": trimmed]) { $1 }))
        let tracks = json["tracks"].array.compactMap { row -> Track? in
            guard let id = row["id"].string?.nonBlank, let title = row["title"].string?.nonBlank else { return nil }
            let hint = [row["audioQuality"].string, row["audioMode"].string, row["format"].string].compactMap { $0 }.joined(separator: " ")
                + " " + row["audioModes"].array.compactMap(\.string).joined(separator: " ")
            return Track(id: id, title: title, artist: row["artist"].string ?? "", album: row["album"].string ?? "",
                         durationSec: row["duration"].double.flatMap { $0 > 0 ? Int($0) : nil },
                         artwork: row["artworkURL"].string?.nonBlank ?? row["albumArtworkURL"].string?.nonBlank,
                         format: row["format"].string ?? "", audioQuality: row["audioQuality"].string ?? "",
                         streamURL: row["streamURL"].string?.nonBlank,
                         isAtmos: row["atmos"].bool == true || hint.range(of: #"atmos|dolby|eac3[_-]?joc|ec-?3"#, options: [.regularExpression, .caseInsensitive]) != nil)
        }
        searches[key] = (Date(), tracks)
        return tracks
    }

    func stream(_ trackId: String, tier: String) async throws -> Stream {
        let params = await settings(for: tier)
        let key = trackId + "|" + params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        if let (at, cached) = streams[key], Date().timeIntervalSince(at) < 300 { return cached }
        let json = try await fetch(endpoint(["stream", trackId], params))
        let stream = Stream(url: json["url"].string ?? "", json: json)
        streams[key] = (Date(), stream)
        return stream
    }

    /**
     * The addon's declared defaults, then `quality` set to the tier asked for —
     * negotiated against the options it enumerates, since an addon offering
     * `high|normal|low` understands none of this app's tier names.
     */
    private func settings(for tier: String) async -> [String: String] {
        let declared = (try? await manifest())?.settings ?? []
        var params: [String: String] = [:]
        for setting in declared { if let value = setting.defaultValue { params[setting.key] = value } }
        let options = declared.first { $0.key == "quality" }?.options ?? []
        params["quality"] = Self.matchTier(tier, options) ?? tier
        return params
    }

    private static func matchTier(_ tier: String, _ options: [String]) -> String? {
        guard !options.isEmpty else { return nil }
        if let exact = options.first(where: { $0.caseInsensitiveCompare(tier) == .orderedSame }) { return exact }
        let wanted: [String]
        switch tier.uppercased() {
        case "LOSSLESS": wanted = ["lossless", "flac", "hifi", "hi-res", "hires", "max", "best"]
        case "LOW": wanted = ["low", "96", "128", "min"]
        default: wanted = ["high", "320", "normal", "standard"]
        }
        return options.first { option in wanted.contains { option.lowercased().contains($0) } } ?? options.first
    }

    private func endpoint(_ segments: [String], _ params: [String: String]) -> String {
        guard var components = URLComponents(string: baseUrl) else { return baseUrl }
        let path = segments.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? $0 }
        components.percentEncodedPath = (components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath)
            + "/" + path.joined(separator: "/")
        components.queryItems = params.isEmpty ? nil : params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url?.absoluteString ?? baseUrl
    }

    private func fetch(_ urlString: String) async throws -> JSON {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw Failure.rejected("That is not a usable address")
        }
        var attempt = 0
        while true {
            let wait = quietUntil.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("BitChord/iOS", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await HTTP.session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200..<300:
                guard !data.isEmpty, let json = try? JSON(data: data) else { throw Failure.rejected("Empty response") }
                return json
            case 404: throw Failure.notFound
            case 500...: throw Failure.unavailable("HTTP \(code)")
            case 429 where attempt < 2:
                let stated = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                quietUntil = Date().addingTimeInterval(min(8, max(0.5, stated ?? 0.5 * pow(2, Double(attempt)))))
                attempt += 1
            case 429: throw Failure.unavailable("This addon is rate limiting BitChord")
            default: throw Failure.rejected("HTTP \(code)")
            }
        }
    }
}

// MARK: - JioSaavn

/** JioSaavn's own API (JioSaavnService): a search, and a song's DES-wrapped media URL, upgraded to 320 kbps where offered. */
enum JioSaavn {
    struct Row: Sendable {
        var id: String
        var title: String
        var artist: String
        var album: String
        var durationSec: Int?
        var image: String
        var isExplicit: Bool
    }

    private static let base = String(data: Data(base64Encoded: "aHR0cHM6Ly93d3cuamlvc2Fhdm4uY29tL2FwaS5waHA=")!, encoding: .utf8)!

    private static func get(_ params: [String: String]) async throws -> JSON {
        var components = URLComponents(string: base)!
        components.queryItems = (["_format": "json", "_marker": "0", "api_version": "4", "ctx": "android"].merging(params) { $1 })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 6)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("49.36.0.1", forHTTPHeaderField: "X-Forwarded-For")
        request.setValue("49.36.0.1", forHTTPHeaderField: "X-Real-IP")
        request.setValue("en-IN,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("explicit_content=1", forHTTPHeaderField: "Cookie")
        let (data, response) = try await HTTP.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AddonClient.Failure.unavailable("JioSaavn HTTP error") }
        return try JSON(data: data)
    }

    private static func row(_ raw: JSON) -> Row {
        let info = raw["more_info"]
        let artists = info["artistMap"]["primary_artists"].array.compactMap { $0["name"].string }.joined(separator: ", ")
        let explicit = raw["explicit_content"].string
        return Row(id: raw["id"].string ?? "", title: raw["title"].string ?? "", artist: artists.isEmpty ? "Unknown Artist" : artists,
                   album: info["album"].string ?? "", durationSec: info["duration"].string.flatMap(Int.init),
                   image: (raw["image"].string ?? "").replacingOccurrences(of: "150x150", with: "500x500")
                       .replacingOccurrences(of: "50x50", with: "500x500").replacingOccurrences(of: "http://", with: "https://"),
                   isExplicit: explicit == "1" || explicit?.lowercased() == "true")
    }

    /** Explicit rows first, as the phone ranks them. */
    static func search(_ query: String) async -> [Row] {
        guard let json = try? await get(["__call": "search.getResults", "q": query, "p": "1", "n": "10"]) else { return [] }
        let rows = json["results"].array.map(row)
        return rows.filter(\.isExplicit) + rows.filter { !$0.isExplicit }
    }

    static func stream(_ id: String) async -> (url: URL, kbps: Int?)? {
        guard let json = try? await get(["__call": "song.getDetails", "pids": id]) else { return nil }
        let song = json["songs"].array.first ?? json[id]
        let info = song["more_info"]
        guard let encrypted = info["encrypted_media_url"].string, let decrypted = decrypt(encrypted), !decrypted.isEmpty else { return nil }
        let supports320 = info["320kbps"].string?.lowercased() == "true"
        let pattern = NSRegularExpression(#"_(48|96|160|320)\.(mp4|aac|mp3)(?=[?#]|$)"#, caseInsensitive: true)
        guard let match = pattern.firstMatch(in: decrypted, range: NSRange(decrypted.startIndex..., in: decrypted)),
              let whole = Range(match.range, in: decrypted), let rate = Range(match.range(at: 1), in: decrypted),
              let ext = Range(match.range(at: 2), in: decrypted) else {
            return URL(string: decrypted).map { ($0, nil) }
        }
        let offered = Int(decrypted[rate])
        guard supports320 else { return URL(string: decrypted).map { ($0, offered) } }
        let upgraded = decrypted.replacingCharacters(in: whole, with: "_320.\(decrypted[ext])")
        return URL(string: upgraded).map { ($0, 320) }
    }

    /** DES/ECB/PKCS5 with JioSaavn's well-known key. */
    private static func decrypt(_ base64: String) -> String? {
        guard let input = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        let key = Array("38346591".utf8)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeDES)
        var moved = 0
        let status = input.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                    key, kCCKeySizeDES, nil, bytes.baseAddress, input.count, &output, output.count, &moved)
        }
        guard status == kCCSuccess else { return nil }
        return String(bytes: output.prefix(moved), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
