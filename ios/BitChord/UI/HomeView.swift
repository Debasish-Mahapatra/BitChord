import SwiftUI

/** Home's feed: YouTube's home shelves, then New releases and Explore as extra shelves. */
@MainActor
@Observable
final class HomeModel {
    private(set) var shelves: [HomeShelf] = []
    private(set) var loading = false
    private(set) var error: String?
    private var continuation: String?
    private var loadingMore = false
    private var supplemented = false

    func loadIfNeeded() async {
        guard shelves.isEmpty, !loading else { return }
        loading = true
        await load()
        loading = false
    }

    /** Refreshes in place: the old shelves stay up until the new ones arrive. */
    func load() async {
        do {
            async let recents = recentsShelf()
            let response = try await Innertube.shared.browse("FEmusic_home")
            var fresh = HomeShelf.withoutRepeats(InnertubeParser.parseHome(response), of: [])
            continuation = InnertubeParser.homeContinuation(response)
            supplemented = false
            if continuation == nil { fresh = await withSupplements(fresh) }
            // Signed in, the account's own last plays lead the feed.
            if let recents = await recents { fresh.insert(recents, at: 0) }
            shelves = dedupe(fresh)
            error = nil
        } catch {
            if shelves.isEmpty { self.error = error.localizedDescription }
        }
    }

    /** "Recents": up to 20 tracks off the account's history, as a list shelf. */
    private func recentsShelf() async -> HomeShelf? {
        guard Account.shared.isSignedIn, let response = try? await Innertube.shared.browse("FEmusic_history") else { return nil }
        let songs = InnertubeParser.collectSongsDeep(response).prefix(20)
        guard !songs.isEmpty else { return nil }
        let items = songs.map { ShelfItem(title: $0.title, subtitle: $0.artist, thumbnailUrl: $0.thumbnailUrl, videoId: $0.videoId,
                                          browseId: nil, song: $0, isVideo: $0.isVideo) }
        return HomeShelf(title: "Recents", items: Array(items), layout: .list)
    }

    /** The next page once the list nears its end; the supplements after the last one. */
    func loadMore() async {
        guard !loadingMore, !shelves.isEmpty else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let token = continuation {
            guard let response = try? await Innertube.shared.browseContinuation(token) else { return }
            let more = HomeShelf.withoutRepeats(InnertubeParser.parseHomeContinuation(response), of: shelves)
            let next = InnertubeParser.homeContinuation(response)
            let before = shelves.count
            shelves = dedupe(shelves + more)
            // A page that adds nothing new ends the paging.
            continuation = shelves.count == before ? nil : next
        } else if !supplemented {
            shelves = dedupe(await withSupplements(shelves))
        }
    }

    var canLoadMore: Bool { continuation != nil || !supplemented }

    private func withSupplements(_ base: [HomeShelf]) async -> [HomeShelf] {
        supplemented = true
        async let releases = try? Innertube.shared.browse("FEmusic_new_releases")
        async let explore = try? Innertube.shared.browse("FEmusic_explore")
        let extra = [await releases, await explore].compactMap { $0 }.flatMap(InnertubeParser.parseHome)
        return base + HomeShelf.withoutRepeats(extra, of: base)
    }

    private func dedupe(_ shelves: [HomeShelf]) -> [HomeShelf] {
        var seen = Set<String>()
        return shelves.filter { seen.insert($0.title.lowercased()).inserted }
    }
}

struct HomeView: View {
    @State private var model = HomeModel()
    private let topPicks = TopPicksStore.shared
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @Environment(Account.self) private var account

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    title
                    if !account.isSignedIn { SignInBanner() }
                    if let picks = topPicks.picks, !picks.isEmpty {
                        TopPicksShelf(picks: picks, width: geometry.size.width, listenerName: account.name)
                    } else if topPicks.picks == nil && topPicks.loading {
                        TopPicksSkeleton(width: geometry.size.width)
                    }
                    if model.loading && model.shelves.isEmpty {
                        skeleton(width: geometry.size.width)
                    } else if let error = model.error {
                        MessageState(text: error, button: "Retry") { Task { await model.load() } }
                    } else {
                        ForEach(Array(model.shelves.enumerated()), id: \.element.id) { index, shelf in
                            // Find Your Mood follows the lead shelf, as on Apple Music's Home.
                            if index == 1 { FindYourMoodShelf() }
                            shelfView(shelf, hero: index == 0, width: geometry.size.width)
                                .onAppear {
                                    if index >= model.shelves.count - 3 { Task { await model.loadMore() } }
                                }
                        }
                        if model.canLoadMore { ShelfSkeleton() }
                    }
                }
                .padding(.top, Metrics.contentTop - 28)
                .padding(.bottom, Metrics.contentBottom(hasSong: player.song != nil))
            }
            .refreshable { await model.load() }
        }
        .task {
            await model.loadIfNeeded()
            await topPicks.load(homeShelves: model.shelves)
        }
        .onChange(of: account.session?.key) { _, _ in
            Task {
                await model.load()
                await topPicks.load(homeShelves: model.shelves)
            }
        }
    }

    /** The logo over "Listen Now". */
    private var title: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image("Logo")
                .resizable()
                .aspectRatio(730 / 484, contentMode: .fit)
                .frame(height: 34 * 0.9)
                .foregroundStyle(Theme.onBackground)
                .padding(.bottom, 14)
            Text("Listen Now").textStyle(.displayLarge).foregroundStyle(Theme.onBackground)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 8)
        .accessibilityAddTraits(.isHeader)
    }

    /**
     * A list shelf (Quick picks, Listen again, Recents) pages four rows to a
     * column; a card shelf leading the feed gets the hero cards; videos get
     * widescreen cards; everything else square ones.
     */
    @ViewBuilder
    private func shelfView(_ shelf: HomeShelf, hero: Bool, width: CGFloat) -> some View {
        if shelf.layout == .list || (hero && shelf.title.caseInsensitiveCompare("Recents") == .orderedSame) {
            TrackPagerShelf(shelf: shelf, width: width) { open($0) }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: shelf.title, strapline: shelf.strapline)
                HorizontalShelf(spacing: 14) {
                    ForEach(shelf.items) { item in
                        if hero && shelf.layout == .cards {
                            HeroCard(item: item, width: min(width * 0.70, 320)) { open(item) }
                        } else if shelf.layout == .video {
                            VideoCard(item: item) { open(item) }
                        } else {
                            ShelfCard(item: item) { open(item) }
                        }
                    }
                }
            }
            .padding(.bottom, 26)
        }
    }

    /** A song card starts a radio from the song; anything else opens its page. */
    private func open(_ item: ShelfItem) {
        if let browse = item.browseItem {
            router.open(browse)
        } else if let song = item.asSong {
            player.startRadio(song)
        }
    }

    private func skeleton(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SkeletonBlock().frame(width: 180, height: 18).padding(.horizontal, Metrics.gutter).padding(.vertical, 10)
                HStack(spacing: 14) {
                    ForEach(0..<2, id: \.self) { _ in
                        SkeletonBlock(radius: 18).frame(width: min(width * 0.7, 320), height: min(width * 0.7, 320) / 0.92)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
            }
            .padding(.bottom, 26)
            .frame(width: width, alignment: .leading)
            .clipped()
            ShelfSkeleton()
            ShelfSkeleton()
        }
    }
}

/** RecentShelf: a small header, then columns of four compact rows paged sideways. */
struct TrackPagerShelf: View {
    let shelf: HomeShelf
    let width: CGFloat
    var onTap: (ShelfItem) -> Void

    var body: some View {
        let columns = stride(from: 0, to: shelf.items.count, by: 4).map { Array(shelf.items[$0..<min($0 + 4, shelf.items.count)]) }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(shelf.title).textStyle(.titleMedium).foregroundStyle(Theme.onBackground).lineLimit(1)
                if !shelf.strapline.isEmpty {
                    Text(shelf.strapline).textStyle(.bodyMedium).foregroundStyle(Theme.onSurfaceVariant).lineLimit(1)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 10)
            HorizontalShelf(spacing: 12) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, rows in
                    VStack(spacing: 0) {
                        ForEach(rows) { item in
                            if let song = item.asSong {
                                CompactTrackRow(song: song, isVideo: item.isVideo) { onTap(item) }
                            }
                        }
                    }
                    .frame(width: min(width * 0.88, 400))
                }
            }
        }
        .padding(.bottom, 26)
    }
}

/** VideoShelfCard: the thumbnail at its own 16:9, 248pt wide, so it stands as tall as a square card. */
struct VideoCard: View {
    let item: ShelfItem
    var onTap: () -> Void

    @Environment(PlayerModel.self) private var player

    var body: some View {
        let current = item.videoId != nil && player.song?.videoId == item.videoId
        VStack(alignment: .leading, spacing: 0) {
            Cover(url: Artwork.url(item.thumbnailUrl, px: cardArtPx), radius: 12)
                .frame(width: 248, height: 248 / (16.0 / 9.0))
                .overlay { if current, player.isPlaying { PlayingBars() } }
            Text(item.title).textStyle(.titleMedium).foregroundStyle(Theme.onBackground)
                .lineLimit(1).padding(.top, 10)
            Text(item.subtitle).textStyle(.bodyMedium).foregroundStyle(Theme.onSurfaceVariant).lineLimit(1)
        }
        .frame(width: 248, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .shelfContextMenu(item)
    }
}

/**
 * The signed-out invitation. The phone drifts four colour blobs behind it and
 * cycles their palette; this is its still frame ("reduce animation").
 */
struct SignInBanner: View {
    @Environment(Account.self) private var account

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in to YouTube Music").textStyle(.headlineMedium, weight: .heavy).foregroundStyle(.white)
            Button { account.presentSignIn = true } label: {
                HStack(spacing: 8) {
                    Text("G").font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [Color(hex: 0x4285F4), Color(hex: 0xEA4335), Color(hex: 0xFBBC05), Color(hex: 0x34A853)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 18, height: 18)
                    Text("Sign in with Google").font(.sfDisplay(15, .bold)).foregroundStyle(.black)
                }
                .padding(.leading, 16).padding(.trailing, 20).padding(.vertical, 10)
                .background(.white, in: Capsule())
            }
            .buttonStyle(PressScale())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 18, trailing: 20))
        .background { StaticMesh() }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
}

/** A mesh palette's still frame: four soft blobs over a deep base, then a scrim. The phone drifts it; this never moves. */
struct StaticMesh: View {
    /** WelcomeMeshPalettes' first: red, violet, ember. */
    var colors: [Color] = [Color(hex: 0xFA2D48), Color(hex: 0x7B2FF7), Color(hex: 0xFF7A45), Color(hex: 0x2E1A8A)]
    var base = Color(hex: 0x3A0710)
    var scrim: (top: Double, bottom: Double) = (0.10, 0.38)

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let radius = max(size.width, size.height) * 0.62
            let anchors: [CGPoint] = [.init(x: 0.20, y: 0.25), .init(x: 0.80, y: 0.20), .init(x: 0.75, y: 0.80), .init(x: 0.25, y: 0.75)]
            ZStack {
                base
                ForEach(0..<4, id: \.self) { i in
                    let x = anchors[i].x + 0.16 * cos(1.7 * Double(i))
                    let y = anchors[i].y + 0.16 * sin(2.3 * Double(i))
                    RadialGradient(colors: [colors[i].opacity(0.85), colors[i].opacity(0)], center: UnitPoint(x: x, y: y), startRadius: 0, endRadius: radius)
                }
            }
            .scaleEffect(1.3)
            .blur(radius: 36)
            .overlay(LinearGradient(colors: [.black.opacity(scrim.top), .black.opacity(scrim.bottom)], startPoint: .top, endPoint: .bottom))
        }
    }
}

/** Scales a pressed button to 0.98, as the banner's sign-in pill. */
struct PressScale: ButtonStyle {
    var scale: CGFloat = 0.98

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.compose(dampingRatio: 1, stiffness: 900), value: configuration.isPressed)
    }
}
