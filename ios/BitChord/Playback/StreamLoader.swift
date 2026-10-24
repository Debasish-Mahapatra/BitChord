import AVFoundation

/**
 * Hands AVPlayer a track as an HLS playlist built over its googlevideo URL —
 * see SegmentIndex for why. AVPlayer asks for `bitchord://…m3u8`; this
 * resolves the stream, reads the file's index with one bounded range, and
 * answers with a playlist whose segments are the file's own subsegments, each
 * one bounded googlevideo range no larger than the minting client is served.
 *
 * A refusal mid-track surfaces as the item failing; PlayerModel then excludes
 * that client and picks up on the next one at the same position, as
 * InnerTubeXResolver.onRefused does.
 */
final class StreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "bitchord"

    let videoId: String
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var stream: ResolvedStream?
    private var playlist: (url: URL, data: Data)?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(videoId: String) {
        self.videoId = videoId
        self.queue = DispatchQueue(label: "bitchord.loader.\(videoId)")
    }

    /** The client whose URL is playing, for the exclusion when it's refused. */
    var clientId: String? { lock.withLock { stream?.client.id } }

    /** The stream's own length, which AVPlayer reads off the playlist too. */
    var resolvedDuration: Double? { lock.withLock { stream?.durationSeconds } }

    /** YouTube's normalisation figure for this track, once the stream is known. */
    var loudnessDb: Double? { lock.withLock { stream?.loudnessDb } }

    /** What the stream is, for Stats for nerds: codec, bitrate, client. */
    var streamDescription: String? {
        lock.withLock {
            guard let stream else { return nil }
            let codec = stream.mimeType.components(separatedBy: "codecs=\"").dropFirst().first?.prefix { $0 != "\"" } ?? Substring(stream.mimeType)
            let name = String(codec).hasPrefix("mp4a.40") ? "AAC" : String(codec).uppercased()
            return [name, "\(Int((Double(stream.bitrate) / 1000).rounded())) kbps", stream.client.id].joined(separator: " · ")
        }
    }

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://stream/\(videoId).m3u8")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /** Starts the resolve before AVPlayer asks, so the first bytes don't wait on the player request. */
    func prime() {
        Task { _ = try? await currentPlaylist() }
    }

    func cancelAll() {
        let running = lock.withLock {
            let running = Array(tasks.values)
            tasks.removeAll()
            return running
        }
        running.forEach { $0.cancel() }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
        let key = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            await self?.serve(loadingRequest)
            self?.lock.withLock { _ = self?.tasks.removeValue(forKey: key) }
        }
        lock.withLock { tasks[key] = task }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let task = lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) }
        task?.cancel()
    }

    // MARK: Serving

    private func serve(_ request: AVAssetResourceLoadingRequest) async {
        do {
            let data = try await currentPlaylist()
            try Task.checkCancellation()
            queue.sync {
                if let info = request.contentInformationRequest {
                    info.contentType = "public.m3u-playlist"
                    info.contentLength = Int64(data.count)
                    info.isByteRangeAccessSupported = false
                }
                if let dataRequest = request.dataRequest {
                    let start = Int(dataRequest.requestedOffset)
                    let end = dataRequest.requestsAllDataToEndOfResource
                        ? data.count : min(data.count, start + dataRequest.requestedLength)
                    if start < end { dataRequest.respond(with: data.subdata(in: start..<end)) }
                }
                request.finishLoading()
            }
        } catch is CancellationError {
            // AVPlayer cancelled it; nothing to answer.
        } catch let error as URLError where error.code == .cancelled {
            // Likewise.
        } catch {
            Log.w("stream load failed: \(error.localizedDescription)", about: videoId)
            queue.sync { request.finishLoading(with: error) }
        }
    }

    private func currentPlaylist() async throws -> Data {
        let stream = try await currentStream()
        if let playlist = lock.withLock({ playlist }), playlist.url == stream.url { return playlist.data }
        let index = try await Self.index(of: stream)
        let data = Data(index.playlist(for: stream).utf8)
        lock.withLock { playlist = (stream.url, data) }
        Log.d("\(stream.client.id): \(index.segments.count) segments, \(Int(index.duration))s", about: videoId)
        return data
    }

    private func currentStream() async throws -> ResolvedStream {
        if let cached = lock.withLock({ stream }), cached.isFresh { return cached }
        let fresh = try await StreamResolver.shared.resolve(videoId)
        lock.withLock { stream = fresh }
        return fresh
    }

    /** The init segment and the index behind it, read with one bounded range. */
    private static func index(of stream: ResolvedStream) async throws -> SegmentIndex {
        let indexEnd = stream.indexRange?.upperBound ?? 16_383
        var request = URLRequest(url: stream.url(for: 0...min(indexEnd, stream.contentLength - 1)))
        stream.client.mediaHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let (data, response) = try await HTTP.media.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else { throw StreamError.failed("googlevideo answered \(status)") }
                let indexStart = stream.indexRange?.lowerBound ?? stream.initRange.map { $0.upperBound + 1 } ?? 0
                return try SegmentIndex.parse(data, initRange: stream.initRange, indexOffset: indexStart)
            } catch let error as URLError where error.code != .cancelled {
                lastError = error
                try await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
            }
        }
        throw lastError ?? StreamError.failed("googlevideo didn't answer")
    }
}

extension HTTP {
    /** Media bytes: no cache, no cookies, and its own connections so a big fetch never queues an API call. */
    static let media: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
}
