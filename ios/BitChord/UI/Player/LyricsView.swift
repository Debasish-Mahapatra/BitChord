import SwiftUI

/** LYRIC_EASING, cubic-bezier(0.41, 0, 0.12, 0.99). */
extension Animation {
    static func lyric(_ seconds: Double) -> Animation { .timingCurve(0.41, 0, 0.12, 0.99, duration: seconds) }
}

/** Which characters a run of text covers, so the renderer knows how much of it is sung. */
private struct CharSpan: TextAttribute {
    let start: Double
    let length: Double
}

/**
 * The word fill: every glyph sits at the unsung alpha until the sung edge
 * reaches it, then rises once to full — a left-to-right fill at the singing
 * speed, with no light of its own.
 */
private struct FillRenderer: TextRenderer, Animatable {
    var revealed: Double
    var unsung: Double

    var animatableData: Double {
        get { revealed }
        set { revealed = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let span = run[CharSpan.self] else {
                    context.draw(run)
                    continue
                }
                let count = Double(run.count)
                for (index, slice) in run.enumerated() {
                    let charAt = span.start + Double(index) / max(1, count) * span.length
                    let lit = min(1, max(0, revealed - charAt))
                    var copy = context
                    copy.opacity = unsung + (1 - unsung) * lit
                    copy.draw(slice)
                }
            }
        }
    }
}

/** A line's text as runs tagged with the characters they cover. */
private func spannedText(_ text: String) -> Text {
    // One run per word and per gap: enough for the renderer to map glyphs back to characters.
    var result = Text("")
    var start = 0
    var current = ""
    var inSpace: Bool?
    func flush() {
        guard !current.isEmpty else { return }
        result = result + Text(current).customAttribute(CharSpan(start: Double(start), length: Double(current.count)))
        start += current.count
        current = ""
    }
    for character in text {
        let space = character.isWhitespace
        if let inSpace, inSpace != space { flush() }
        inSpace = space
        current.append(character)
    }
    flush()
    return result
}

/** The full lyrics panel (LyricsPanel). */
struct LyricsPanel: View {
    let lyrics: Lyrics?
    let loading: Bool
    let tint: Color
    @Binding var browsing: Bool

    @Environment(PlayerModel.self) private var player
    @Environment(LyricsModel.self) private var model
    @State private var focus = 0
    @State private var resumeTask: Task<Void, Never>?
    @State private var visible: Set<Int> = []

    var body: some View {
        GeometryReader { geometry in
            if let lyrics, !lyrics.lines.isEmpty {
                if lyrics.isSynced {
                    synced(lyrics, viewport: geometry.size.height)
                } else {
                    unsynced(lyrics)
                }
            } else if loading {
                skeleton
            } else {
                Text("No lyrics for this track").textStyle(.titleMedium).foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .mask {
            // 28pt fades at the top and bottom of the list.
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 28)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
            }
        }
    }

    // MARK: Synced

    private func synced(_ lyrics: Lyrics, viewport: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                TimelineView(.animation(paused: !player.isPlaying)) { timeline in
                    let ms = Int(player.position * 1000) - model.offsetMs
                    let active = activeRows(lyrics.lines, at: ms)
                    let scroll = active.first ?? lastStarted(lyrics.lines, at: ms)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                            row(line, index: index, ms: ms, active: active.contains(index), scroll: scroll, lyrics: lyrics)
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.top, 30)
                    .padding(.horizontal, 20)
                    .padding(.bottom, viewport * 0.8)
                    .onChange(of: focusLine(lyrics.lines, at: ms) ?? scroll) { _, newFocus in
                        guard let newFocus, newFocus != focus else { return }
                        focus = newFocus
                        guard !browsing else { return }
                        withAnimation(.lyric(scrollLead(lyrics.lines, at: ms))) { proxy.scrollTo(newFocus, anchor: UnitPoint(x: 0.5, y: 0.02)) }
                    }
                }
            }
            .onScrollTargetVisibilityChange(idType: Int.self) { ids in visible = Set(ids) }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    resumeTask?.cancel()
                    browsing = true
                } else if phase == .idle, browsing {
                    // Back to following: soon if the sung line is in view, later if it isn't.
                    let delay: UInt64 = visible.contains(focus) ? 600_000_000 : 5_000_000_000
                    resumeTask?.cancel()
                    resumeTask = Task {
                        try? await Task.sleep(nanoseconds: delay)
                        guard !Task.isCancelled, player.isPlaying else { return }
                        browsing = false
                        withAnimation(.lyric(0.5)) { proxy.scrollTo(focus, anchor: UnitPoint(x: 0.5, y: 0.02)) }
                    }
                }
            }
            .onAppear {
                let ms = Int(player.position * 1000) - model.offsetMs
                focus = focusLine(lyrics.lines, at: ms) ?? lastStarted(lyrics.lines, at: ms) ?? 0
                proxy.scrollTo(focus, anchor: UnitPoint(x: 0.5, y: 0.02))
            }
        }
    }

    @ViewBuilder
    private func row(_ line: LyricLine, index: Int, ms: Int, active: Bool, scroll: Int?, lyrics: Lyrics) -> some View {
        let distance = min(4, abs(index - (scroll ?? index)))
        let alpha = active ? 1.0 : browsing ? 0.8 : [1.0, 0.8, 0.7, 0.58, 0.46][distance]
        let blur = active || browsing || !AppSettings.shared.lyricsBlur ? 0.0 : [0.0, 1.0, 1.0, 1.7, 2.4][distance]
        let duet = lyrics.hasDuet
        let trailing = line.alignment == .end
        Group {
            if line.isGap {
                gapRow(line, index: index, ms: ms, lines: lyrics.lines, active: active)
            } else {
                VStack(alignment: trailing ? .trailing : .leading, spacing: 0) {
                    lineText(line, ms: ms, active: active, size: 34, lineHeight: 41, tracking: -0.7)
                        .padding(10)
                    if let background = line.background, active || ms >= background.time - 250 && ms < background.end {
                        lineText(background, ms: ms, active: true, size: 23, lineHeight: 29, tracking: -0.4, stripParens: true)
                            .opacity(0.72)
                            .padding([.horizontal, .bottom], 10)
                            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: trailing ? .topTrailing : .topLeading)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
                .padding(.leading, duet && trailing ? 44 : 0)
                .padding(.trailing, duet && !trailing ? 44 : 0)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onTapGesture { player.seek(to: Double(max(0, line.time + model.offsetMs)) / 1000) }
            }
        }
        .scaleEffect(active ? 1 : 0.98, anchor: trailing ? .trailing : .leading)
        .opacity(alpha)
        .blur(radius: blur)
        .animation(.lyric(0.4), value: active)
        .animation(.lyric(0.4), value: distance)
        .animation(.lyric(0.4), value: browsing)
    }

    private func lineText(_ line: LyricLine, ms: Int, active: Bool, size: CGFloat, lineHeight: CGFloat, tracking: CGFloat,
                          stripParens: Bool = false) -> some View {
        var display = line.text
        if stripParens, display.hasPrefix("("), display.hasSuffix(")") { display = String(display.dropFirst().dropLast()) }
        let offset = stripParens && line.text.hasPrefix("(") ? 1.0 : 0
        let passed = ms >= line.end && line.hasKnownEnd
        let revealed: Double = line.isWordSynced ? line.revealedChars(at: ms) - offset : (active || passed || ms >= line.time ? Double(line.text.count) : 0)
        let unsung = passed ? 1.0 : 0.45
        return spannedText(display)
            .font(.sfDisplay(size, .heavy))
            .tracking(tracking)
            .lineSpacing(lineHeight - size * 1.19)
            .foregroundStyle(active ? .white : tint)
            .textRenderer(FillRenderer(revealed: active || passed ? revealed : 0, unsung: unsung))
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(line.alignment == .end ? .trailing : .leading)
    }

    /** Three dots that fill left to right across the pause; nothing pulses. */
    @ViewBuilder
    private func gapRow(_ gap: LyricLine, index: Int, ms: Int, lines: [LyricLine], active: Bool) -> some View {
        let next = lines.dropFirst(index + 1).first { !$0.isGap }?.time ?? gap.time + 4000
        let through = Double(ms - gap.time) / Double(max(1, next - gap.time))
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { k in
                Circle().fill(.white)
                    .frame(width: 13, height: 13)
                    .opacity(0.25 + 0.75 * min(1, max(0, through * 3 - Double(k))))
            }
        }
        .scaleEffect(active ? 1 : 0.76, anchor: .leading)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: active ? 56 : 0, alignment: .center)
        .opacity(active ? 1 : 0)
        .clipped()
        .animation(.lyric(active ? 0.4 : 0.35), value: active)
        .onTapGesture { player.seek(to: Double(max(0, gap.time + model.offsetMs)) / 1000) }
    }

    // MARK: Unsynced and loading

    private func unsynced(_ lyrics: Lyrics) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { _, line in
                    if line.isGap {
                        Spacer().frame(height: 14)
                    } else if line.text.hasPrefix("["), line.text.hasSuffix("]"), (3...60).contains(line.text.count) {
                        Text(line.text.dropFirst().dropLast().uppercased())
                            .font(.sfDisplay(11.5, .bold)).tracking(1.3).foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 11).padding(.vertical, 4)
                            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                            .padding(.top, 24).padding(.bottom, 8)
                    } else {
                        Text(line.text).font(.sfDisplay(30, .heavy)).tracking(-0.4).foregroundStyle(.white.opacity(0.95))
                            .lineSpacing(38 - 30 * 1.19)
                            .padding(10)
                    }
                }
            }
            .padding(.top, 30)
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
    }

    /** Still bars where the lines will be (the phone shimmers these; here they don't move). */
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 35) {
            ForEach(Array([[0.97, 0.54], [0.92, 0.99, 0.41], [0.68], [0.95, 0.73], [0.89, 0.96, 0.37]].enumerated()), id: \.offset) { _, block in
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(Array(block.enumerated()), id: \.offset) { _, width in
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)).frame(width: g.size.width * width)
                        }
                        .frame(height: 26)
                    }
                }
            }
        }
        .padding(.top, 40)
        .padding(.horizontal, 30)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Timing (LyricFocus)

    /** The latest line started, plus any earlier one still being sung. */
    private func activeRows(_ lines: [LyricLine], at ms: Int) -> [Int] {
        guard let latest = lastStarted(lines, at: ms) else { return [] }
        var rows = lines.indices.filter { i in
            i < latest && !lines[i].isGap && lines[i].hasKnownEnd && lines[i].time <= ms && ms < lines[i].end
        }
        rows.append(latest)
        return rows
    }

    private func lastStarted(_ lines: [LyricLine], at ms: Int) -> Int? {
        lines.lastIndex { $0.time <= ms }
    }

    /** How early the list moves for the next line: the pause before it, 350–500 ms. */
    private func scrollLead(_ lines: [LyricLine], at ms: Int) -> Double {
        guard let current = lastStarted(lines, at: ms), current + 1 < lines.count else { return 0.35 }
        let gap = lines[current + 1].time - lines[current].end
        return Double(min(500, max(350, gap))) / 1000
    }

    private func focusLine(_ lines: [LyricLine], at ms: Int) -> Int? {
        activeRows(lines, at: ms + Int(scrollLead(lines, at: ms) * 1000)).first
    }
}

/** The one line above the scrubber (CurrentLyricStrip), hard-edged and small. */
struct LyricStrip: View {
    let tint: Color
    var onTap: () -> Void

    @Environment(PlayerModel.self) private var player
    @Environment(LyricsModel.self) private var model

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying)) { _ in
            let ms = Int(player.position * 1000) - model.offsetMs
            content(ms: ms)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 22)
                .clipped()
        }
        .offset(y: 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private func content(ms: Int) -> some View {
        if !AppSettings.shared.syncedLyrics {
            // Its slot stays, empty, so the player keeps its shape.
            Color.clear
        } else if model.loading {
            label("Finding the words…", icon: nil)
        } else if let lyrics = model.lyrics, !lyrics.lines.isEmpty {
            if !lyrics.isSynced {
                label("Lyrics", icon: "music.note", chevron: true)
            } else if let index = lyrics.lines.lastIndex(where: { $0.time <= ms }), !lyrics.lines[index].isGap {
                let line = lyrics.lines[index]
                let revealed = line.isWordSynced ? line.revealedChars(at: ms) : Double(line.text.count)
                spannedText(line.text)
                    .font(.sfDisplay(16, .semibold)).tracking(-0.2)
                    .foregroundStyle(.white)
                    .textRenderer(FillRenderer(revealed: revealed, unsung: 0.55))
                    .lineLimit(1)
                    .id(index)
                    .transition(.asymmetric(insertion: .offset(y: 8).combined(with: .opacity), removal: .offset(y: -8).combined(with: .opacity)))
                    .animation(.fastOutSlowIn(0.34), value: index)
            } else {
                let started = lyrics.lines.contains { !$0.isGap && $0.time <= ms }
                label(started ? "Instrumental" : "Warming up", icon: "music.note", chevron: true, dim: started)
            }
        } else if model.videoId != nil {
            label("Lyrics not available", icon: nil)
        }
    }

    private func label(_ text: String, icon: String?, chevron: Bool = false, dim: Bool = false) -> some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 14)) }
            Text(text).font(.sfDisplay(16, .semibold)).tracking(-0.2).opacity(dim ? 0.5 : 0.55)
            if chevron { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).opacity(0.5) }
        }
        .foregroundStyle(.white)
    }
}

/** "Choose lyrics provider": every source with what it found. */
struct LyricsProviderSheet: View {
    @Environment(LyricsModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose lyrics provider").font(.sfDisplay(19, .bold)).foregroundStyle(.white).padding(.leading, 4)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.order) { source in
                        row(source)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(26)
        .presentationBackground(Color(hex: 0x121212))
        .environment(\.colorScheme, .dark)
    }

    private func row(_ source: LyricsSource) -> some View {
        let current = model.lyrics?.source == source
        let state = model.states[source] ?? .notFetched
        let status: String = current ? "Current provider" : {
            switch state {
            case .found: return "Lyrics found · Tap to use"
            case .notFound: return "Lyrics not found"
            case .fetching: return "Fetching lyrics…"
            case .notFetched: return "Tap to fetch"
            }
        }()
        return Button {
            model.choose(source)
            if state == .found { dismiss() }
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle().fill(.white.opacity(current ? 0.16 : 0.08))
                    switch state {
                    case .fetching: ProgressView().controlSize(.small).tint(.white.opacity(0.8))
                    case .found: Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).opacity(current ? 1 : 0.75)
                    case .notFound: Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).opacity(0.4)
                    case .notFetched: Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold)).opacity(0.7)
                    }
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.label).font(.sfDisplay(16, current ? .semibold : .regular)).opacity(current ? 1 : 0.85)
                    Text(status).font(.sfDisplay(12, .semibold)).opacity(current ? 0.7 : 0.5)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.white.opacity(current ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(current || state == .notFound)
    }
}
