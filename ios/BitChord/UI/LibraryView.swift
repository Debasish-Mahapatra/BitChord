import SwiftUI

@MainActor
@Observable
final class LibraryModel {
    struct Section: Identifiable {
        let title: String
        let items: [ShelfItem]
        var id: String { title }
    }

    private(set) var sections: [Section] = []
    private(set) var loading = false
    private(set) var error: String?
    private var loadedFor: String?

    /** The account's library feeds, in the phone's order: Playlists (always), Albums, Artists, Subscriptions. */
    func load(for session: Session?, force: Bool = false) async {
        guard let session else {
            sections = []
            loadedFor = nil
            return
        }
        guard force || loadedFor != session.key else { return }
        loading = sections.isEmpty
        defer { loading = false }
        let feeds = [("Playlists", "FEmusic_liked_playlists"), ("Albums", "FEmusic_liked_albums"),
                     ("Artists", "FEmusic_library_corpus_track_artists"), ("Subscriptions", "FEmusic_library_corpus_artists")]
        var loaded: [Section] = []
        var failure: Error?
        for (title, browseId) in feeds {
            do {
                let response = try await Innertube.shared.browse(browseId)
                let items = InnertubeParser.parseLibraryItems(response).items
                if title == "Playlists" || !items.isEmpty { loaded.append(Section(title: title, items: items)) }
            } catch {
                failure = error
            }
        }
        if loaded.isEmpty, let failure {
            error = failure.localizedDescription
        } else {
            sections = loaded
            error = nil
            loadedFor = session.key
        }
    }
}

struct LibraryView: View {
    @State private var model = LibraryModel()
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @Environment(Account.self) private var account
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Library").textStyle(.displayLarge).foregroundStyle(Theme.onBackground)
                    .padding(.horizontal, Metrics.gutter).padding(.vertical, 8)
                if !account.isSignedIn {
                    // The row that makes a playlist is drawn even signed out, empty but for its tile.
                    shelf(.init(title: "Playlists", items: []))
                    MessageState(text: "Sign in to your Google account to see your liked songs, playlists, and YouTube Music history.",
                                 button: "Sign in") { account.presentSignIn = true }
                } else if model.loading {
                    ShelfSkeleton()
                    ForEach(0..<7, id: \.self) { RowSkeleton(index: $0) }
                } else if let error = model.error {
                    MessageState(text: error, button: "Retry") { Task { await model.load(for: account.session, force: true) } }
                } else {
                    ForEach(model.sections) { section in shelf(section) }
                }
            }
            .padding(.top, Metrics.contentTop)
            .padding(.bottom, Metrics.contentBottom(hasSong: player.song != nil))
        }
        .refreshable { await model.load(for: account.session, force: true) }
        .task(id: account.session?.key) { await model.load(for: account.session) }
        .onChange(of: router.playlistsChanged) { _, _ in Task { await model.load(for: account.session, force: true) } }
    }

    /** LibraryGridShelf: five slots, the Playlists tile counting as one, and "Show all" past that. */
    private func shelf(_ section: LibraryModel.Section) -> some View {
        let isPlaylists = section.title == "Playlists"
        let items = isPlaylists ? settings.pinnedFirst(section.items) : section.items
        let leading = isPlaylists ? 1 : 0
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title).textStyle(.headlineMedium).foregroundStyle(Theme.onBackground).lineLimit(2)
                Spacer()
                if items.count + leading > 5 {
                    Button { router.push(.showAll(title: section.title, items: items, library: true)) } label: {
                        Text("Show all").textStyle(.titleSmall).foregroundStyle(Theme.primary).padding(.leading, 12).padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 10)
            HorizontalShelf(spacing: Metrics.gridSpacing) {
                if isPlaylists { NewPlaylistCard(width: Metrics.shelfCardWidth) }
                ForEach(items.prefix(5 - leading)) { item in
                    ShelfCard(item: item, isPinned: isPlaylists && settings.pinnedPlaylists.contains(item.browseId ?? "")) {
                        if let browse = item.browseItem { router.open(browse) }
                    }
                }
            }
        }
        .padding(.bottom, 26)
    }
}

/** NewShelfCard: a Plus on a blank square, "New playlist", "Saved to YouTube Music". */
struct NewPlaylistCard: View {
    /** Nil: the grid cell's width. */
    var width: CGFloat?
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceVariant)
                .aspectRatio(1, contentMode: .fit)
                .frame(width: width)
                .overlay { Image(systemName: "plus").font(.system(size: 32, weight: .medium)).foregroundStyle(Theme.primary) }
            Text("New playlist").textStyle(.titleMedium).foregroundStyle(Theme.onBackground).lineLimit(1).padding(.top, 10)
            Text("Saved to YouTube Music").textStyle(.bodyMedium).foregroundStyle(Theme.onSurfaceVariant).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { router.newPlaylist = true }
    }
}

/**
 * "Show all": the grid of a shelf's cards, 2–5 columns of at least 140pt. A
 * Library shelf's is pinned-first and then in the top bar's sort, Playlists
 * leading with the tile that makes one.
 */
struct ShowAllView: View {
    let title: String
    let items: [ShelfItem]
    var library = false
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @Environment(AppSettings.self) private var settings

    /** Re-read live, so a pin toggled from this page's own menu moves the card at once. */
    private var shown: [ShelfItem] {
        library ? settings.librarySort.sorted(settings.pinnedFirst(items)) : items
    }

    var body: some View {
        GeometryReader { geometry in
            let columns = max(2, min(5, Int((geometry.size.width - 32 + 12) / (140 + 12))))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageTitle(text: title)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns), spacing: 20) {
                        if library, title == "Playlists" { NewPlaylistCard() }
                        ForEach(shown) { item in
                            GridCard(item: item, isPinned: library && settings.pinnedPlaylists.contains(item.browseId ?? "")) {
                                if let browse = item.browseItem { router.open(browse) } else if let song = item.asSong { player.startRadio(song) }
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .animation(.fastOutSlowIn(0.25), value: shown.map(\.id))
                }
                .padding(.top, Metrics.contentTop)
                .padding(.bottom, Metrics.contentBottom(hasSong: player.song != nil))
            }
        }
    }
}

/** A shelf card that takes its grid cell's width. */
struct GridCard: View {
    let item: ShelfItem
    var radius: CGFloat = 12
    var isPinned = false
    var onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Cover(url: Artwork.url(item.thumbnailUrl, px: cardArtPx), radius: radius)
                .aspectRatio(1, contentMode: .fit)
            HStack(spacing: 4) {
                if isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Theme.onSurfaceVariant)
                        .accessibilityLabel("Pinned")
                }
                Text(item.title).textStyle(.titleMedium).foregroundStyle(Theme.onBackground).lineLimit(1)
            }
            .padding(.top, 10)
            Text(item.subtitle.isEmpty ? " " : item.subtitle).textStyle(.bodyMedium).foregroundStyle(Theme.onSurfaceVariant).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .shelfContextMenu(item)
    }
}

/** History: YouTube Music's own when signed in, this phone's otherwise. Tapping a row plays on from there. */
struct HistoryView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(Account.self) private var account
    @State private var remote: [Song]?
    @State private var loading = false

    private var songs: [Song] { remote ?? History.shared.songs }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageTitle(text: "History")
                if loading {
                    ForEach(0..<10, id: \.self) { RowSkeleton(index: $0) }
                } else if songs.isEmpty {
                    MessageState(text: "Songs you play show up here.")
                } else {
                    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                        SongRow(song: song) {
                            player.play(songs, from: index, source: QueueSource(title: "History", kind: .library))
                        }
                        if index < songs.count - 1 { InsetDivider(color: Theme.outline.opacity(0.5)) }
                    }
                }
            }
            .padding(.top, Metrics.contentTop)
            .padding(.bottom, Metrics.contentBottom(hasSong: player.song != nil))
        }
        .task {
            guard account.isSignedIn else { return }
            loading = true
            if let response = try? await Innertube.shared.browse("FEmusic_history") {
                remote = InnertubeParser.collectSongsDeep(response)
            }
            loading = false
        }
    }
}
