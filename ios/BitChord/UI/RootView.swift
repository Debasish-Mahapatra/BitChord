import SwiftUI

/** The phone's root (BitChordApp in MainActivity.kt): tabs, pushed pages, the bottom chrome and the player. */
struct RootView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @Environment(Account.self) private var account
    @Environment(AppSettings.self) private var settings
    @State private var pageActions: PageActions?
    @State private var pageColor: Color?
    /** How far the player sheet sits below fully open, in points; nil while it's down. */
    @State private var sheetOffset: CGFloat?
    @State private var dragOffset: CGFloat = 0
    @State private var renameText = ""

    var body: some View {
        @Bindable var router = router
        @Bindable var account = account
        GeometryReader { geometry in
            let height = geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
            ZStack(alignment: .bottom) {
                Theme.background.ignoresSafeArea()
                content
                    .onPreferenceChange(PageActionsKey.self) { pageActions = $0 }
                    .onPreferenceChange(PageColorKey.self) { pageColor = $0 }
                fades(bottomInset: geometry.safeAreaInsets.bottom)
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                }
                bottomBars
                sortMenuOverlay
                if router.accountPopup {
                    AccountPopup { withAnimation(.linear(duration: 0.15)) { router.accountPopup = false } }
                        .transition(.opacity)
                }
                playerSheet(height: height)
                if let song = router.songInfo {
                    SongInfoCard(song: song) { router.songInfo = nil }
                        .id(song.videoId)
                        .transition(.opacity)
                }
            }
            .onChange(of: router.showPlayer) { _, show in
                let spring = Animation.compose(dampingRatio: 1, stiffness: 195)
                if show {
                    // Placed a full height down first, then sprung up on the next frame.
                    if sheetOffset == nil {
                        sheetOffset = height
                        dragOffset = 0
                    }
                    DispatchQueue.main.async { withAnimation(spring) { sheetOffset = 0 } }
                } else {
                    withAnimation(spring) {
                        sheetOffset = height
                        dragOffset = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if !router.showPlayer { sheetOffset = nil } }
                }
            }
        }
        .statusBarHidden(router.showPlayer && settings.hideStatusBarInPlayer)
        .sheet(item: $router.songMenu) { song in
            ActionSheet(title: song.title, subtitle: song.artist, artwork: song.artwork(rowArtPx),
                        groups: { SongActions(song: song, inPlayer: false, ownPlaylistId: router.songMenuPlaylist).groups },
                        onAppear: {
                            async let likes: Void = Likes.shared.load(song.videoId)
                            await TrackLinks.shared.resolve(song)
                            await likes
                        })
        }
        .sheet(item: $router.browseMenu) { item in
            ActionSheet(title: item.title, subtitle: item.subtitle, artwork: Artwork.url(item.thumbnailUrl, px: rowArtPx),
                        groups: { BrowseActions(item: item, fromCard: false, owned: router.browseMenuOwned,
                                                onRename: { router.renamePlaylist = item },
                                                onDelete: { delete(item) }).groups },
                        onAppear: { router.confirmingDelete = nil })
        }
        .sheet(item: $router.playlistPicker) { song in
            PlaylistPicker(song: song)
        }
        .sheet(isPresented: $router.newPlaylist) { PlaylistPicker(song: nil) }
        .sheet(isPresented: Binding(get: { account.presentSignIn && settings.onboardingComplete },
                                    set: { account.presentSignIn = $0 })) { SignInView() }
        .fullScreenCover(isPresented: Binding(get: { !settings.onboardingComplete }, set: { _ in })) {
            OnboardingView()
                .sheet(isPresented: $account.presentSignIn) { SignInView() }
        }
        .alert("Rename playlist", isPresented: Binding(get: { router.renamePlaylist != nil },
                                                       set: { if !$0 { router.renamePlaylist = nil } })) {
            TextField("Playlist name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename() }
        }
        .onChange(of: router.renamePlaylist?.browseId) { _, _ in renameText = router.renamePlaylist?.title ?? "" }
    }

    private func rename() {
        guard let item = router.renamePlaylist else { return }
        let title = renameText.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        Task {
            do {
                try await Innertube.shared.renamePlaylist(item.browseId, title: title)
                router.playlistDidChange()
            } catch {
                player.showNotice(error.localizedDescription)
            }
        }
    }

    private func delete(_ item: BrowseItem) {
        router.confirmingDelete = nil
        Task {
            do {
                try await Innertube.shared.deletePlaylist(item.browseId)
                if case .browse(let open) = router.top, open.browseId == item.browseId { router.back() }
                router.playlistDidChange()
                player.showNotice("Deleted “\(item.title)”")
            } catch {
                player.showNotice(error.localizedDescription)
            }
        }
    }

    // MARK: Content

    /** The tab's root, or the page on top of it; pages cross-fade over 180 ms. */
    @ViewBuilder
    private var content: some View {
        ZStack {
            switch router.top {
            case nil:
                tabRoot.transition(.opacity)
            case .browse(let item):
                Group {
                    if item.type == .artist { ArtistView(item: item) } else { CollectionView(item: item) }
                }
                .id(item.browseId)
                .transition(.opacity)
            case .mood(let mood):
                MoodPageView(mood: mood).id(mood.id)
            case .history:
                HistoryView().transition(.opacity)
            case .moods:
                MoodGridPage().transition(.opacity)
            case .showAll(let title, let items, let library):
                ShowAllView(title: title, items: items, library: library).transition(.opacity)
            case .settings:
                SettingsView().transition(.opacity)
            case .account:
                AccountPage().transition(.opacity)
            case .sources:
                SourcesView().transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var tabRoot: some View {
        // Each tab keeps its own scroll position.
        ZStack {
            HomeView().opacity(router.tab == .home ? 1 : 0).allowsHitTesting(router.tab == .home)
            ExploreView().opacity(router.tab == .explore ? 1 : 0).allowsHitTesting(router.tab == .explore)
            LibraryView().opacity(router.tab == .library ? 1 : 0).allowsHitTesting(router.tab == .library)
            SearchView().opacity(router.tab == .search ? 1 : 0).allowsHitTesting(router.tab == .search)
        }
    }

    // MARK: Top bar

    /** No fill and no title: a back circle on pushed pages, and one glass pill of actions. */
    private var topBar: some View {
        HStack(spacing: 0) {
            if !router.stack.isEmpty {
                Button { router.back() } label: {
                    Image(systemName: "arrow.left").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.onSurface)
                        .frame(width: 44, height: 44)
                        .background { FrostedBackground(shape: Circle()) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            Spacer()
            actionsPill
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.topBarHeight)
    }

    private var actionsPill: some View {
        let actions = router.stack.isEmpty ? rootActions : (pageActions?.items ?? [])
        let sortsLibrary = isLibraryShowAll
        return HStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, item in
                Button(action: item.action) {
                    Image(systemName: item.icon).font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.onSurface)
                        .frame(width: 44, height: 48)
                }
                .buttonStyle(.plain)
            }
            if sortsLibrary { librarySortMenu }
            // None on Settings or the pages opened from it: the photo would only reopen them.
            if router.stack.isEmpty || !(isReleasePage || isSettingsPage) { avatar }
        }
        .padding(.horizontal, actions.isEmpty && !sortsLibrary ? 0 : 6)
        .background { FrostedBackground(shape: Capsule()) }
        .animation(.compose(dampingRatio: 1, stiffness: 400), value: actions.count)
    }

    /** Left of the account photo, and only on Library itself: History. */
    private var rootActions: [PageActions.Item] {
        guard router.tab == .library else { return [] }
        return [.init(icon: "clock.arrow.circlepath") { router.push(.history) }]
    }

    private var isSettingsPage: Bool {
        router.stack.contains { $0 == .settings || $0 == .account || $0 == .sources }
    }

    private var isLibraryShowAll: Bool {
        if case .showAll(_, _, true) = router.top { return true }
        return false
    }

    /** A Library "Show all" grid's order: the shelf's own, or by title. */
    private var librarySortMenu: some View {
        Menu {
            Picker("Sort", selection: Binding(get: { settings.librarySort }, set: { settings.setLibrarySort($0) })) {
                ForEach(LibrarySort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.onSurface)
                .frame(width: 44, height: 48)
        }
        .accessibilityLabel("Sort")
    }

    /** A release page's sort menu over a scrim that dismisses it. */
    @ViewBuilder
    private var sortMenuOverlay: some View {
        if let browseId = router.sortMenu {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.48).ignoresSafeArea()
                    .onTapGesture { router.sortMenu = nil }
                FrostedSortMenu(browseId: browseId) { router.sortMenu = nil }
                    .padding(.top, Metrics.topBarHeight + 4)
                    .padding(.trailing, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .transition(.opacity)
        }
    }

    private var isReleasePage: Bool {
        if case .browse(let item) = router.top { return item.type != .artist }
        return false
    }

    /** The account photo: signed in, the account switcher; signed out, Settings. */
    private var avatar: some View {
        Button {
            if account.isSignedIn {
                withAnimation(.linear(duration: 0.15)) { router.accountPopup = true }
            } else if router.top != .settings {
                router.push(.settings)
            }
        } label: {
            ZStack {
                Circle().fill(Theme.surfaceVariant)
                if let photo = account.photo {
                    RemoteImage(url: URL(string: photo)).clipShape(Circle())
                } else {
                    Image(systemName: "person.fill").font(.system(size: 15)).foregroundStyle(Theme.onSurfaceVariant)
                }
            }
            .frame(width: 28, height: 28)
            .overlay(Circle().stroke(Theme.thumbnailBorder, lineWidth: 1))
            .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account")
    }

    // MARK: Fades

    /** The page colour fading in at the top (under the bar) and the bottom (under the bars), EaseInCubic. */
    private func fades(bottomInset: CGFloat) -> some View {
        // A plain colour: dynamic (trait-resolved) colours drop out of gradient stops. The app is dark.
        let color = pageColor ?? Color.black
        let stops = (0...15).map { i -> Gradient.Stop in
            let t = Double(i) / 15
            return .init(color: color.opacity(easeInCubic(t)), location: t)
        }
        // Fully the page colour at the screen's very top and bottom edges.
        return VStack(spacing: 0) {
            // The bottom fade turned over: it takes the bottom inset's height too.
            LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top)
                .frame(height: max(bottomInset, 15) + 180)
            Spacer()
            LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
                .frame(height: max(bottomInset, 15) + (player.song == nil ? 180 : 254))
                .animation(.easeInOut(duration: 0.22), value: player.song == nil)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func easeInCubic(_ t: Double) -> Double {
        // cubic-bezier(0.32, 0, 0.67, 0), sampled by solving for x.
        var lo = 0.0, hi = 1.0
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            let x = 3 * (1 - mid) * (1 - mid) * mid * 0.32 + 3 * (1 - mid) * mid * mid * 0.67 + mid * mid * mid
            if x < t { lo = mid } else { hi = mid }
        }
        let s = (lo + hi) / 2
        return s * s * s
    }

    // MARK: Bottom chrome

    private var bottomBars: some View {
        VStack(spacing: 8) {
            if let notice = player.notice {
                Text(notice).textStyle(.bodyLarge).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .background(Color(hex: 0x282828), in: RoundedRectangle(cornerRadius: 5))
                    .shadow(color: .black.opacity(0.3), radius: 4)
                    .padding(.horizontal, Metrics.gutter)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if player.song != nil {
                MiniPlayer(dragOffset: $dragOffset)
            }
            FloatingTabBar()
        }
        .frame(maxWidth: 440)
        .padding(.bottom, 2)
        .ignoresSafeArea(.keyboard)
        .animation(.spring(duration: 0.3), value: player.notice)
    }

    // MARK: Player sheet

    @ViewBuilder
    private func playerSheet(height: CGFloat) -> some View {
        if let offset = sheetOffset, player.song != nil {
            let open = 1 - min(1, max(0, (offset + dragOffset) / height))
            ZStack(alignment: .top) {
                Color.black.opacity(0.32 * open).ignoresSafeArea()
                    .onTapGesture { router.showPlayer = false }
                NowPlayingView(dragOffset: $dragOffset, height: height)
                    .offset(y: offset + dragOffset)
            }
            // Top-aligned in the whole screen: centred, the full-height player sat half the top inset low.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
        }
    }
}

// MARK: - Mini player

/** The frosted capsule above the tabs: cover, title, play/pause and next. */
struct MiniPlayer: View {
    @Binding var dragOffset: CGFloat
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @State private var swipe: CGFloat = 0

    var body: some View {
        if let song = player.song {
            HStack(spacing: 0) {
                Cover(url: song.artwork(rowArtPx), size: 40, radius: 8)
                VStack(alignment: .leading, spacing: 0) {
                    SongTitle(text: song.title, explicit: song.isExplicit)
                    Text(song.artist).textStyle(.bodyMedium).foregroundStyle(Theme.onSurfaceVariant).lineLimit(1)
                }
                .padding(.leading, 10)
                .offset(x: swipe * 0.35)
                Spacer(minLength: 8)
                Button { player.togglePlay() } label: {
                    ZStack {
                        if player.isBuffering && player.isPlaying {
                            ProgressView().controlSize(.small).tint(Theme.onBackground)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 24))
                        }
                    }
                    .foregroundStyle(Theme.onBackground)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 20)).scaleEffect(y: 0.85)
                        .foregroundStyle(Theme.onBackground.opacity(player.hasNext ? 1 : 0.3))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                .accessibilityLabel("Next")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background { FrostedBackground(shape: Capsule(), thin: true) }
            .padding(.horizontal, Metrics.gutter)
            .contentShape(Capsule())
            .onTapGesture { router.showPlayer = true }
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        if abs(value.translation.width) > abs(value.translation.height) { swipe = value.translation.width }
                    }
                    .onEnded { value in
                        let dx = value.translation.width, dy = value.translation.height
                        if abs(dx) >= 72, abs(dx) > abs(dy) {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if dx < 0 { player.next() } else { player.previous() }
                        } else if dy < -30, abs(dx) < abs(dy) * 1.5 {
                            router.showPlayer = true
                        }
                        withAnimation(.compose(dampingRatio: 0.65, stiffness: 400)) { swipe = 0 }
                    }
            )
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
        }
    }
}

// MARK: - Tab bar

/** FloatingBottomBar: a frosted capsule of four tabs and a sliding selection pill. */
struct FloatingTabBar: View {
    @Environment(Router.self) private var router
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Router.Tab.allCases) { tab in
                let selected = router.tab == tab
                VStack(spacing: 2) {
                    Image(systemName: tab.icon).font(.system(size: 21, weight: .semibold))
                        .frame(height: 25)
                        .scaleEffect(selected ? 1.08 : 1)
                    Text(tab.title).textStyle(.labelSmall).lineLimit(1)
                }
                .foregroundStyle(selected ? Theme.primary : Theme.onSurfaceVariant)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background {
                    if selected {
                        Capsule().fill(Theme.primary.opacity(0.14)).matchedGeometryEffect(id: "pill", in: indicator)
                    }
                }
                .contentShape(Capsule())
                .onTapGesture {
                    if !selected { UISelectionFeedbackGenerator().selectionChanged() }
                    withAnimation(.compose(dampingRatio: 0.72, stiffness: 320)) { router.select(tab) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(6)
        .background { FrostedBackground(shape: Capsule()) }
        .padding(.horizontal, Metrics.gutter)
        .animation(.linear(duration: 0.2), value: router.tab)
    }
}
