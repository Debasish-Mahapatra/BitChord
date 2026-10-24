import SwiftUI
import UIKit

/** Decoded artwork, kept in memory; the bytes themselves sit in HTTP.session's disk cache. */
actor ImageLoader {
    static let shared = ImageLoader()

    /** NSCache is thread-safe, so the synchronous peek needs no hop onto the actor. */
    nonisolated private let memory = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init() {
        memory.countLimit = 300
    }

    /** "Clear image cache": the decoded images and the downloaded bytes behind them. */
    nonisolated func clear() {
        memory.removeAllObjects()
        HTTP.session.configuration.urlCache?.removeAllCachedResponses()
        URLCache.shared.removeAllCachedResponses()
    }

    nonisolated func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(_ url: URL) async -> UIImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if let task = inFlight[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            guard let (data, _) = try? await HTTP.session.data(from: url), let image = UIImage(data: data) else { return nil }
            return await image.byPreparingForDisplay() ?? image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/** An image from the network, cross-fading in over 200 ms (the phone's Coil default). */
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity.animation(.linear(duration: 0.2)))
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let cached = ImageLoader.shared.cached(url) {
                image = cached
                return
            }
            image = nil
            let loaded = await ImageLoader.shared.image(url)
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: 0.2)) { image = loaded }
        }
    }
}
