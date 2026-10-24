import SwiftUI

@MainActor
@Observable
final class ArtistModel {
    let item: BrowseItem
    private(set) var page: ArtistPage?
    private(set) var error: String?
    private(set) var palette: ArtworkPalette?
    /** The full "Top songs" list, when the shelf links to it. */
    private(set) var allSongs: [Song]?
    /** Apple Music's header for this artist: its photo, title logo and colours. */
    private(set) var appleArt: AppleArtistArt?

    init(item: BrowseItem) {
        self.item = item
    }

    func load() async {
        guard page == nil else { return }
        appleArt = await AppleArtistArtRepository.shared.cached(item.browseId)
        if let appleArt { palette = .from(background: appleArt.background, accent: appleArt.accent) }
        do {
            let parsed = InnertubeParser.parseArtistPage(try await Innertube.shared.browse(item.browseId))
            page = parsed
            if appleArt == nil {
                let photo = Artwork.url(parsed.thumbnailUrl ?? item.thumbnailUrl, px: 720)
                palette = PaletteCache.shared.cached(photo)
                if palette == nil, let loaded = await PaletteCache.shared.palette(photo) {
                    withAnimation(.linear(duration: 0.26)) { palette = loaded }
                }
            }
            if let more = parsed.moreSongsBrowseId, let response = try? await Innertube.shared.browse(more) {
                let songs = InnertubeParser.parsePlaylistShelf(response)?.songs ?? InnertubeParser.collectSongsDeep(response)
                if !songs.isEmpty { allSongs = songs }
            }
            await loadAppleArt(parsed)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /** Confirmed by a shared title in both catalogues, so it waits for the page's songs. */
    private func loadAppleArt(_ page: ArtistPage) async {
        guard appleArt == nil else { return }
        let titles = AppleCatalogue.titles(of: page) + (allSongs ?? []).map(\.title)
        guard let art = await AppleArtistArtRepository.shared.art(for: item.browseId, name: page.name ?? item.title, catalogue: { titles }) else { return }
        withAnimation(.linear(duration: 0.26)) {
            appleArt = art
            palette = .from(background: art.background, accent: art.accent)
        }
    }

    var playable: [Song] { allSongs ?? page?.songs ?? [] }

    /** The star: nil signed out, where the header carries no subscribe state. */
    var subscribed: Bool? { page?.subscription?.subscribed }

    func toggleSubscription() {
        guard let subscription = page?.subscription else { return }
        let now = !subscription.subscribed
        page?.subscription?.subscribed = now
        Task {
            do {
                try await Innertube.shared.setSubscribed(subscription.channelId, now)
            } catch {
                page?.subscription?.subscribed = !now
                PlayerModel.shared.showNotice(error.localizedDescription)
            }
        }
    }
}

struct ArtistView: View {
    @State private var model: ArtistModel
    @State private var aboutOpen = false
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @Environment(Account.self) private var account

    init(item: BrowseItem) {
        _model = State(initialValue: ArtistModel(item: item))
    }

    private var wash: Color { (model.palette ?? .neutral).wash }
    private var accent: Color { (model.palette ?? .neutral).accent }

    var body: some View {
        GeometryReader { geometry in
            let artHeight = min(geometry.size.width / 0.95, geometry.size.height * 0.6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    hero(width: geometry.size.width, height: artHeight)
                    if let error = model.error {
                        MessageState(text: error, button: "Retry") { Task { await model.load() } }
                    } else if let page = model.page {
                        if !page.songs.isEmpty { actions }
                        if let release = newestRelease(page) { releaseCard(release) }
                        if !page.songs.isEmpty { topSongs(width: geometry.size.width) }
                        ForEach(page.shelves) { shelf in carousel(shelf) }
                        about(page)
                    } else {
                        ForEach(0..<6, id: \.self) { RowSkeleton(index: $0) }.opacity(0.4)
                    }
                }
                .padding(.bottom, Metrics.contentBottom(hasSong: player.song != nil))
            }
            .ignoresSafeArea(edges: .top)
        }
        .background(wash.ignoresSafeArea())
        .preference(key: PageActionsKey.self, value: PageActions(items: [
            .init(icon: "square.and.arrow.up") { Share.present(url: "https://music.youtube.com/channel/\(model.item.browseId)") },
        ]))
        .preference(key: PageColorKey.self, value: wash)
        .task { await model.load() }
    }

    // MARK: Hero

    /** The photo edge to edge (Apple's when it has one), dissolving into the page's wash, the name or title logo over its foot. */
    private func hero(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: model.appleArt.flatMap { URL(string: $0.heroUrl) }
                        ?? Artwork.url(model.page?.thumbnailUrl ?? model.item.thumbnailUrl, px: 720))
                .frame(width: width, height: height)
                .clipped()
            LinearGradient(stops: [
                .init(color: wash.opacity(0), location: 0.45),
                .init(color: wash.opacity(0.30), location: 0.65),
                .init(color: wash.opacity(0.72), location: 0.82),
                .init(color: wash.opacity(0.95), location: 0.94),
                .init(color: wash, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            ArtistTitle(name: model.page?.name ?? model.item.title, art: model.appleArt, width: width, artHeight: height)
        }
        .frame(width: width, height: height + 44 - 64, alignment: .bottom)
        .frame(width: width, height: height + 44 - 64)
        .clipped()
    }

    /** Shuffle, the big Play circle, and Subscribe. */
    private var actions: some View {
        HStack(spacing: 24) {
            round("shuffle", size: 52) { play(shuffled: true) }
            Button { play(shuffled: false) } label: {
                PlayCircle(color: model.appleArt?.keyColor.map { Color(hex: UInt32($0)) } ?? .white)
                    .frame(width: 70, height: 70)
            }
            .buttonStyle(PressScale(scale: 0.95))
            round(model.subscribed == true ? "star.fill" : "star", size: 52) { model.toggleSubscription() }
                .disabled(!account.isSignedIn || model.subscribed == nil)
                .opacity(account.isSignedIn && model.subscribed != nil ? 1 : 0.38)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 22)
    }

    private func round(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.white.opacity(0.07), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(PressScale())
    }

    private func play(shuffled: Bool, from index: Int = 0) {
        let songs = model.playable
        guard !songs.isEmpty else { return }
        player.play(songs, from: shuffled ? Int.random(in: 0..<songs.count) : index,
                    source: QueueSource(title: model.page?.name ?? model.item.title, kind: .artist, id: model.item.browseId),
                    shuffled: shuffled)
    }

    // MARK: Sections

    /** The newest album or single, by the year in its subtitle. */
    private func newestRelease(_ page: ArtistPage) -> ShelfItem? {
        let releases = page.shelves.prefix(2).flatMap(\.items).filter { $0.browseId?.hasPrefix("MPRE") == true }
        func year(_ item: ShelfItem) -> Int { item.subtitle.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init).filter { $0 > 1900 }.max() ?? 0 }
        return releases.max { year($0) < year($1) }
    }

    private func releaseCard(_ release: ShelfItem) -> some View {
        HStack(spacing: 14) {
            Cover(url: Artwork.url(release.thumbnailUrl, px: cardArtPx), size: 88, radius: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(release.subtitle).textStyle(.bodyMedium).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Text(release.title).textStyle(.titleLarge).foregroundStyle(.white).lineLimit(2)
                Text(release.subtitle.lowercased().contains("single") ? "Recent Single" : release.subtitle.lowercased().contains("ep") ? "Recent EP" : "Recent Album")
                    .textStyle(.bodyMedium).foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 22)
        .contentShape(Rectangle())
        .onTapGesture { if let browse = release.browseItem { router.open(browse) } }
        .shelfContextMenu(release)
    }

    /** "Top songs": columns of four, paged sideways, at most 20. */
    private func topSongs(width: CGFloat) -> some View {
        let songs = Array(model.playable.prefix(20))
        let columns = stride(from: 0, to: songs.count, by: 4).map { Array(songs[$0..<min($0 + 4, songs.count)]) }
        return VStack(alignment: .leading, spacing: 0) {
            Text("Top songs").textStyle(.headlineMedium).foregroundStyle(.white)
                .padding(.horizontal, Metrics.gutter).padding(.top, 10).padding(.bottom, 8)
            HorizontalShelf(spacing: 12) {
                ForEach(Array(columns.enumerated()), id: \.offset) { column, rows in
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.videoId) { row, song in
                            CompactTrackRow(song: song) { play(shuffled: false, from: column * 4 + row) }
                        }
                    }
                    .frame(width: min(width * 0.88, 400))
                }
            }
        }
    }

    private func carousel(_ shelf: HomeShelf) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(shelf.title).textStyle(.headlineMedium).foregroundStyle(.white).lineLimit(2)
                Spacer()
                if shelf.items.count > 5 {
                    Button { router.push(.showAll(title: shelf.title, items: shelf.items)) } label: {
                        Text("Show all").textStyle(.titleSmall).foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Metrics.gutter).padding(.top, 10).padding(.bottom, 8)
            HorizontalShelf(spacing: 14) {
                ForEach(shelf.items) { item in
                    // An artist's Videos shelf: widescreen, as on the web player.
                    if item.isVideo {
                        VideoCard(item: item) { if let song = item.asSong { player.startRadio(song) } }
                    } else {
                        ShelfCard(item: item, radius: 10) {
                            if let browse = item.browseItem { router.open(browse) } else if let song = item.asSong { player.startRadio(song) }
                        }
                    }
                }
            }
        }
        .padding(.top, 22)
    }

    @ViewBuilder
    private func about(_ page: ArtistPage) -> some View {
        if page.description != nil || page.subscriberCountText != nil || page.monthlyListenerCount != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("About the artist").textStyle(.titleMedium).foregroundStyle(.white)
                if let text = page.description {
                    Text(text).font(.sfDisplay(16, .medium)).foregroundStyle((model.palette ?? .neutral).onBackgroundVariant)
                        .lineLimit(aboutOpen ? nil : 2)
                        .onTapGesture { withAnimation(.fastOutSlowIn(0.25)) { aboutOpen.toggle() } }
                    Button(aboutOpen ? "Less" : "More") { withAnimation(.fastOutSlowIn(0.25)) { aboutOpen.toggle() } }
                        .textStyle(.labelLarge).foregroundStyle(accent)
                }
                HStack(spacing: 6) {
                    if let subscribers = page.subscriberCountText { chip(subscribers, icon: "person.fill") }
                    if let listeners = page.monthlyListenerCount { chip(listeners, icon: "waveform") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 28)
        }
    }

    private func chip(_ text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13))
            Text(text).textStyle(.labelMedium)
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.white.opacity(0.08), in: Capsule())
    }
}

/**
 * The artist's name across the foot of the photo — or Apple's title logo in
 * its place once that has drawn, at most 82% of the page wide and 30% of the
 * photo tall, so a logo set on two lines can't swallow the picture.
 */
private struct ArtistTitle: View {
    let name: String
    let art: AppleArtistArt?
    let width: CGFloat
    let artHeight: CGFloat
    @State private var logo: UIImage?

    var body: some View {
        ZStack(alignment: .bottom) {
            if let logo, let art {
                let aspect = min(max(art.logoAspect, 0.4), 6)
                let height = min(width * 0.82 / aspect, artHeight * 0.30)
                Image(uiImage: logo).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: height * aspect, height: height)
                    .padding(.top, 14).padding(.bottom, 20)
                    .accessibilityLabel(name)
                    .transition(.opacity)
            } else {
                Text(name)
                    .textStyle(.displayLarge)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 7)
            }
        }
        .task(id: art?.logoUrl) {
            // Two more tries for a dropped fetch before the name is left in place.
            guard let url = art?.logoUrl.flatMap(URL.init(string:)) else { return }
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
                if let image = await ImageLoader.shared.image(url) {
                    withAnimation(.linear(duration: 0.2)) { logo = image }
                    return
                }
            }
        }
    }
}

/** The artist page's Play: a filled circle with the triangle punched out of it, so the page shows through. */
private struct PlayCircle: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(color))
            let box = min(size.width, size.height) * 0.56
            let unit = box / 24
            let origin = CGPoint(x: (size.width - box) / 2, y: (size.height - box) / 2)
            var triangle = Path()
            triangle.move(to: CGPoint(x: origin.x + 6.8 * unit, y: origin.y + 4.8 * unit))
            triangle.addLine(to: CGPoint(x: origin.x + 19.2 * unit, y: origin.y + 12 * unit))
            triangle.addLine(to: CGPoint(x: origin.x + 6.8 * unit, y: origin.y + 19.2 * unit))
            triangle.closeSubpath()
            context.blendMode = .clear
            context.fill(triangle, with: .color(.black))
            context.stroke(triangle, with: .color(.black), style: StrokeStyle(lineWidth: 2 * unit, lineCap: .round, lineJoin: .round))
        }
    }
}
