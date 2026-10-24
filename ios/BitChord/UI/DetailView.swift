import SwiftUI

@MainActor
@Observable
final class CollectionModel {
    let item: BrowseItem
    private(set) var page: CollectionPage?
    private(set) var songs: [Song] = []
    private(set) var error: String?
    private(set) var palette: ArtworkPalette?
    /** The bookmark: which playlist id saving acts on, and whether it's saved. */
    var library: (playlistId: String, saved: Bool)?
    /** A playlist this account made. */
    private(set) var owned = false

    init(item: BrowseItem) {
        self.item = item
    }

    func load(force: Bool = false) async {
        guard page == nil || force else { return }
        do {
            let response = try await Innertube.shared.browse(item.browseId)
            let parsed = InnertubeParser.parseCollection(response, browseId: item.browseId)
            page = parsed
            songs = parsed.songs
            library = InnertubeParser.parseLibraryState(response)
            owned = item.browseId.hasPrefix("VL") && Account.shared.isSignedIn && InnertubeParser.parsePlaylistOwned(response) == true
            let cover = Artwork.url(parsed.thumbnailUrl ?? item.thumbnailUrl, px: 720)
            palette = PaletteCache.shared.cached(cover)
            if palette == nil, let loaded = await PaletteCache.shared.palette(cover) {
                withAnimation(.linear(duration: 0.26)) { palette = loaded }
            }
            await loadRest(parsed.continuation)
        } catch {
            // A failed reload leaves the page that's already showing.
            if page == nil { self.error = error.localizedDescription }
        }
    }

    func removeRow(setVideoId: String) {
        songs.removeAll { $0.setVideoId == setVideoId }
    }

    /** Saves [order] as the playlist's running order, in the fewest moves. */
    func saveOrder(_ order: [Song]) async -> Bool {
        let moves = PlaylistOrder.moves(current: songs.compactMap(\.setVideoId), target: order.compactMap(\.setVideoId))
        guard !moves.isEmpty else { return true }
        do {
            try await Innertube.shared.movePlaylistItems(item.browseId, moves)
            songs = order
            return true
        } catch {
            return false
        }
    }

    /** Every remaining page in the background, appended as it arrives (150 ms after the first). */
    private func loadRest(_ first: String?) async {
        var token = first
        try? await Task.sleep(nanoseconds: 150_000_000)
        while let current = token {
            guard let response = try? await Innertube.shared.browseContinuation(current) else { break }
            let more = InnertubeParser.parsePlaylistShelf(response)
            let known = Set(songs.map(\.videoId))
            let fresh = (more?.songs ?? InnertubeParser.collectSongsDeep(response)).filter { !known.contains($0.videoId) }
            if fresh.isEmpty { break }
            songs += fresh
            token = more?.continuation
        }
    }
}

/** An album or playlist page (DetailScreen.kt's ReleaseHeader and track list). */
struct CollectionView: View {
    @State private var model: CollectionModel
    @State private var filter = ""
    @State private var filtering = false
    @State private var aboutOpen = false
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @Environment(Account.self) private var account
    @Environment(AppSettings.self) private var settings

    init(item: BrowseItem) {
        _model = State(initialValue: CollectionModel(item: item))
    }

    private var palette: ArtworkPalette { model.palette ?? .neutral }
    private var isAlbum: Bool { model.item.type == .album || model.item.browseId.hasPrefix("MPRE") }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(spacing: 0) {
                    header(size: geometry.size)
                    if filtering { filterField }
                    if isAlbum, let about = model.page?.description { aboutSection(about) }
                    if let error = model.error {
                        MessageState(text: error, button: "Retry") { Task { await model.load() } }
                    } else if model.page == nil {
                        ForEach(0..<8, id: \.self) { RowSkeleton(index: $0) }.opacity(0.4)
                    } else {
                        tracks
                        ForEach(model.page?.shelves ?? []) { shelf in
                            VStack(alignment: .leading, spacing: 0) {
                                SectionHeader(title: shelf.title)
                                HorizontalShelf {
                                    ForEach(shelf.items) { item in
                                        ShelfCard(item: item) { if let browse = item.browseItem { router.open(browse) } }
                                    }
                                }
                            }
                            .padding(.top, 22)
                        }
                    }
                }
                .padding(.bottom, Metrics.contentBottom(hasSong: player.song != nil))
            }
        }
        .background(palette.background.ignoresSafeArea())
        .preference(key: PageActionsKey.self, value: pageActions)
        .preference(key: PageColorKey.self, value: palette.background)
        .overlay {
            if router.reorderPlaylist == model.item.browseId, model.owned {
                ReorderPlaylistView(model: model, palette: palette) { router.reorderPlaylist = nil }
                    .transition(.opacity)
            }
        }
        .animation(.fastOutSlowIn(0.25), value: router.reorderPlaylist)
        .task { await model.load() }
        .onChange(of: router.playlistsChanged) { _, _ in Task { await model.load(force: true) } }
        .onChange(of: router.removedFromPlaylist?.setVideoId) { _, _ in
            guard let removed = router.removedFromPlaylist, model.item.browseId.hasSuffix(removed.playlistId) else { return }
            withAnimation(.fastOutSlowIn(0.2)) { model.removeRow(setVideoId: removed.setVideoId) }
        }
    }

    /** Search and the overflow flank Sort, once there are tracks to search and act on. */
    private var pageActions: PageActions {
        var items: [PageActions.Item] = []
        let hasSongs = !model.songs.isEmpty
        if hasSongs {
            items.append(.init(icon: filtering ? "xmark" : "magnifyingglass") {
                withAnimation(.fastOutSlowIn(0.22)) {
                    filtering.toggle()
                    if !filtering { filter = "" }
                }
            })
        }
        let browseId = model.item.browseId
        items.append(.init(icon: "line.3.horizontal.decrease") {
            withAnimation(.linear(duration: 0.15)) { router.sortMenu = browseId }
        })
        if hasSongs {
            items.append(.init(icon: "ellipsis") {
                router.browseMenuOwned = model.owned
                router.browseMenu = currentItem
            })
        }
        return PageActions(items: items)
    }

    /** The tracks in the page's chosen order, each with its place in the page's own. */
    private var sortedSongs: [(offset: Int, element: Song)] {
        settings.songSort(for: model.item.browseId).sorted(model.songs)
    }

    private var currentItem: BrowseItem {
        var item = model.item
        if let page = model.page {
            item.title = page.title
            item.subtitle = page.subtitle
            item.thumbnailUrl = page.thumbnailUrl ?? item.thumbnailUrl
        }
        return item
    }

    // MARK: Header

    private func header(size: CGSize) -> some View {
        let sleeve = min(size.width * 0.76, size.height * 0.5)
        let title = model.page?.title.nonBlank ?? model.item.title
        let meta = metaLine
        return VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.elevated)
                RemoteImage(url: Artwork.url(model.page?.thumbnailUrl ?? model.item.thumbnailUrl, px: 720))
            }
            .frame(width: sleeve, height: sleeve)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.thumbnailBorder, lineWidth: 1) }
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            Text(title).textStyle(.headlineMedium).foregroundStyle(.white)
                .multilineTextAlignment(.center).lineLimit(2)
                .padding(.horizontal, 24).padding(.top, 20)
            if !meta.credit.isEmpty {
                Text(meta.credit).font(.sfDisplay(19, .regular)).tracking(-0.3).foregroundStyle(palette.onBackgroundVariant).lineLimit(1)
                    .padding(.horizontal, 24).padding(.top, 2)
                    .onTapGesture {
                        if let id = model.page?.artistId { router.openArtist(id: id, name: meta.credit) }
                    }
            }
            if !meta.details.isEmpty {
                Text(meta.details).textStyle(.labelMedium).foregroundStyle(palette.onBackgroundVariant).padding(.top, 4)
            }
            actions.padding(.top, 18)
        }
        .padding(.top, Metrics.contentTop)
        .padding(.bottom, 18)
    }

    /** "Album · 2023 · 10 Tracks · 38 min" and the credit, out of the header's subtitle. */
    private var metaLine: (credit: String, details: String) {
        let subtitle = model.page?.subtitle ?? model.item.subtitle
        let parts = subtitle.replacingOccurrences(of: " · ", with: " • ").components(separatedBy: " • ")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let kinds = ["album", "single", "ep", "playlist"]
        let kind = parts.first { kinds.contains($0.lowercased()) }
        let year = parts.first { $0.count == 4 && Int($0) != nil }
        let credit = parts.filter { $0 != kind && $0 != year && !$0.lowercased().contains("song") && !$0.lowercased().contains("view")
            && !$0.lowercased().contains("minute") && !$0.lowercased().contains("hour") && !$0.lowercased().contains("track") }
            .joined(separator: ", ")
        var details: [String] = [kind, year].compactMap { $0 }
        if !model.songs.isEmpty {
            details.append("\(model.songs.count) \(model.songs.count == 1 ? "Track" : "Tracks")")
            let minutes = Int(model.songs.compactMap(\.duration).reduce(0, +) / 60)
            if minutes > 0 { details.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min") }
        }
        return (credit, details.joined(separator: " · "))
    }

    /** Shuffle, the white Play pill, and add-to-library. */
    private var actions: some View {
        HStack(spacing: 14) {
            circleButton("shuffle") { play(shuffled: true) }
            Button { play(shuffled: false) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill").font(.system(size: 16))
                    Text("Play").textStyle(.titleMedium)
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(.white, in: Capsule())
            }
            .buttonStyle(PressScale())
            circleButton(model.library?.saved == true ? "checkmark" : "plus") {
                guard let library = model.library else { return }
                let saving = !library.saved
                model.library?.saved = saving
                Task {
                    do {
                        try await Innertube.shared.savePlaylist(library.playlistId, saving)
                        player.showNotice(saving ? "Added to your library" : "Removed from your library")
                    } catch {
                        model.library?.saved = !saving
                        player.showNotice(error.localizedDescription)
                    }
                }
            }
            .disabled(!account.isSignedIn || model.library == nil)
            .opacity(account.isSignedIn && model.library != nil ? 1 : 0.38)
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 24)
        .disabled(model.songs.isEmpty)
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(.white.opacity(0.07), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(PressScale())
    }

    /** The list as it's shown: [index] is a position in the sorted order. */
    private func play(shuffled: Bool, from index: Int = 0) {
        let songs = sortedSongs.map(\.element)
        guard !songs.isEmpty else { return }
        let start = shuffled ? Int.random(in: 0..<songs.count) : index
        player.play(songs, from: start, source: QueueSource(title: model.page?.title ?? model.item.title,
                                                             kind: isAlbum ? .album : .playlist, id: model.item.browseId),
                    shuffled: shuffled)
    }

    // MARK: Filter and About

    private var filterField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.white.opacity(0.6))
            TextField("", text: $filter, prompt: Text("Search this list").foregroundStyle(.white.opacity(0.5)))
                .textStyle(.bodyLarge).foregroundStyle(.white)
                .autocorrectionDisabled()
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6)).frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 0.5))
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    private func aboutSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("About the album").textStyle(.titleMedium).foregroundStyle(.white)
            Text(text).font(.sfDisplay(16, .medium)).foregroundStyle(palette.onBackgroundVariant)
                .lineLimit(aboutOpen ? nil : 2)
                .onTapGesture { withAnimation(.fastOutSlowIn(0.25)) { aboutOpen.toggle() } }
            Button(aboutOpen ? "Less" : "More") { withAnimation(.fastOutSlowIn(0.25)) { aboutOpen.toggle() } }
                .textStyle(.labelLarge).foregroundStyle(palette.accent).padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    // MARK: Tracks

    @ViewBuilder
    private var tracks: some View {
        // Sorted: `offset` is the row's place in the page's own order (an album's track number).
        let all = sortedSongs
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = query.isEmpty ? all : all.filter {
            $0.element.title.lowercased().contains(query) || $0.element.artist.lowercased().contains(query)
                || ($0.element.albumName?.lowercased().contains(query) ?? false)
        }
        if shown.isEmpty, !query.isEmpty {
            MessageState(text: "Nothing here matches “\(filter)”")
        }
        ForEach(Array(shown.enumerated()), id: \.element.element.videoId) { position, entry in
            SongRow(song: entry.element,
                    leading: isAlbum ? .number(entry.offset + 1) : .artwork,
                    accent: palette.accent,
                    subtitleColor: palette.onBackgroundVariant,
                    fallbackArtwork: model.page?.thumbnailUrl,
                    ownPlaylistId: model.owned ? String(model.item.browseId.dropFirst(2)) : nil) {
                play(shuffled: false, from: all.firstIndex { $0.offset == entry.offset } ?? 0)
            }
            if position < shown.count - 1 {
                InsetDivider(inset: isAlbum ? Metrics.numberedRowDividerInset : Metrics.rowDividerInset, color: .white.opacity(0.12))
            }
        }
    }
}

/** The actions a page puts in the top bar's pill, read by the shell. */
struct PageActions: Equatable {
    struct Item: Equatable {
        let icon: String
        let action: () -> Void
        static func == (a: Item, b: Item) -> Bool { a.icon == b.icon }
    }

    var items: [Item]
}

struct PageActionsKey: PreferenceKey {
    static let defaultValue: PageActions? = nil
    static func reduce(value: inout PageActions?, nextValue: () -> PageActions?) { value = nextValue() ?? value }
}

/** The colour a page paints behind itself, for the shell's top and bottom fades. */
struct PageColorKey: PreferenceKey {
    static let defaultValue: Color? = nil
    static func reduce(value: inout Color?, nextValue: () -> Color?) { value = nextValue() ?? value }
}

/**
 * "Reorder songs" (ReorderPlaylistPage): the playlist's rows with grips, over
 * the page's own colour, and Save once the order has changed.
 */
private struct ReorderPlaylistView: View {
    let model: CollectionModel
    let palette: ArtworkPalette
    var onClose: () -> Void
    @State private var order: [Song] = []
    @State private var saving = false

    var body: some View {
        let changed = order.map(\.setVideoId) != model.songs.map(\.setVideoId)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white).frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                VStack(alignment: .leading, spacing: 0) {
                    Text("Reorder songs").textStyle(.titleLarge).foregroundStyle(.white)
                    Text(model.page?.title ?? model.item.title).textStyle(.bodyMedium).foregroundStyle(palette.onBackgroundVariant).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { save() } label: {
                    ZStack {
                        if saving { ProgressView().controlSize(.small).tint(.white) } else { Text("Save").textStyle(.titleMedium) }
                    }
                    .foregroundStyle(changed ? .black : palette.onBackgroundVariant)
                    .padding(.horizontal, 20).frame(height: 40)
                    .background(changed && !saving ? .white : .white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!changed || saving)
            }
            .padding(.leading, 8).padding(.trailing, 22).padding(.bottom, 8)
            Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
            List {
                ForEach(order, id: \.setVideoId) { song in
                    HStack(spacing: 14) {
                        Cover(url: song.artwork(rowArtPx), size: 48, radius: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).textStyle(.titleMedium).foregroundStyle(.white).lineLimit(1)
                            Text(song.artist).textStyle(.bodyMedium).foregroundStyle(palette.onBackgroundVariant).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.white.opacity(0.12))
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                .moveDisabled(saving)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
        .padding(.top, Metrics.contentTop - 8)
        .background(palette.background.ignoresSafeArea())
        .onAppear { order = model.songs.filter { $0.setVideoId != nil } }
    }

    private func save() {
        saving = true
        Task {
            let saved = await model.saveOrder(order)
            saving = false
            PlayerModel.shared.showNotice(saved ? "Playlist order saved" : "Couldn't save the new order")
            if saved { onClose() }
        }
    }
}
