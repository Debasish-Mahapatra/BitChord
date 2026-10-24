import SwiftUI

enum SearchChip: String, CaseIterable, Identifiable {
    case all = "All", songs = "Songs", videos = "Videos", albums = "Albums", artists = "Artists", playlists = "Playlists"

    var id: String { rawValue }

    var params: String? {
        switch self {
        case .all: return nil
        case .songs: return SearchFilter.songs.params
        case .videos: return "EgWKAQIQAWoKEAkQChAFEAMQBA=="
        case .albums: return SearchFilter.albums.params
        case .artists: return SearchFilter.artists.params
        case .playlists: return SearchFilter.playlists.params
        }
    }
}

@MainActor
@Observable
final class SearchModel {
    var text = "" {
        didSet { if text != oldValue { typed() } }
    }
    var editing = false
    private(set) var suggestions: [String] = []
    private(set) var typeahead: [SearchResult] = []
    private(set) var submitted: String?
    private(set) var chip: SearchChip = .all
    private(set) var rows: [SearchResult] = []
    private(set) var loading = false
    private(set) var error: String?
    private var continuation: String?
    private var loadingMore = false
    private var suggestTask: Task<Void, Never>?
    private var typeaheadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    /** Results already seen, by query and filter, shown at once when asked again. */
    private var cache: [String: InnertubeParser.SearchPage] = [:]

    /** Suggestions after 180 ms of quiet; live media after 350 ms, at most 15. The search itself waits for submit. */
    private func typed() {
        suggestTask?.cancel()
        typeaheadTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            suggestions = []
            typeahead = []
            return
        }
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let response = try? await Innertube.shared.searchSuggestions(query), !Task.isCancelled else { return }
            suggestions = InnertubeParser.parseSearchSuggestions(response)
        }
        typeaheadTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let response = try? await Innertube.shared.search(query), !Task.isCancelled else { return }
            typeahead = Array(InnertubeParser.parseSearchPage(response).rows.map { row -> SearchResult in
                if case .topTrack(let song) = row { return .track(song) }
                return row
            }.prefix(15))
        }
    }

    func submit(_ query: String? = nil, chip newChip: SearchChip? = nil) {
        if let query { text = query }
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        editing = false
        suggestTask?.cancel()
        typeaheadTask?.cancel()
        suggestions = []
        typeahead = []
        submitted = query
        chip = newChip ?? chip
        let key = "\(chip.rawValue):\(query.lowercased())"
        if let hit = cache[key] {
            rows = hit.rows
            continuation = hit.continuation
            error = nil
            loading = false
            return
        }
        rows = []
        error = nil
        loading = true
        searchTask?.cancel()
        let chip = self.chip
        searchTask = Task {
            do {
                let response = try await Innertube.shared.search(query, params: chip.params)
                let page = InnertubeParser.parseSearchPage(response, includeVideos: chip == .videos)
                guard !Task.isCancelled else { return }
                cache[key] = page
                rows = page.rows
                continuation = page.continuation
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            loading = false
        }
    }

    func select(_ newChip: SearchChip) {
        guard newChip != chip else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        submit(chip: newChip)
    }

    func loadMore() async {
        guard let token = continuation, !loadingMore, chip != .all else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let response = try? await Innertube.shared.searchContinuation(token) else { return }
        let page = InnertubeParser.parseSearchPage(response, includeVideos: chip == .videos)
        let seen = Set(rows.map(\.id))
        rows += page.rows.filter { !seen.contains($0.id) }
        continuation = page.continuation
    }

    var hasMore: Bool { continuation != nil && chip != .all }

    func clear() {
        text = ""
        submitted = nil
        rows = []
        error = nil
        continuation = nil
    }
}

struct SearchView: View {
    @State private var model = SearchModel()
    @FocusState private var focused: Bool
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @Environment(Account.self) private var account
    private let history = SearchHistory.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.editing, !model.text.isEmpty, !(model.suggestions.isEmpty && model.typeahead.isEmpty) {
                    typing
                } else if model.submitted == nil || model.text.isEmpty {
                    recent
                } else {
                    chips
                    results
                }
            }
            .padding(.top, Metrics.contentTop)
            .padding(.bottom, Metrics.contentBottom(hasSong: player.song != nil))
        }
        .scrollDismissesKeyboard(.immediately)
        .overlay(alignment: .top) { field }
        .onChange(of: router.searchFocusToken) { _, _ in
            model.clear()
            focused = true
        }
        .onChange(of: focused) { _, isFocused in if isFocused { model.editing = true } }
        .onChange(of: router.tab) { _, tab in if tab != .search { focused = false } }
    }

    // MARK: Field

    /** In the top bar: 46pt tall, radius 11, the magnifier submits. */
    private var field: some View {
        HStack(spacing: 4) {
            Button { model.submit() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.onSurfaceVariant).frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(model.text.trimmingCharacters(in: .whitespaces).isEmpty)
            TextField("", text: $model.text, prompt: Text("Artists, Songs, Lyrics and More").foregroundStyle(Theme.onSurfaceVariant))
                .textStyle(.bodyLarge)
                .foregroundStyle(Theme.onBackground)
                .tint(Theme.primary)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { model.submit() }
            if !model.text.isEmpty {
                Button {
                    model.text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.onSurfaceVariant).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: 46)
        .background(Theme.surfaceVariant, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.leading, Metrics.gutter)
        .padding(.trailing, Metrics.gutter + 48 + 8)
        .frame(height: Metrics.topBarHeight)
    }

    // MARK: Before typing

    @ViewBuilder
    private var recent: some View {
        if history.entries.isEmpty {
            MessageState(text: "Search millions of songs on YouTube Music.")
        } else {
            HStack {
                Text("Recent searches").textStyle(.headlineMedium).foregroundStyle(Theme.onBackground)
                Spacer()
                Button { history.clear() } label: {
                    Text("Clear").textStyle(.titleMedium).foregroundStyle(Theme.primary)
                        .padding(.horizontal, 10).padding(.vertical, 4).contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 10)
            ForEach(history.entries) { entry in
                HStack(spacing: 14) {
                    Cover(url: Artwork.url(entry.artworkUrl, px: rowArtPx), size: 52, radius: 8, circle: entry.kind == .artist)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).textStyle(.titleMedium)
                            .foregroundStyle(Theme.onBackground).lineLimit(1)
                        Text(entry.subtitle.isEmpty ? entry.typeLabel : entry.subtitle).textStyle(.bodyMedium)
                            .foregroundStyle(Theme.onSurfaceVariant).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { history.remove(entry) } label: {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.onSurfaceVariant).frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, Metrics.gutter).padding(.trailing, 8).padding(.vertical, 6)
                .background(Theme.background)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let song = entry.song {
                        player.startRadio(song)
                    } else if entry.kind != .track {
                        let type: BrowseType = entry.kind == .album ? .album : entry.kind == .artist ? .artist : .playlist
                        router.open(BrowseItem(browseId: entry.id, title: entry.title, subtitle: entry.subtitle, thumbnailUrl: entry.artworkUrl, type: type))
                    }
                }
                // A recent track gets a result row's menu and swipe, so it can be queued without interrupting.
                .modifier(RecentTrackActions(song: entry.song))
            }
        }
    }

    // MARK: While typing

    @ViewBuilder
    private var typing: some View {
        Spacer().frame(height: 8)
        // Element 0 echoes what was typed; up to three after it.
        ForEach(Array(model.suggestions.dropFirst().prefix(3)), id: \.self) { suggestion in
            HStack(spacing: 16) {
                Image(systemName: "magnifyingglass").font(.system(size: 19)).foregroundStyle(Theme.onSurfaceVariant).frame(width: 22)
                Text(suggestion).textStyle(.titleMedium).foregroundStyle(Theme.onBackground).lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    model.text = suggestion
                } label: {
                    Image(systemName: "arrow.up.left").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.onSurfaceVariant).frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, Metrics.gutter).padding(.trailing, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                focused = false
                model.submit(suggestion)
            }
        }
        if !model.typeahead.isEmpty {
            Rectangle().fill(Theme.outline.opacity(0.4)).frame(height: 0.5).padding(.horizontal, Metrics.gutter)
            ForEach(model.typeahead) { row in
                switch row {
                case .track(let song), .topTrack(let song):
                    HStack(spacing: 14) {
                        Cover(url: song.artwork(rowArtPx), size: 52, radius: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            SongTitle(text: song.title, explicit: song.isExplicit,
                                      color: Theme.onBackground)
                            Text(song.artist).textStyle(.bodyMedium).foregroundStyle(Theme.onSurfaceVariant).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Metrics.gutter).padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { playSong(song) }
                    .songContextMenu(song)
                case .browse(let item):
                    BrowseRow(item: item) { openItem(item) }
                }
            }
        }
    }

    // MARK: Results

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchChip.allCases) { chip in
                    let selected = chip == model.chip
                    Text(chip.rawValue).textStyle(.labelLarge)
                        .foregroundStyle(selected ? Theme.background : Theme.onBackground)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(selected ? Theme.onBackground : Theme.surfaceVariant, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onTapGesture { model.select(chip) }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var results: some View {
        if model.loading {
            ForEach(0..<8, id: \.self) { RowSkeleton(index: $0, circle: model.chip == .artists) }
        } else if let error = model.error {
            MessageState(text: error)
        } else if model.rows.isEmpty {
            MessageState(text: "No results for “\(model.submitted ?? "")”.")
        } else if model.chip == .all {
            allSections
        } else {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                resultRow(row)
                    .onAppear { if index >= model.rows.count - 4 { Task { await model.loadMore() } } }
                if index < model.rows.count - 1 { InsetDivider() }
            }
            if model.hasMore { ForEach(0..<3, id: \.self) { RowSkeleton(index: $0) } }
        }
    }

    /** The All page: the top result, then Songs, Artists, Albums, Playlists, More. */
    @ViewBuilder
    private var allSections: some View {
        let top = model.rows.first
        if let top, case .topTrack(let song) = top {
            topResult(song)
        }
        let rest = model.rows.dropFirst(top.map { if case .topTrack = $0 { return 1 } else { return 0 } } ?? 0)
        let songs = rest.filter { if case .track = $0 { return true } else { return false } }
        let browse = rest.compactMap { row -> BrowseItem? in if case .browse(let item) = row { return item } else { return nil } }
        let groups: [(String, [SearchResult])] = [
            ("Songs", Array(songs)),
            ("Artists", browse.filter { $0.type == .artist }.map(SearchResult.browse)),
            ("Albums", browse.filter { $0.type == .album }.map(SearchResult.browse)),
            ("Playlists", browse.filter { $0.type == .playlist }.map(SearchResult.browse)),
            ("More", browse.filter { $0.type == .other }.map(SearchResult.browse)),
        ]
        ForEach(groups.filter { !$0.1.isEmpty }, id: \.0) { title, rows in
            Text(title).textStyle(.titleSmall).foregroundStyle(Theme.onSurface)
                .padding(.horizontal, Metrics.gutter).padding(.top, 16).padding(.bottom, 6)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                resultRow(row)
                if index < rows.count - 1 { InsetDivider() }
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ row: SearchResult) -> some View {
        switch row {
        case .track(let song), .topTrack(let song):
            SongRow(song: song) { playSong(song) }
        case .browse(let item):
            BrowseRow(item: item) { openItem(item) }
        }
    }

    /** "Top result": 72pt art, the title in titleLarge, then Play and Playlist. */
    private func topResult(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Top result").textStyle(.labelLarge).foregroundStyle(Theme.onSurface).padding(.bottom, 10)
            HStack(spacing: 14) {
                Cover(url: song.artwork(cardArtPx), size: 72, radius: 10, border: false)
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title).textStyle(.titleLarge).foregroundStyle(Theme.onBackground).lineLimit(2)
                    Text(song.artist).textStyle(.bodyMedium).foregroundStyle(Theme.onSurfaceVariant).lineLimit(1)
                }
                Spacer(minLength: 0)
                MoreButton(color: Theme.onSurface) { router.songMenu = song }
            }
            .contentShape(Rectangle())
            .onTapGesture { playSong(song) }
            .songContextMenu(song)
            HStack(spacing: 10) {
                outlined("Play", icon: "play.fill") { playSong(song) }
                outlined("Playlist", icon: "text.badge.plus") { router.playlistPicker = song }
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .background(Theme.background)
        .swipeToQueue(song)
    }

    private func outlined(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(title).textStyle(.labelLarge)
            }
            .foregroundStyle(Theme.onSurface)
            .padding(.horizontal, 20)
            .frame(height: 40)
            .overlay(Capsule().stroke(Theme.outline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /** A song from Search starts a radio from it, and is remembered. */
    private func playSong(_ song: Song) {
        focused = false
        history.record(song: song)
        player.startRadio(song)
    }

    private func openItem(_ item: BrowseItem) {
        focused = false
        history.record(item: item)
        router.open(item)
    }
}

/** A recent search that is a track: the held menu and swipe-to-queue a result row has. */
private struct RecentTrackActions: ViewModifier {
    let song: Song?

    func body(content: Content) -> some View {
        if let song {
            content.songContextMenu(song).swipeToQueue(song)
        } else {
            content
        }
    }
}
