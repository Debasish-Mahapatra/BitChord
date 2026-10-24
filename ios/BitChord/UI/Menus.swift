import SwiftUI
import UIKit

/** The song actions, in the phone's order, for both the held menu and the ⋮ sheet. */
struct SongActions {
    let song: Song
    var inPlayer = false
    /** The account's own playlist this row is in, which adds "Remove from this playlist". */
    var ownPlaylistId: String? = nil

    /** A page the ⋮ sheet swaps its rows for; the held menu shows it some other way. */
    enum Page: Equatable {
        case songInfo(Song)
    }

    struct Action: Identifiable {
        let id: String
        let title: String
        let icon: String
        /** Like and Dislike leave the ⋮ sheet open so the new state shows. */
        var keepsOpen = false
        var tint: Color? = nil
        /** In the ⋮ sheet, opens this page instead of running. */
        var page: Page? = nil
        /** A row still waiting on what it opens: drawn with a spinner, and does nothing yet. */
        var loading = false
        let run: @MainActor () -> Void
    }

    @MainActor
    var groups: [[Action]] {
        let player = PlayerModel.shared
        let router = Router.shared
        var queue: [Action] = [
            Action(id: "radio", title: "Start radio", icon: "dot.radiowaves.left.and.right") { player.startRadio(song) },
            Action(id: "next", title: "Play next", icon: "text.line.first.and.arrowtriangle.forward") { player.playNext(song) },
            Action(id: "queue", title: "Add to queue", icon: "text.badge.plus") { player.addToQueue(song) },
        ]
        if inPlayer { queue.removeAll { $0.id != "radio" } }
        // A row that arrived without its album or artist reads them off its watch entry (TrackLinks).
        let links = TrackLinks.shared
        let linked = links.links[song.videoId]
        let resolving = links.resolving.contains(song.videoId)
        var open: [Action] = []
        if let albumId = song.albumId ?? linked?.albumId {
            let albumName = song.albumName ?? linked?.albumName
            open.append(Action(id: "album", title: "Open album", icon: "square.stack") {
                router.openFromPlayer { router.openAlbum(id: albumId, title: albumName) }
            })
        } else if resolving {
            open.append(Action(id: "album", title: "Open album", icon: "square.stack", loading: true) {})
        }
        let artist = song.artistId.map { ($0, song.artists.first?.name ?? song.artist) }
            ?? song.artists.first?.browseId.map { ($0, song.artists.first?.name ?? song.artist) }
            ?? (linked?.artistId ?? linked?.artists.first?.browseId).map { ($0, linked?.artists.first?.name ?? song.artist) }
        if let (artistId, name) = artist {
            open.append(Action(id: "artist", title: "Open artist", icon: "person") {
                router.openFromPlayer { router.openArtist(id: artistId, name: name) }
            })
        } else if resolving {
            open.append(Action(id: "artist", title: "Open artist", icon: "person", loading: true) {})
        }
        open.append(Action(id: "info", title: "Song Info", icon: "info.circle", page: .songInfo(song)) { router.songInfo = song })
        let share = [Action(id: "share", title: "Share", icon: "square.and.arrow.up") { Share.present(url: "https://music.youtube.com/watch?v=\(song.videoId)") }]
        // Signed in: Like, Dislike and Add to playlist lead (SongActionsSheet order).
        var account: [Action] = []
        if Account.shared.isSignedIn {
            let likes = Likes.shared
            let rating = likes.rating(song.videoId)
            account = [
                Action(id: "like", title: rating == .like ? "Remove from Liked Music" : "Like",
                       icon: rating == .like ? "heart.fill" : "heart", keepsOpen: true,
                       tint: rating == .like ? Theme.playingAccent : nil) { likes.toggleLike(song) },
                Action(id: "dislike", title: rating == .dislike ? "Undo dislike" : "Dislike",
                       icon: rating == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown", keepsOpen: true) { likes.toggleDislike(song) },
                Action(id: "playlist", title: "Add to playlist", icon: "text.badge.plus") { router.playlistPicker = song },
            ]
            if let playlistId = ownPlaylistId, let setVideoId = song.setVideoId {
                account.append(Action(id: "remove", title: "Remove from this playlist", icon: "text.badge.minus") {
                    Task {
                        do {
                            try await Innertube.shared.removeFromPlaylist(playlistId, entries: [(setVideoId, song.videoId)])
                            router.removedFromPlaylist = (playlistId, setVideoId)
                        } catch {
                            PlayerModel.shared.showNotice(error.localizedDescription)
                        }
                    }
                })
            }
        }
        // One separator, under the account's rows; everything after is one list.
        return [account, queue + open + share].filter { !$0.isEmpty }
    }
}

/** Album and playlist actions (artists never get a menu). */
struct BrowseActions {
    let item: BrowseItem
    var fromCard = true
    /** A playlist the account made: Rename and Delete. */
    var owned = false
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @MainActor
    var groups: [[SongActions.Action]] {
        let router = Router.shared
        var actions: [SongActions.Action] = []
        if fromCard {
            actions.append(.init(id: "play", title: "Play", icon: "play") { Task { await Collection.play(item, shuffled: false) } })
            actions.append(.init(id: "shuffle", title: "Shuffle", icon: "shuffle") { Task { await Collection.play(item, shuffled: true) } })
        }
        actions.append(.init(id: "next", title: "Play next", icon: "text.line.first.and.arrowtriangle.forward") { Task { await Collection.enqueue(item, next: true) } })
        actions.append(.init(id: "queue", title: "Add to queue", icon: "text.badge.plus") { Task { await Collection.enqueue(item, next: false) } })
        var open: [SongActions.Action] = []
        if fromCard {
            open.append(.init(id: "open", title: item.type == .album ? "Open album" : "Open playlist", icon: "chevron.right") { router.open(item) })
        }
        let link = item.type == .album
            ? "https://music.youtube.com/browse/\(item.browseId)"
            : "https://music.youtube.com/playlist?list=\(item.browseId.hasPrefix("VL") ? String(item.browseId.dropFirst(2)) : item.browseId)"
        open.append(.init(id: "share", title: "Share", icon: "square.and.arrow.up") { Share.present(url: link) })
        // Pinning only touches what sits at the top of this phone's Library, so any playlist can be.
        if item.type == .playlist {
            let settings = AppSettings.shared
            let pinned = settings.pinnedPlaylists.contains(item.browseId)
            open.append(.init(id: "pin", title: pinned ? "Unpin" : "Pin", icon: pinned ? "pin.slash" : "pin") {
                if !settings.togglePinned(item.browseId), !pinned {
                    PlayerModel.shared.showNotice("Only \(AppSettings.maxPinnedPlaylists) playlists can be pinned")
                }
            })
        }
        var own: [SongActions.Action] = []
        if owned {
            if let onRename { own.append(.init(id: "rename", title: "Rename", icon: "pencil", run: onRename)) }
            // Rearranged on the playlist's own page: opened first when the menu came from anywhere else.
            own.append(.init(id: "reorder", title: "Reorder songs", icon: "arrow.up.arrow.down") {
                if case .browse(let open) = router.top, open.browseId == item.browseId {} else { router.open(item) }
                router.reorderPlaylist = item.browseId
            })
            if let onDelete {
                // The first tap turns the row into its own confirmation; the second deletes.
                if router.confirmingDelete == item.browseId {
                    own.append(.init(id: "delete", title: "Delete “\(item.title)”? Tap again to confirm.", icon: "trash.fill",
                                     tint: .red, run: onDelete))
                } else {
                    own.append(.init(id: "delete", title: "Delete playlist", icon: "trash", keepsOpen: true) {
                        router.confirmingDelete = item.browseId
                    })
                }
            }
        }
        return [actions, open, own].filter { !$0.isEmpty }
    }
}

/** Loading a whole album or playlist for the menu's Play / Play next / Add to queue. */
enum Collection {
    static func songs(_ item: BrowseItem) async -> [Song] {
        guard let page = try? await Innertube.shared.browse(item.browseId) else { return [] }
        return InnertubeParser.parseCollection(page, browseId: item.browseId).songs
    }

    @MainActor
    static func play(_ item: BrowseItem, shuffled: Bool) async {
        let songs = await songs(item)
        let kind: QueueSource.Kind = item.type == .album ? .album : .playlist
        PlayerModel.shared.play(songs, from: shuffled ? Int.random(in: 0..<max(1, songs.count)) : 0,
                                source: QueueSource(title: item.title, kind: kind, id: item.browseId), shuffled: shuffled)
    }

    @MainActor
    static func enqueue(_ item: BrowseItem, next: Bool) async {
        let songs = await songs(item)
        let player = PlayerModel.shared
        for song in (next ? songs.reversed() : songs) {
            if next { player.playNext(song) } else { player.addToQueue(song) }
        }
    }
}

enum Share {
    @MainActor
    static func present(url: String) {
        guard let link = URL(string: url),
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(UIActivityViewController(activityItems: [link], applicationActivities: nil), animated: true)
    }
}

// MARK: - Held menus (the lift-out context menu)

extension View {
    func songContextMenu(_ song: Song) -> some View {
        contextMenu {
            ForEach(Array(SongActions(song: song).groups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group.filter { !$0.loading }) { action in
                        Button(action: action.run) { Label(action.title, systemImage: action.icon) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    func browseContextMenu(_ item: BrowseItem) -> some View {
        if item.type == .artist {
            self
        } else {
            contextMenu {
                ForEach(Array(BrowseActions(item: item).groups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group) { action in
                            Button(action: action.run) { Label(action.title, systemImage: action.icon) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    func shelfContextMenu(_ item: ShelfItem) -> some View {
        if let song = item.asSong, item.browseId == nil {
            songContextMenu(song)
        } else if let browse = item.browseItem {
            browseContextMenu(browse)
        } else {
            self
        }
    }

    /** Swipe a row either way past 45% of its width to add it to the queue. */
    func swipeToQueue(_ song: Song) -> some View {
        modifier(SwipeToQueue(song: song))
    }
}

private struct SwipeToQueue: ViewModifier {
    let song: Song
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 1
    @State private var armed = false

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background {
                HStack {
                    label
                    Spacer()
                    label
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.primary.opacity(0.18))
                .opacity(offset == 0 ? 0 : 1)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max(1, $0) }
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                        offset = value.translation.width
                        let past = abs(offset) >= width * 0.45
                        if past != armed {
                            armed = past
                            if past { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                        }
                    }
                    .onEnded { _ in
                        if armed {
                            if AppSettings.shared.playNextOnSwipe { PlayerModel.shared.playNext(song) } else { PlayerModel.shared.addToQueue(song) }
                        }
                        armed = false
                        withAnimation(.compose(dampingRatio: 0.8, stiffness: 400)) { offset = 0 }
                    }
            )
    }

    private var label: some View {
        let next = AppSettings.shared.playNextOnSwipe
        return HStack(spacing: 6) {
            Image(systemName: next ? "text.line.first.and.arrowtriangle.forward" : "text.badge.plus").font(.system(size: 18))
            Text(next ? "Play next" : "Queue").textStyle(.labelMedium)
        }
        .foregroundStyle(Theme.primary)
    }
}

// MARK: - The ⋮ sheet

/** The bottom sheet ⋮ opens: the track (or release) on top, then the actions in groups. */
struct ActionSheet: View {
    let title: String
    let subtitle: String
    let artwork: URL?
    var circle = false
    /** Built in the body, so a Like or Dislike redraws its row. */
    let groups: @MainActor () -> [[SongActions.Action]]
    var onAppear: (() async -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var page: SongActions.Page?

    var body: some View {
        Group {
            switch page {
            case .songInfo(let song):
                ScrollView { SongInfoPage(song: song) { withAnimation(.fastOutSlowIn(0.2)) { page = nil } } }
                    .transition(.opacity)
            case nil:
                rows.transition(.opacity)
            }
        }
        .task { await onAppear?() }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground {
            ZStack {
                Color(hex: 0x121212)
                RemoteImage(url: artwork).blur(radius: 72).opacity(0.55)
                LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Cover(url: artwork, size: 52, radius: 8, circle: circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).textStyle(.titleMedium).foregroundStyle(.white).lineLimit(1)
                    Text(subtitle).textStyle(.bodyMedium).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // A hairline under the header and between groups.
                    ForEach(Array(groups().enumerated()), id: \.offset) { _, group in
                        Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5).padding(.vertical, 6)
                        ForEach(group) { action in
                            Button {
                                if let target = action.page {
                                    withAnimation(.fastOutSlowIn(0.2)) { page = target }
                                    return
                                }
                                guard !action.loading else { return }
                                if !action.keepsOpen { dismiss() }
                                action.run()
                            } label: {
                                HStack(spacing: 18) {
                                    Image(systemName: action.icon).font(.system(size: 19)).frame(width: 22)
                                        .foregroundStyle(action.tint ?? .white)
                                    Text(action.title).textStyle(.bodyLarge)
                                        .foregroundStyle(action.id == "delete" ? (action.tint ?? .white) : .white)
                                    Spacer()
                                    if action.loading { ProgressView().controlSize(.small).tint(.white.opacity(0.6)) }
                                }
                                .foregroundStyle(.white)
                                .opacity(action.loading ? 0.5 : 1)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 15)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }
}

// MARK: - The frosted sort menu

/**
 * A release page's track sort (FrostedSortMenu): Date added as one row whose
 * arrow shows the direction and flips it, then the other orders with a tick.
 */
struct FrostedSortMenu: View {
    let browseId: String
    var onDismiss: () -> Void
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let selected = settings.songSort(for: browseId)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // Flipping leaves the menu up, so the turn reads against the list reordering behind it.
                let next: SongSort = selected == .dateAddedDesc ? .dateAddedAsc : .dateAddedDesc
                withAnimation(.fastOutSlowIn(0.2)) { settings.setSongSort(next, for: browseId) }
            } label: {
                HStack(spacing: 16) {
                    Text("Date added").textStyle(.bodyLarge)
                    Spacer(minLength: 0)
                    if selected.isDateAdded {
                        Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.primary)
                            .rotationEffect(.degrees(selected == .dateAddedAsc ? 180 : 0))
                            .animation(.linear(duration: 0.2), value: selected)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach([SongSort.default, .titleAsc, .titleDesc], id: \.self) { option in
                Button {
                    withAnimation(.fastOutSlowIn(0.2)) { settings.setSongSort(option, for: browseId) }
                    onDismiss()
                } label: {
                    HStack(spacing: 16) {
                        Text(option.label).textStyle(.bodyLarge)
                        Spacer(minLength: 0)
                        if option == selected {
                            Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.primary)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(Theme.onSurface)
        .padding(.vertical, 8)
        .frame(width: 264)
        .background { FrostedBackground(shape: RoundedRectangle(cornerRadius: 28, style: .continuous), thin: true) }
    }
}
