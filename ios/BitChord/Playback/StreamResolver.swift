import Foundation

/** A googlevideo audio URL, and the identity its media fetch has to wear. */
struct ResolvedStream: Sendable {
    let videoId: String
    let url: URL
    let contentLength: Int64
    let mimeType: String
    let bitrate: Int
    let client: PlayerClient
    let expiresAt: Date
    let loudnessDb: Double?
    let durationSeconds: Double?
    /** Where the init segment and the `sidx` index sit, as the format states them. */
    var initRange: ClosedRange<Int64>?
    var indexRange: ClosedRange<Int64>?

    var isFresh: Bool { expiresAt.timeIntervalSinceNow > 120 }

    /** The URL for bytes [range], as a bounded googlevideo range request. */
    func url(for range: ClosedRange<Int64>) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "range" }
        items.append(URLQueryItem(name: "range", value: "\(range.lowerBound)-\(range.upperBound)"))
        components.queryItems = items
        return components.url!
    }
}

enum StreamError: LocalizedError {
    /** No client will play it, for a reason that reads the same in ten seconds. */
    case unplayable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unplayable(let reason), .failed(let reason): return reason
        }
    }
}

/**
 * Which identity asks YouTube for a track, in order, following
 * StreamResolver.kt / InnerTubeXResolver.kt and the web player's resolver.ts:
 * walk the catalog, at most three clients per track; a client that refuses a
 * track sits out for ten minutes, and a settled "no" isn't asked again for ten.
 */
actor StreamResolver {
    static let shared = StreamResolver()

    static let clientAttempts = 3
    static let excludeInterval: TimeInterval = 10 * 60
    static let unplayableTTL: TimeInterval = 10 * 60

    private var unplayable: [String: (reason: String, at: Date)] = [:]
    private var excluded: [String: [String: Date]] = [:]
    private var resolved: [String: ResolvedStream] = [:]
    private var inFlight: [String: Task<ResolvedStream, Error>] = [:]

    /** A playable stream for [videoId], reusing a fresh one already minted. */
    func resolve(_ videoId: String) async throws -> ResolvedStream {
        if let cached = resolved[videoId], cached.isFresh, !isExcluded(videoId, cached.client.id) { return cached }
        if let task = inFlight[videoId] { return try await task.value }
        let task = Task { try await self.walk(videoId) }
        inFlight[videoId] = task
        defer { inFlight[videoId] = nil }
        let stream = try await task.value
        if resolved.count > 64 { resolved.removeAll() }
        resolved[videoId] = stream
        return stream
    }

    /** Records that [clientId]'s URL for [videoId] was refused, so the next walk skips it. */
    func exclude(_ videoId: String, clientId: String, why: String) {
        Log.w("\(clientId) refused: \(why); skipping it for this track", about: videoId)
        if excluded.count > 64 { excluded.removeAll() }
        excluded[videoId, default: [:]][clientId] = Date().addingTimeInterval(Self.excludeInterval)
        if resolved[videoId]?.client.id == clientId { resolved[videoId] = nil }
    }

    private func isExcluded(_ videoId: String, _ clientId: String) -> Bool {
        guard let until = excluded[videoId]?[clientId] else { return false }
        return until > Date()
    }

    private func walk(_ videoId: String) async throws -> ResolvedStream {
        if let verdict = unplayable[videoId] {
            if Date().timeIntervalSince(verdict.at) < Self.unplayableTTL { throw StreamError.unplayable(verdict.reason) }
            unplayable[videoId] = nil
        }
        let candidates = PlayerClient.catalog.filter { !isExcluded(videoId, $0.id) }.prefix(Self.clientAttempts)
        var lastReason = "No YouTube client would play this track"
        var permanent: String?
        var refreshedVisitor = false

        for client in candidates {
            var attempt = 0
            while attempt < 2 {
                attempt += 1
                let started = Date()
                do {
                    let response = try await playerRequest(client, videoId: videoId)
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    let status = response["playabilityStatus"]["status"].string
                    let reason = response["playabilityStatus"]["reason"].string
                    if status == "OK", let stream = Self.pick(response, videoId: videoId, client: client) {
                        let stream = try await withContentLength(stream)
                        Log.d("\(client.id) answered OK in \(ms)ms: itag \(stream.mimeType) \(stream.bitrate / 1000)kbps", about: videoId)
                        return stream
                    }
                    let why = reason ?? (status == "OK" ? "no AAC stream in the response" : status ?? "no status")
                    lastReason = why
                    // A visitor id can be burned while the session around it is fine; mint one fresh, once.
                    if why.localizedCaseInsensitiveContains("not a bot"), !refreshedVisitor {
                        refreshedVisitor = true
                        _ = await Innertube.shared.ensureVisitorData(refresh: true)
                        continue
                    }
                    if let verdict = Self.permanentReason(status: status, reason: why) { permanent = verdict }
                    exclude(videoId, clientId: client.id, why: "\(status ?? "?"): \(why) (\(ms)ms)")
                } catch {
                    lastReason = error.localizedDescription
                    exclude(videoId, clientId: client.id, why: "request failed: \(error.localizedDescription)")
                }
                break
            }
        }
        if let permanent {
            unplayable[videoId] = (permanent, Date())
            throw StreamError.unplayable(permanent)
        }
        throw StreamError.failed(lastReason)
    }

    /** The player request, as InnerTube.playerWithSession builds it for a direct-URL client. */
    private func playerRequest(_ client: PlayerClient, videoId: String) async throws -> JSON {
        let visitor = await Innertube.shared.ensureVisitorData()
        let base = client.useMusicPlayerEndpoint ? "https://music.youtube.com" : "https://www.youtube.com"
        let origin = base
        var request = URLRequest(url: URL(string: "\(base)/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        request.setValue(client.clientId, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin, forHTTPHeaderField: "X-Origin")
        request.setValue("\(origin)/", forHTTPHeaderField: "Referer")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ","), forHTTPHeaderField: "Accept-Language")
        if let visitor { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        var body: [String: Any] = [
            "context": client.context(visitorData: visitor),
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        if !client.useMusicPlayerEndpoint { body["videoCheckOk"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await HTTP.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw InnertubeError.status(code, "player") }
        return try JSON(data: data)
    }

    /**
     * The best AAC-in-MP4 audio format with a direct URL. AVPlayer can't open
     * WebM/Opus, so this is the phone's `requireM4a` ask: AudioQuality.MP4.
     */
    private static func pick(_ response: JSON, videoId: String, client: PlayerClient) -> ResolvedStream? {
        let formats = response["streamingData"]["adaptiveFormats"].array.filter {
            ($0["mimeType"].string ?? "").hasPrefix("audio/mp4") && $0["url"].string != nil
        }
        guard let best = formats.max(by: { ($0["bitrate"].double ?? 0) < ($1["bitrate"].double ?? 0) }),
              let urlString = best["url"].string, let url = URL(string: urlString) else { return nil }
        let expire = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "expire" }?.value.flatMap(Double.init)
        return ResolvedStream(
            videoId: videoId,
            url: url,
            contentLength: Int64(best["contentLength"].string ?? "") ?? 0,
            mimeType: best["mimeType"].string ?? "audio/mp4",
            bitrate: Int(best["bitrate"].double ?? 0),
            client: client,
            expiresAt: expire.map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(3 * 3600),
            loudnessDb: response["playerConfig"]["audioConfig"]["loudnessDb"].double,
            durationSeconds: best["approxDurationMs"].double.map { $0 / 1000 } ?? response["videoDetails"]["lengthSeconds"].double,
            initRange: range(best["initRange"]),
            indexRange: range(best["indexRange"])
        )
    }

    private static func range(_ json: JSON) -> ClosedRange<Int64>? {
        guard let start = json["start"].string.flatMap(Int64.init), let end = json["end"].string.flatMap(Int64.init), end >= start else { return nil }
        return start...end
    }

    /** Some responses leave out the length; ask googlevideo for it, as InnerTube.mediaContentLength. */
    private func withContentLength(_ stream: ResolvedStream) async throws -> ResolvedStream {
        guard stream.contentLength <= 0 else { return stream }
        var request = URLRequest(url: stream.url)
        request.httpMethod = "HEAD"
        stream.client.mediaHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (_, response) = try await HTTP.session.data(for: request)
        let length = (response as? HTTPURLResponse)?.expectedContentLength ?? -1
        guard length > 0 else { throw StreamError.failed("googlevideo didn't say how long the stream is") }
        return ResolvedStream(videoId: stream.videoId, url: stream.url, contentLength: length, mimeType: stream.mimeType,
                              bitrate: stream.bitrate, client: stream.client, expiresAt: stream.expiresAt,
                              loudnessDb: stream.loudnessDb, durationSeconds: stream.durationSeconds,
                              initRange: stream.initRange, indexRange: stream.indexRange)
    }

    /** Why a playability status is a verdict on the track rather than on the client (resolver.ts). */
    private static func permanentReason(status: String?, reason: String) -> String? {
        let text = reason.lowercased()
        if text.range(of: "confirm your age|age-restricted|inappropriate for some users|sign in to confirm your age", options: .regularExpression) != nil {
            return "This track is age-restricted. YouTube only plays it to a signed-in account."
        }
        if text.contains("country") || text.contains("region") { return "This track isn’t available in your country" }
        if text.contains("private") { return "This track is private" }
        if text.contains("terminated") { return "The channel behind this track was terminated" }
        if text.contains("premium") { return "This track needs YouTube Music Premium" }
        if status == "ERROR", text.range(of: "removed|no longer available|does not exist", options: .regularExpression) != nil {
            return "This track was removed from YouTube"
        }
        return nil
    }
}
