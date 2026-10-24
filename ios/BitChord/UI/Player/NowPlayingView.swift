import AVKit
import SwiftUI

/** Which screen the player shows; remembered for the next time it opens. */
enum PlayerMode: String {
    case main, lyrics, queue
}

/**
 * The full-screen player (NowPlayingScreen.kt), portrait: a grabber strip,
 * the art box (the cover as a full-bleed banner, the title row under it), and
 * the deck — lyric strip, scrubber, transport, volume, and the bottom row.
 */
struct NowPlayingView: View {
    @Binding var dragOffset: CGFloat
    let height: CGFloat

    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @Environment(Account.self) private var account
    @Environment(LyricsModel.self) private var lyrics
    @AppStorage("player.mode") private var storedMode = PlayerMode.main.rawValue
    @State private var mode: PlayerMode = .main
    @State private var palette: ArtworkPalette = .neutral
    @State private var swipe: CGFloat = 0
    @State private var browsingLyrics = false
    @State private var deckHidden = false
    @State private var idleTask: Task<Void, Never>?
    @State private var showMenu = false
    @State private var showProviders = false
    @State private var showOffset = false
    @State private var showTimer = false
    @Namespace private var namespace

    private var tint: Color { palette.tint }
    private var panelOpen: Bool { mode != .main }

    var body: some View {
        GeometryReader { geometry in
            let insets = Self.safeInsets
            let width = geometry.size.width
            let layout = Layout(width: width, height: geometry.size.height, top: insets.top, bottom: insets.bottom)
            ZStack(alignment: .top) {
                PlayerBackdrop(song: player.song, seam: layout.heroHeight, panelOpen: panelOpen)
                if mode == .main { banner(layout) }
                topScrim(layout)
                VStack(spacing: 0) {
                    handleStrip
                    ZStack(alignment: .topLeading) {
                        if mode == .main {
                            titleRow(layout)
                                .padding(.top, layout.groupTop + layout.fullArt + 20)
                        } else {
                            collapsedHeader
                            panel
                                .padding(.top, 60)
                                .padding(.horizontal, mode == .lyrics ? -30 : -30)
                                .transition(.opacity.animation(.fastOutSlowIn(0.2).delay(0.2)))
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 8)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .contentShape(Rectangle())
                    .gesture(mode == .main ? artGestures : nil)
                    if !(mode == .lyrics && deckHidden) {
                        deck(layout)
                            .padding(.horizontal, 30)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.top, insets.top)
                .padding(.bottom, insets.bottom)
            }
            .frame(width: width, height: geometry.size.height)
        }
        // The insets are applied by hand above; laid out inside them, the full-height frame sat centred and low.
        .ignoresSafeArea()
        .frame(height: height)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: dragOffset > 0 ? 40 : 0, style: .continuous))
        .environment(\.colorScheme, .dark)
        .onAppear { mode = PlayerMode(rawValue: storedMode) ?? .main }
        .task(id: player.song?.thumbnailUrl) { await loadPalette() }
        .task(id: player.song?.videoId) {
            lyrics.load(for: player.song, duration: player.duration)
            if let id = player.song?.videoId { await Likes.shared.load(id) }
        }
        .onChange(of: player.durationSeconds) { _, duration in lyrics.load(for: player.song, duration: duration) }
        .sheet(isPresented: $showMenu) { menuSheet }
        .sheet(isPresented: $showProviders) { LyricsProviderSheet() }
        .sheet(isPresented: $showOffset) { LyricsOffsetSheet() }
        .sheet(isPresented: $showTimer) { SleepTimerSheet() }
    }

    // MARK: Geometry

    /** The art box's sums (ART_TITLE_GAP 20, HEADER_HEIGHT 60), with the deck's natural height taken out. */
    struct Layout {
        let width: CGFloat
        let fullArt: CGFloat
        let groupTop: CGFloat
        let spread: CGFloat
        let heroHeight: CGFloat

        init(width: CGFloat, height: CGFloat, top: CGFloat, bottom: CGFloat) {
            self.width = width
            let deckBase: CGFloat = 30 + 41 + 8 + 92 + 12 + 32 + 6 + 44 + 18 + 20 + 18
            let available = height - top - bottom - 32 - deckBase - 8 - 18
            let maxW = width - 60
            let art0 = max(54, min(min(maxW, available - 80), available - 80))
            let slack = max(0, available - art0 - 80)
            spread = (min(slack, 48) / 2).rounded(.down) * 2
            let maxH = available - spread
            fullArt = max(54, min(min(maxW, maxH + spread - 80), maxH - 80 + spread))
            groupTop = max(0, (maxH - fullArt - 80) / 2)
            heroHeight = top + 32 + 8 + groupTop + fullArt + 10
        }
    }

    static var safeInsets: UIEdgeInsets {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets ?? .zero
    }

    // MARK: Artwork

    /** The full-bleed banner: the cover across the top, its bottom 42% dissolving into the mesh. */
    private func banner(_ layout: Layout) -> some View {
        RemoteImage(url: player.song?.artwork(playerArtPx))
            .matchedGeometryEffect(id: "art", in: namespace)
            .frame(width: layout.width, height: layout.heroHeight)
            .clipped()
            .mask {
                // Smoothstep over the bottom 42%: a linear fade has a visible corner where it starts and ends.
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.58),
                                       .init(color: .black.opacity(0.844), location: 0.685), .init(color: .black.opacity(0.5), location: 0.79),
                                       .init(color: .black.opacity(0.156), location: 0.895), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .offset(x: swipe * 0.35)
            .overlay(alignment: .bottom) { skipHint(layout) }
            // Pinned to the screen's top edge: a fixed-height view would otherwise sit centred in the inset it grows into.
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    private func skipHint(_ layout: Layout) -> some View {
        let fraction = min(1, abs(swipe) / 72)
        let available = swipe < 0 ? player.hasNext : (player.hasPrevious || player.position > 10)
        return Image(systemName: swipe < 0 ? "forward.fill" : "backward.fill")
            .font(.system(size: 16))
            .foregroundStyle(.white)
            .opacity(fraction * (available ? 0.85 : 0.3))
            .offset(y: 2 + 20)
    }

    /** Dark at the top, so the status bar reads over a bright cover. */
    private func topScrim(_ layout: Layout) -> some View {
        let strength = panelOpen ? 0.40 : 0.30
        return LinearGradient(stops: (0...7).map { i in
            .init(color: .black.opacity(strength * pow(1 - Double(i) / 7, 1.5)), location: Double(i) / 7)
        }, startPoint: .top, endPoint: .bottom)
        .frame(height: Self.safeInsets.top + 32)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Strip and title

    /** The grabber and "Playing from …". */
    private var handleStrip: some View {
        ZStack(alignment: .top) {
            Capsule().fill(tint.opacity(0.70)).frame(width: 38, height: 5)
                .shadow(color: .black.opacity(0.3), radius: 2)
                .padding(.top, mode == .main ? 6 : 13.5)
            if mode == .main, !AppSettings.shared.hideSongStatus, let caption = player.sourceCaption {
                Text(caption).textStyle(.labelSmall).foregroundStyle(tint)
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                    .lineLimit(1)
                    .padding(.horizontal, 30)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 1)
                    .onTapGesture { openSource() }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .contentShape(Rectangle())
        .gesture(dismissDrag)
        .onTapGesture { router.showPlayer = false }
    }

    private func titleRow(_ layout: Layout) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if player.song?.isExplicit == true { ExplicitBadge(color: .white, height: 18) }
                    MarqueeText(text: player.song?.title ?? "", font: .sfDisplay(20, .bold), tracking: -0.3, color: .white)
                }
                .matchedGeometryEffect(id: "title", in: namespace)
                .onTapGesture { openAlbum() }
                MarqueeText(text: player.song?.artist ?? "", font: .sfDisplay(20, .medium), tracking: -0.3, color: tint.opacity(0.55), delay: 3)
                    .matchedGeometryEffect(id: "artist", in: namespace)
                    .onTapGesture { openArtist() }
            }
            Spacer(minLength: 10)
            circles
        }
        .frame(height: 60)
    }

    @ViewBuilder
    private var circles: some View {
        HStack(spacing: 8) {
            if account.isSignedIn, let song = player.song {
                let isLiked = Likes.shared.isLiked(song.videoId)
                // Favourite with a star, as the phone has since 1.8.1.
                glyph(isLiked ? "star.fill" : "star", active: isLiked) { Likes.shared.toggleLike(song) }
            }
            glyph("ellipsis", active: false) { showMenu = true }
        }
        .matchedGeometryEffect(id: "circles", in: namespace)
    }

    private func glyph(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(active ? 0.34 : 0.18), in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }

    /** Lyrics and queue: the cover as a 54pt thumbnail, the credits beside it at 80%. */
    private var collapsedHeader: some View {
        HStack(spacing: 12) {
            RemoteImage(url: player.song?.artwork(cardArtPx))
                .matchedGeometryEffect(id: "art", in: namespace)
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .onTapGesture { setMode(.main) }
            VStack(alignment: .leading, spacing: 0) {
                Text(player.song?.title ?? "").font(.sfDisplay(16, .bold)).tracking(-0.3).foregroundStyle(.white).lineLimit(1)
                    .matchedGeometryEffect(id: "title", in: namespace)
                Text(player.song?.artist ?? "").font(.sfDisplay(16, .medium)).foregroundStyle(tint.opacity(0.55)).lineLimit(1)
                    .matchedGeometryEffect(id: "artist", in: namespace)
            }
            Spacer(minLength: 8)
            circles
        }
        .frame(height: 60, alignment: .top)
        .contentShape(Rectangle())
        .gesture(dismissDrag)
    }

    @ViewBuilder
    private var panel: some View {
        if mode == .lyrics {
            LyricsPanel(lyrics: lyrics.lyrics, loading: lyrics.loading, tint: tint, browsing: $browsingLyrics)
                .overlay(alignment: .bottom) {
                    // With the controls tucked away, the lower half's tap brings them back instead of seeking.
                    if deckHidden {
                        GeometryReader { g in
                            Color.clear.contentShape(Rectangle())
                                .frame(height: g.size.height / 2)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                                .onTapGesture { showDeck() }
                        }
                    }
                }
        } else {
            QueuePanel()
        }
    }

    // MARK: Deck

    private func deck(_ layout: Layout) -> some View {
        VStack(spacing: 0) {
            if mode == .lyrics, let source = lyrics.lyrics?.source {
                Button { showProviders = true } label: {
                    Text("Lyrics by \(source.label)").textStyle(.titleMedium).underline().foregroundStyle(tint.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .frame(height: 30)
            } else {
                LyricStrip(tint: tint) { setMode(.lyrics) }
            }
            scrubber
            Spacer().frame(height: 8 + layout.spread / 2)
            transport
            Spacer().frame(height: 12 + layout.spread / 2)
            if !AppSettings.shared.hideVolumeBar {
                VolumeSlider(tint: tint)
                Spacer().frame(height: 6)
            }
            bottomRow
            Spacer().frame(height: 18)
            Text(AudioOutput.shared.label(accountName: account.name)).textStyle(.labelSmall).foregroundStyle(tint.opacity(0.55)).lineLimit(1)
                .frame(height: 20)
            Spacer().frame(height: 18)
        }
    }

    private var scrubber: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let duration = player.duration
            let position = min(player.position, duration)
            VStack(spacing: 0) {
                ThinSlider(value: duration > 0 ? position / duration : 0) { fraction in
                    player.seek(to: fraction * duration)
                }
                HStack {
                    Text(Self.time(position)).monospacedDigit()
                    Spacer()
                    HStack(spacing: 4) {
                        if AppSettings.shared.showNerdStats, let stats = player.streamDescription {
                            Text(stats).font(.sfDisplay(12.5, .medium)).lineLimit(1)
                        } else {
                            // Static, never pulsing: "Upgrading quality" is a word, not a light.
                            Image(systemName: player.playingSubstitute?.format.isLossless == true ? "waveform" : "headphones").font(.system(size: 11))
                            Text(player.qualityLabel).font(.sfDisplay(12.5, .medium))
                        }
                    }
                    .foregroundStyle(tint.opacity(0.45))
                    Spacer()
                    Text("-" + Self.time(max(0, duration - position))).monospacedDigit()
                }
                .textStyle(.labelMedium)
                .foregroundStyle(tint.opacity(0.55))
                .padding(.top, -9)
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var transport: some View {
        HStack {
            Spacer()
            Button { haptic(); player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 40)).scaleEffect(y: 0.85).frame(width: 53, height: 53)
            }
            .disabled(!(player.hasPrevious || player.position > 10))
            Spacer()
            Button { haptic(); player.togglePlay() } label: {
                ZStack {
                    if player.isBuffering && player.isPlaying {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 58))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 92, height: 92)
            }
            Spacer()
            Button { haptic(); player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 40)).scaleEffect(y: 0.85).frame(width: 53, height: 53)
            }
            .disabled(!player.hasNext)
            Spacer()
        }
        .buttonStyle(TransportStyle())
        .foregroundStyle(.white)
    }

    /** Lyrics, the output capsule (Shuffle | Repeat | AutoPlay in queue mode), Queue. */
    private var bottomRow: some View {
        HStack(spacing: 0) {
            roundGlyph("quote.bubble", lit: mode == .lyrics) { setMode(mode == .lyrics ? .main : .lyrics) }
                .opacity(mode == .queue ? 0 : 1)
            Spacer()
            capsule
            Spacer()
            roundGlyph("list.bullet", lit: mode == .queue) { setMode(mode == .queue ? .main : .queue) }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func roundGlyph(_ icon: String, lit: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint.opacity(lit ? 1 : 0.75))
                .frame(width: 44, height: 44)
                .background(tint.opacity(lit ? 0.20 : 0), in: Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var capsule: some View {
        HStack(spacing: 0) {
            if mode == .queue {
                segment(lit: player.shuffle) {
                    Image(systemName: "shuffle").font(.system(size: 18, weight: .semibold))
                } action: { player.shuffle.toggle() }
                divider
                segment(lit: player.repeatMode != .off) {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.system(size: 18, weight: .semibold))
                } action: { player.repeatMode = player.repeatMode.next }
                divider
                segment(lit: player.autoplay) {
                    Image(systemName: "infinity").font(.system(size: 19, weight: .semibold))
                } action: { player.autoplay.toggle() }
            } else {
                // The picker's own AirPlay glyph is hidden; the device the sound leaves by is drawn over it.
                RoutePicker(tint: .clear)
                    .frame(width: 64, height: 44)
                    .overlay {
                        Image(systemName: AudioOutput.shared.glyph).font(.system(size: 19, weight: .semibold))
                            .contentTransition(.opacity)
                            .animation(.fastOutSlowIn(0.2), value: AudioOutput.shared.glyph)
                            .allowsHitTesting(false)
                    }
            }
        }
        .foregroundStyle(tint)
        .frame(height: 44)
        .background(tint.opacity(0.12), in: Capsule())
        .animation(.compose(dampingRatio: 0.82, stiffness: 400), value: mode)
    }

    private var divider: some View {
        Rectangle().fill(tint.opacity(0.20)).frame(width: 1, height: 22)
    }

    private func segment<Label: View>(lit: Bool, @ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .opacity(lit ? 1 : 0.55)
                .frame(width: 64, height: 44)
                .background(lit ? tint.opacity(0.14) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Gestures

    /** Down closes the player. */
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in dragOffset = max(0, value.translation.height) }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 320 {
                    router.showPlayer = false
                } else {
                    withAnimation(.compose(dampingRatio: 1, stiffness: 195)) { dragOffset = 0 }
                }
            }
    }

    /** Over the artwork: sideways skips (the cover follows at 35%), down closes. */
    private var artGestures: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if abs(value.translation.width) > abs(value.translation.height) {
                    withAnimation(.compose(dampingRatio: 1, stiffness: 400)) { swipe = value.translation.width }
                } else if value.translation.height > 0 {
                    dragOffset = value.translation.height
                }
            }
            .onEnded { value in
                if abs(swipe) >= 72 {
                    haptic()
                    if swipe < 0 { player.next() } else { player.previous() }
                } else if dragOffset > 0 {
                    if value.translation.height > 120 || value.predictedEndTranslation.height > 320 {
                        router.showPlayer = false
                    } else {
                        withAnimation(.compose(dampingRatio: 1, stiffness: 195)) { dragOffset = 0 }
                    }
                }
                withAnimation(.compose(dampingRatio: 1, stiffness: 400)) { swipe = 0 }
            }
    }

    // MARK: Actions

    private func setMode(_ new: PlayerMode) {
        withAnimation(.fastOutSlowIn(0.42)) {
            mode = new
            deckHidden = false
        }
        storedMode = new.rawValue
        scheduleDeckHide()
    }

    /** In lyrics, the deck tucks away after five idle seconds; a tap brings it back. */
    private func scheduleDeckHide() {
        idleTask?.cancel()
        guard mode == .lyrics else { return }
        idleTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, mode == .lyrics else { return }
            withAnimation(.fastOutSlowIn(0.42)) { deckHidden = true }
        }
    }

    private func showDeck() {
        guard deckHidden else { return }
        withAnimation(.fastOutSlowIn(0.42)) { deckHidden = false }
        scheduleDeckHide()
    }

    private func haptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func openAlbum() {
        guard let song = player.song, let id = song.albumId else { return }
        router.openFromPlayer { router.openAlbum(id: id, title: song.albumName) }
    }

    private func openArtist() {
        guard let song = player.song, let id = song.artistId ?? song.artists.first?.browseId else { return }
        router.openFromPlayer { router.openArtist(id: id, name: song.artist) }
    }

    private func openSource() {
        guard let source = player.current?.source else { return }
        switch source.kind {
        case .queue: setMode(.queue)
        case .album, .playlist, .artist:
            guard let id = source.id else { return }
            let type: BrowseType = source.kind == .album ? .album : source.kind == .artist ? .artist : .playlist
            router.openFromPlayer { router.open(BrowseItem(browseId: id, title: source.title, subtitle: "", thumbnailUrl: nil, type: type)) }
        default: break
        }
    }

    private func loadPalette() async {
        guard let url = player.song?.artwork(cardArtPx) else { return }
        if let cached = PaletteCache.shared.cached(url) {
            withAnimation(.fastOutSlowIn(0.36)) { palette = cached }
            return
        }
        if let loaded = await PaletteCache.shared.palette(url) {
            withAnimation(.fastOutSlowIn(0.36)) { palette = loaded }
        }
    }

    private var menuSheet: some View {
        let song = player.song ?? Song(videoId: "", title: "", artist: "")
        return ActionSheet(title: song.title, subtitle: song.artist, artwork: song.artwork(rowArtPx), groups: {
            var groups = SongActions(song: song, inPlayer: true).groups
            // From the player only, after Song Info and before Share.
            if var rest = groups.popLast() {
                let at = rest.firstIndex { $0.id == "share" } ?? rest.endIndex
                rest.insert(contentsOf: [
                    .init(id: "timer", title: SleepTimer.shared.label ?? "Sleep timer", icon: "moon.zzz") { showTimer = true },
                    .init(id: "offset", title: "Lyrics offset", icon: "slider.horizontal.3") { showOffset = true },
                ], at: at)
                groups.append(rest)
            }
            return groups
        }, onAppear: { await TrackLinks.shared.resolve(song) })
    }
}

/** Transport glyphs: no ripple, a faint dip under the finger, 30% when disabled. */
private struct TransportStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.3)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/** AirPlay and Bluetooth output, where the phone has its output drawer. */
private struct RoutePicker: UIViewRepresentable {
    let tint: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = tint
        view.activeTintColor = tint
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        view.activeTintColor = tint
    }
}

/**
 * A single line that scrolls when it doesn't fit: 26pt/s, leftward, the text
 * drawn twice 48pt apart, resting five seconds between passes.
 */
struct MarqueeText: View {
    let text: String
    let font: Font
    var tracking: CGFloat = 0
    let color: Color
    var delay: Double = 0

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var runner: Task<Void, Never>?

    var body: some View {
        let label = Text(text).font(font).tracking(tracking).foregroundStyle(color).lineLimit(1).fixedSize()
        ZStack(alignment: .leading) {
            HStack(spacing: 48) {
                label.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                if textWidth > boxWidth { label }
            }
            .offset(x: offset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
        .onChange(of: text) { _, _ in restart() }
        .onChange(of: textWidth > boxWidth) { _, _ in restart() }
        .onAppear { restart() }
        .onDisappear { runner?.cancel() }
    }

    private func restart() {
        runner?.cancel()
        offset = 0
        guard textWidth > boxWidth, boxWidth > 0 else { return }
        let distance = textWidth + 48
        let duration = max(0.4, Double(distance / 26))
        runner = Task {
            try? await Task.sleep(nanoseconds: UInt64((5 + delay) * 1_000_000_000))
            while !Task.isCancelled {
                withAnimation(.linear(duration: duration)) { offset = -distance }
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                offset = 0
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
}

// MARK: - Sleep timer and lyrics offset

@MainActor
@Observable
final class SleepTimer {
    static let shared = SleepTimer()

    private(set) var endsAt: Date?
    private(set) var afterThisSong = false
    private var task: Task<Void, Never>?

    var label: String? {
        if afterThisSong { return "Sleep timer · End of song" }
        guard let endsAt else { return nil }
        let minutes = max(1, Int(endsAt.timeIntervalSinceNow / 60 + 0.5))
        return "Sleep timer · \(minutes) min"
    }

    func start(minutes: Int) {
        cancel()
        endsAt = Date().addingTimeInterval(Double(minutes) * 60)
        task = Task {
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            guard !Task.isCancelled else { return }
            PlayerModel.shared.pause()
            endsAt = nil
        }
    }

    /** Pauses when the current track ends. */
    func startAfterThisSong() {
        cancel()
        afterThisSong = true
        let id = PlayerModel.shared.current?.id
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let player = PlayerModel.shared
                if player.current?.id != id || player.duration - player.position < 0.4 {
                    player.pause()
                    afterThisSong = false
                    return
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        endsAt = nil
        afterThisSong = false
    }
}

struct SleepTimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let timer = SleepTimer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sleep timer").font(.sfDisplay(19, .bold)).foregroundStyle(.white).padding(.bottom, 10)
            option("After this song") { timer.startAfterThisSong() }
            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                option("\(minutes) minutes") { timer.start(minutes: minutes) }
            }
            if timer.label != nil { option("Turn off timer") { timer.cancel() } }
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationCornerRadius(26)
        .presentationBackground(Color(hex: 0x121212))
        .environment(\.colorScheme, .dark)
    }

    private func option(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            Text(title).textStyle(.bodyLarge).foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/** "Lyrics offset": ±5 s in 100 ms steps; positive shows lyrics later. */
struct LyricsOffsetSheet: View {
    @Environment(LyricsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lyrics offset").font(.sfDisplay(19, .bold)).foregroundStyle(.white)
                Text("Positive values show lyrics later").font(.sfDisplay(14)).foregroundStyle(.white.opacity(0.55))
            }
            VStack(spacing: 10) {
                Text(String(format: "%+.1f s", Double(model.offsetMs) / 1000)).font(.sfDisplay(22, .semibold)).foregroundStyle(.white)
                HStack(spacing: 12) {
                    step("minus", -100)
                    ThinSlider(value: Double(model.offsetMs + 5000) / 10000, idleHeight: 6, activeHeight: 10,
                               onChanged: { set($0) }, onCommit: { set($0) })
                    step("plus", 100)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Button("Reset") {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                model.offsetMs = 0
            }
            .font(.sfDisplay(16, .semibold))
            .foregroundStyle(.white.opacity(model.offsetMs == 0 ? 0.35 : 0.8))
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(.white.opacity(0.08), in: Capsule())
            .disabled(model.offsetMs == 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .presentationDetents([.height(300)])
        .presentationCornerRadius(26)
        .presentationBackground(Color(hex: 0x121212))
        .environment(\.colorScheme, .dark)
    }

    private func set(_ fraction: Double) {
        model.offsetMs = Int((fraction * 10000 - 5000) / 100) * 100
    }

    private func step(_ icon: String, _ delta: Int) -> some View {
        let next = model.offsetMs + delta
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            model.offsetMs = min(5000, max(-5000, next))
        } label: {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .opacity(abs(next) > 5000 ? 0.25 : 0.85)
        .disabled(abs(next) > 5000)
    }
}
