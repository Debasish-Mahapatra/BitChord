import Foundation

/** Shared networking: one session for InnerTube, lyrics and artwork. */
enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20)
        return URLSession(configuration: config)
    }()

    static let webUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
}

enum InnertubeError: LocalizedError {
    case status(Int, String)
    case badResponse
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .status(let code, let endpoint): return "YouTube Music answered \(code) to \(endpoint)"
        case .badResponse: return "YouTube Music sent something unreadable"
        case .refused(let message): return message
        }
    }
}

/**
 * The WEB_REMIX client every browse page, search and watch queue goes
 * through — Innertube.kt's `postMusic`, anonymous: no account, so nothing is
 * written to anyone's history.
 */
actor Innertube {
    static let shared = Innertube()

    static let musicBase = "https://music.youtube.com/youtubei/v1"
    static let musicOrigin = "https://music.youtube.com"
    static let webRemixVersion = "1.20260707.12.00"
    static let webRemixClientId = "67"

    private var visitorData: String?
    private var visitorTask: Task<String?, Never>?

    /** The signed-in session, read by every request; set from Account. */
    nonisolated(unsafe) private static var session: Session?
    private static let sessionLock = NSLock()

    nonisolated static func setSession(_ session: Session?) {
        sessionLock.withLock { self.session = session }
    }

    nonisolated static var currentSession: Session? { sessionLock.withLock { session } }

    nonisolated static var language: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    nonisolated static var region: String {
        Locale.current.region?.identifier ?? "US"
    }

    // MARK: Visitor id

    /**
     * A visitor id for this session, minting one if there isn't one yet
     * (Innertube.ensureVisitorData). [refresh] discards a burned one — worth
     * doing once when a request comes back accusing us of being a bot.
     */
    func ensureVisitorData(refresh: Bool = false) async -> String? {
        if !refresh, let visitorData { return visitorData }
        if let visitorTask { return await visitorTask.value }
        let task = Task { await Innertube.fetchVisitorData() }
        visitorTask = task
        let fresh = await task.value
        visitorTask = nil
        if let fresh { visitorData = fresh }
        return visitorData
    }

    /**
     * The service worker bootstrap the web player loads first, which hands out
     * a fresh visitor id without a page. Anti-hijacking prefix, then nested
     * arrays, so the id is found by its shape.
     */
    private static func fetchVisitorData() async -> String? {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/sw.js_data")!)
        request.setValue(HTTP.webUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await HTTP.session.data(for: request),
              let body = String(data: data, encoding: .utf8) else { return nil }
        let payload = body.firstIndex(of: "\n").map { String(body[body.index(after: $0)...]) } ?? String(body.dropFirst(5))
        guard let json = try? JSON(data: Data(payload.utf8)) else { return nil }
        func find(_ node: Any) -> String? {
            if let array = node as? [Any] { return array.lazy.compactMap(find).first }
            if let string = node as? String, string.wholeMatch(visitorPattern) { return string }
            return nil
        }
        return json.raw.flatMap(find)
    }

    private static let visitorPattern = NSRegularExpression(#"Cg[A-Za-z0-9_%-]{40,}"#)

    // MARK: Endpoints

    func browse(_ browseId: String, params: String? = nil) async throws -> JSON {
        var body: [String: Any] = ["browseId": browseId]
        if let params { body["params"] = params }
        return try await post("browse", body: body)
    }

    /** The next page of a paged browse; YouTube Music takes the token in the query as well. */
    func browseContinuation(_ token: String) async throws -> JSON {
        try await post("browse", body: ["continuation": token],
                       query: ["ctoken": token, "continuation": token, "type": "next"])
    }

    /** Anonymous by default, so a search isn't written to the account's history (Innertube.search). */
    func search(_ query: String, params: String? = nil) async throws -> JSON {
        var body: [String: Any] = ["query": query]
        if let params { body["params"] = params }
        return try await post("search", body: body, anonymous: true)
    }

    func accountMenu() async throws -> JSON {
        try await post("account/account_menu", body: [:])
    }

    /** Every channel this login can act as, each with the page id and data-sync id a request needs to act as it. */
    func accountsList() async throws -> JSON {
        try await post("account/accounts_list", body: [:])
    }

    /** A thumbs rating on a track: like, dislike, or back to none. */
    func rate(_ videoId: String, _ status: LikeStatus) async throws {
        let endpoint: String
        switch status {
        case .like: endpoint = "like/like"
        case .dislike: endpoint = "like/dislike"
        case .indifferent: endpoint = "like/removelike"
        }
        try Self.refused(await post(endpoint, body: ["target": ["videoId": videoId]]))
    }

    /** Saves or unsaves an album or playlist (by its playlist id). */
    func savePlaylist(_ playlistId: String, _ saved: Bool) async throws {
        try Self.refused(await post(saved ? "like/like" : "like/removelike", body: ["target": ["playlistId": playlistId]]))
    }

    func setSubscribed(_ channelId: String, _ subscribed: Bool) async throws {
        try Self.refused(await post(subscribed ? "subscription/subscribe" : "subscription/unsubscribe", body: ["channelIds": [channelId]]))
    }

    enum Privacy: String, CaseIterable, Identifiable, Sendable {
        case `private` = "PRIVATE", unlisted = "UNLISTED", `public` = "PUBLIC"

        var id: String { rawValue }
        var label: String { rawValue.prefix(1) + rawValue.dropFirst().lowercased() }
        var icon: String {
            switch self {
            case .private: return "lock"
            case .unlisted: return "link"
            case .public: return "globe"
            }
        }
    }

    /** A new playlist, seeded with [videoIds] in the same request; returns its id. */
    func createPlaylist(title: String, privacy: Privacy, videoIds: [String] = []) async throws -> String {
        var body: [String: Any] = ["title": title, "description": "", "privacyStatus": privacy.rawValue]
        if !videoIds.isEmpty { body["videoIds"] = videoIds }
        let response = try await post("playlist/create", body: body)
        try Self.refused(response)
        guard let id = response["playlistId"].string ?? response.findString("playlistId") else {
            throw InnertubeError.badResponse
        }
        return id
    }

    func deletePlaylist(_ playlistId: String) async throws {
        try Self.refused(await post("playlist/delete", body: ["playlistId": Self.bare(playlistId)]))
    }

    /** Adds tracks; answers videoId → setVideoId for what landed. */
    @discardableResult
    func addToPlaylist(_ playlistId: String, videoIds: [String]) async throws -> [String: String] {
        let response = try await editPlaylist(playlistId, videoIds.map { ["action": "ACTION_ADD_VIDEO", "addedVideoId": $0] })
        var added: [String: String] = [:]
        for result in response["playlistEditResults"].array {
            let data = result["playlistEditVideoAddedResultData"]
            if let videoId = data["videoId"].string, let setVideoId = data["setVideoId"].string { added[videoId] = setVideoId }
        }
        return added
    }

    /** Removes (setVideoId, videoId) entries. */
    func removeFromPlaylist(_ playlistId: String, entries: [(setVideoId: String, videoId: String)]) async throws {
        _ = try await editPlaylist(playlistId, entries.map {
            ["action": "ACTION_REMOVE_VIDEO", "setVideoId": $0.setVideoId, "removedVideoId": $0.videoId]
        })
    }

    /** Moves an entry before [before] (nil: to the end). */
    func movePlaylistItem(_ playlistId: String, setVideoId: String, before: String?) async throws {
        var action: [String: Any] = ["action": "ACTION_MOVE_VIDEO_BEFORE", "setVideoId": setVideoId]
        if let before { action["movedSetVideoIdSuccessor"] = before }
        _ = try await editPlaylist(playlistId, [action])
    }

    /** Several moves in one edit, as many as fifty at a time (reorderPlaylist). */
    func movePlaylistItems(_ playlistId: String, _ moves: [(setVideoId: String, before: String?)]) async throws {
        for start in stride(from: 0, to: moves.count, by: 50) {
            let actions: [[String: Any]] = moves[start..<min(start + 50, moves.count)].map { move in
                var action: [String: Any] = ["action": "ACTION_MOVE_VIDEO_BEFORE", "setVideoId": move.setVideoId]
                if let before = move.before { action["movedSetVideoIdSuccessor"] = before }
                return action
            }
            _ = try await editPlaylist(playlistId, actions)
        }
    }

    func renamePlaylist(_ playlistId: String, title: String) async throws {
        _ = try await editPlaylist(playlistId, [["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": title]])
    }

    private func editPlaylist(_ playlistId: String, _ actions: [[String: Any]]) async throws -> JSON {
        let response = try await post("browse/edit_playlist", body: ["playlistId": Self.bare(playlistId), "actions": actions])
        try Self.refused(response)
        if let status = response["status"].string, status != "STATUS_SUCCEEDED" {
            throw InnertubeError.refused("YouTube Music refused the edit (\(status))")
        }
        return response
    }

    private static func bare(_ playlistId: String) -> String {
        playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
    }

    /** An `error` object in a 200 answer is still a refusal. */
    private static func refused(_ response: JSON) throws {
        guard response["error"].exists else { return }
        throw InnertubeError.refused(response["error"]["message"].string ?? "YouTube Music refused the change")
    }

    func searchContinuation(_ token: String) async throws -> JSON {
        try await post("search", body: ["continuation": token],
                       query: ["ctoken": token, "continuation": token, "type": "next"])
    }

    func searchSuggestions(_ input: String) async throws -> JSON {
        try await post("music/get_search_suggestions", body: ["input": input])
    }

    /** The watch queue YouTube Music would play after [videoId] — its "RDAMVM" radio. */
    func next(videoId: String, playlistId: String? = nil) async throws -> JSON {
        try await post("next", body: [
            "videoId": videoId,
            "playlistId": playlistId ?? "RDAMVM\(videoId)",
            "isAudioOnly": true,
        ])
    }

    /** A track's own watch entry: the album and artists a row arrived without. */
    func trackLinks(_ videoId: String) async throws -> Song? {
        InnertubeParser.parseWatchQueue(try await next(videoId: videoId)).first { $0.videoId == videoId }
    }

    /** A playlist's (or a station's) watch queue, which pages further than its browse page. */
    func nextPlaylist(_ playlistId: String, videoId: String? = nil, params: String? = nil) async throws -> JSON {
        var body: [String: Any] = ["playlistId": playlistId, "isAudioOnly": true]
        if let videoId { body["videoId"] = videoId }
        if let params { body["params"] = params }
        return try await post("next", body: body)
    }

    /** The tracks of a watch target, catalogue cuts only (YtMusicRepository.watchQueue). */
    func watchQueue(_ target: WatchTarget) async throws -> [Song] {
        let response = try await nextPlaylist(target.playlistId, videoId: target.videoId, params: target.params)
        return InnertubeParser.parseWatchQueue(response).filter { !$0.isVideo }
    }

    // MARK: Plumbing

    private func post(_ endpoint: String, body extras: [String: Any], query: [String: String] = [:], anonymous: Bool = false) async throws -> JSON {
        let session = anonymous ? nil : Self.currentSession
        var visitor = session?.visitorData
        if visitor == nil { visitor = await ensureVisitorData() }
        let clientVersion = session?.clientVersion ?? Self.webRemixVersion
        var components = URLComponents(string: "\(Self.musicBase)/\(endpoint)")!
        components.queryItems = [URLQueryItem(name: "prettyPrint", value: "false"), URLQueryItem(name: "hl", value: Self.language)]
            + query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(HTTP.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.musicOrigin, forHTTPHeaderField: "Origin")
        request.setValue(Self.musicOrigin, forHTTPHeaderField: "X-Origin")
        request.setValue("\(Self.musicOrigin)/", forHTTPHeaderField: "Referer")
        request.setValue(Self.webRemixClientId, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ","), forHTTPHeaderField: "Accept-Language")
        if let visitor { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let session {
            // Which account in the jar, and which channel of it.
            request.setValue(session.cookie, forHTTPHeaderField: "Cookie")
            request.setValue(session.authUser ?? "0", forHTTPHeaderField: "X-Goog-AuthUser")
            if let pageId = session.pageId { request.setValue(pageId, forHTTPHeaderField: "X-Goog-PageId") }
            if let auth = session.authorization(origin: Self.musicOrigin) { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        }

        var client: [String: Any] = [
            "clientName": "WEB_REMIX",
            "clientVersion": clientVersion,
            "hl": Self.language,
            "gl": Self.region,
        ]
        if let visitor { client["visitorData"] = visitor }
        var body = extras
        var user: [String: Any] = ["lockedSafetyMode": false]
        if let dataSyncId = session?.dataSyncId { user["onBehalfOfUser"] = dataSyncId }
        body["context"] = [
            "client": client,
            "user": user,
            "request": ["useSsl": true],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await withRetry { try await HTTP.session.data(for: request) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw InnertubeError.status(status, endpoint) }
        let json = try JSON(data: data)
        if visitorData == nil, let fresh = json["responseContext"]["visitorData"].string { visitorData = fresh }
        return json
    }

    /** Transport failures get another go; an HTTP status is an answer and isn't retried. */
    private func withRetry<T>(attempts: Int = 3, _ block: () async throws -> T) async throws -> T {
        var backoff: UInt64 = 500_000_000
        for _ in 0..<(attempts - 1) {
            do {
                return try await block()
            } catch let error as URLError where error.code != .cancelled {
                try await Task.sleep(nanoseconds: backoff)
                backoff *= 2
            }
        }
        return try await block()
    }
}
