import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
@Observable
final class ExploreModel {
    private(set) var moods: [MoodGenre] = []
    private(set) var artwork: [String: String] = [:]
    private(set) var loading = false
    private(set) var error: String?

    func loadIfNeeded() async {
        guard moods.isEmpty, !loading else { return }
        await load()
    }

    /** The server's sections flattened into one grid, each button once. */
    func load() async {
        loading = moods.isEmpty
        do {
            let response = try await Innertube.shared.browse("FEmusic_moods_and_genres")
            var seen = Set<String>()
            moods = InnertubeParser.parseMoodAndGenres(response).flatMap(\.items).filter { seen.insert($0.id).inserted }
            error = moods.isEmpty ? "Nothing to explore right now" : nil
        } catch {
            if moods.isEmpty { self.error = error.localizedDescription }
        }
        loading = false
        // The grid shows now; each card's picture arrives on its own.
        Task { await loadArtwork() }
    }

    /** Each card's picture is its page's first playlist cover, four fetched at a time. */
    private func loadArtwork() async {
        let pending = moods.filter { artwork[$0.id] == nil }
        await withTaskGroup(of: (String, String?).self) { group in
            var iterator = pending.makeIterator()
            func addNext() {
                guard let mood = iterator.next() else { return }
                group.addTask {
                    let page = try? await Innertube.shared.browse(mood.browseId, params: mood.params)
                    let cover = page.flatMap { InnertubeParser.parseHome($0).first?.items.first?.thumbnailUrl }
                    return (mood.id, cover)
                }
            }
            for _ in 0..<4 { addNext() }
            for await (id, cover) in group {
                if let cover { artwork[id] = cover }
                addNext()
            }
        }
    }
}

struct ExploreView: View {
    @State private var model = ExploreModel()
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router

    var body: some View {
        GeometryReader { geometry in
            let columns = max(2, min(6, Int((geometry.size.width - 32 + 12) / (220 + 12))))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageTitle(text: "Explore")
                    if model.loading {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                            ForEach(0..<(6 * columns), id: \.self) { _ in
                                SkeletonBlock(radius: 18).aspectRatio(1.72, contentMode: .fit)
                            }
                        }
                        .padding(.horizontal, Metrics.gutter)
                    } else if let error = model.error {
                        MessageState(text: error, button: "Retry") { Task { await model.load() } }
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                            ForEach(model.moods) { mood in
                                MoodSleeve(mood: mood, artwork: model.artwork[mood.id])
                                    .onTapGesture { router.push(.mood(mood)) }
                            }
                        }
                        .padding(.horizontal, Metrics.gutter)
                    }
                }
                .padding(.top, Metrics.contentTop)
                .padding(.bottom, Metrics.contentBottom(hasSong: player.song != nil))
            }
            .refreshable { await model.load() }
        }
        .task { await model.loadIfNeeded() }
    }
}

/** MoodGenreSleeve: the mood's colour, its artwork in duotone on the right 72%, the title top-left. */
private struct MoodSleeve: View {
    let mood: MoodGenre
    let artwork: String?

    private static let fallback: [UInt32] = [0xCC6A55, 0xC07A92, 0x9C8AC0, 0x8090C8, 0xD0A060, 0x6A88B0, 0x7AAED0, 0x86B890]

    private var base: UIColor {
        if let stripe = mood.stripeColor { return UIColor(hex: stripe & 0xFFFFFF) }
        let hash = mood.title.unicodeScalars.reduce(Int32(0)) { $0 &* 31 &+ Int32($1.value) }
        return UIColor(hex: Self.fallback[Int(abs(Int(hash)) % Self.fallback.count)])
    }

    var body: some View {
        let base = base
        let stripe = base.mixed(with: .black, 0.08)
        let shadow = base.mixed(with: .black, 0.68)
        let highlight = base.mixed(with: .white, 0.32)
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color(stripe)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ZStack {
                        Color(shadow.mixed(with: highlight, 0.45))
                        DuotoneImage(url: Artwork.url(artwork, px: cardArtPx), shadow: shadow, highlight: highlight)
                    }
                    .frame(width: geometry.size.width * 0.72)
                    .clipped()
                }
                LinearGradient(stops: [.init(color: .black.opacity(0.24), location: 0), .init(color: .clear, location: 0.62)],
                               startPoint: .top, endPoint: .bottom)
                Text(mood.title)
                    .textStyle(.titleMedium, weight: .bold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
        }
        .aspectRatio(1.72, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }
}

/** Luminance mapped from [shadow] to [highlight]: CIFalseColor. */
private struct DuotoneImage: View {
    let url: URL?
    let shadow: UIColor
    let highlight: UIColor
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            guard let url, let source = await ImageLoader.shared.image(url) else { return }
            let tinted = await Task.detached(priority: .utility) { Self.duotone(source, shadow, highlight) }.value
            withAnimation(.linear(duration: 0.2)) { image = tinted }
        }
    }

    nonisolated private static func duotone(_ image: UIImage, _ shadow: UIColor, _ highlight: UIColor) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let filter = CIFilter.falseColor()
        filter.inputImage = input
        filter.color0 = CIColor(color: shadow)
        filter.color1 = CIColor(color: highlight)
        guard let output = filter.outputImage, let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension UIColor {
    /** lerp(self, other, t) in sRGB. */
    func mixed(with other: UIColor, _ t: CGFloat) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }
}

/** The mood or genre's own page: its title and shelves of playlists. */
struct MoodPageView: View {
    let mood: MoodGenre
    @State private var shelves: [HomeShelf] = []
    @State private var loading = true
    @State private var error: String?
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(mood.title).textStyle(.displayLarge).foregroundStyle(Theme.onBackground).lineLimit(1)
                    .padding(.horizontal, Metrics.gutter).padding(.vertical, 8)
                if loading {
                    ShelfSkeleton()
                    ShelfSkeleton()
                } else if let error {
                    MessageState(text: error)
                } else {
                    ForEach(shelves) { shelf in
                        VStack(alignment: .leading, spacing: 0) {
                            SectionHeader(title: shelf.title, strapline: shelf.strapline)
                            HorizontalShelf {
                                ForEach(shelf.items) { item in
                                    ShelfCard(item: item) {
                                        if let browse = item.browseItem { router.open(browse) } else if let song = item.asSong { player.startRadio(song) }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 26)
                    }
                }
            }
            .padding(.top, Metrics.contentTop)
            .padding(.bottom, Metrics.contentBottom(hasSong: player.song != nil))
        }
        .task {
            do {
                shelves = InnertubeParser.parseHome(try await Innertube.shared.browse(mood.browseId, params: mood.params))
                if shelves.isEmpty { error = "Nothing to explore right now" }
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
