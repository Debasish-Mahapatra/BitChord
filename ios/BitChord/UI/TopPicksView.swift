import SwiftUI

/** A card in Top Picks: 60% of the row, at most 280pt, 3:4. */
private func topPickWidth(_ available: CGFloat) -> CGFloat { min(available * 0.60, 280) }

/** Google and Apple artwork at a size, cropped (croppedAt). */
private func cropped(_ url: String?, _ width: Int, _ height: Int? = nil) -> URL? {
    guard let url else { return nil }
    let h = height ?? width
    if url.contains("mzstatic.com/image/thumb/") {
        let side = max(width, h)
        return URL(string: url.components(separatedBy: "/").dropLast().joined(separator: "/") + "/\(side)x\(side)cc.jpg")
    }
    if let range = url.range(of: #"=w\d+-h\d+[^/?]*$"#, options: .regularExpression) {
        return URL(string: url.replacingCharacters(in: range, with: "=w\(width)-h\(h)-p-l90-rj"))
    }
    return Artwork.url(url, px: max(width, h))
}

/** "Top Picks for You". */
struct TopPicksShelf: View {
    let picks: [TopPick]
    let width: CGFloat
    var listenerName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Top Picks for You")
            HorizontalShelf(spacing: 14) {
                ForEach(picks) { pick in
                    TopPickCard(pick: pick, listenerName: listenerName)
                        .frame(width: topPickWidth(width))
                }
            }
        }
        .padding(.bottom, 26)
    }
}

/** While the picks are built: the header and two still placeholder cards. */
struct TopPicksSkeleton: View {
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkeletonBlock().frame(width: 180, height: 18).padding(.horizontal, Metrics.gutter).padding(.vertical, 10)
            HStack(spacing: 14) {
                ForEach(0..<2, id: \.self) { _ in
                    SkeletonBlock(radius: 12).frame(width: topPickWidth(width), height: topPickWidth(width) / 0.75)
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
        .frame(width: width, alignment: .leading)
        .clipped()
        .padding(.bottom, 26)
    }
}

struct TopPickCard: View {
    let pick: TopPick
    var listenerName: String?

    @Environment(Router.self) private var router
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let text = pick.text(listenerName: listenerName)
        ZStack(alignment: .bottomLeading) {
            art
            if branded {
                Image("Logo").resizable().aspectRatio(730 / 484, contentMode: .fit).frame(height: 15)
                    .foregroundStyle(.white)
                    .padding(.top, 12).padding(.trailing, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(text.eyebrow).font(.sfDisplay(13)).foregroundStyle(eyebrow).lineLimit(1)
                Text(text.title).font(.sfDisplay(17, .semibold)).tracking(-0.2).foregroundStyle(.white).lineLimit(2)
                if !text.subtitle.isEmpty {
                    Text(text.subtitle).font(.sfDisplay(13)).foregroundStyle(.white.opacity(0.86)).lineLimit(2)
                }
            }
            .padding(16)
        }
        .aspectRatio(0.75, contentMode: .fit)
        .background(Theme.surfaceVariant)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.thumbnailBorder, lineWidth: 1) }
        .contentShape(Rectangle())
        .onTapGesture { open(text.title) }
    }

    private var branded: Bool {
        switch pick.kind {
        case .personalStation, .discoveryStation, .mood, .artistAndSimilar: return true
        default: return false
        }
    }

    private var eyebrow: Color {
        switch pick.kind {
        case .personalStation: return Color(hex: 0xFFD2DA)
        case .discoveryStation: return Color(hex: 0xCDBDFF)
        case .mood: return (pick.mood ?? .feelGood).style.eyebrow
        case .artistAndSimilar: return CollagePalette.of(pick.artistName ?? "").eyebrow
        default: return .white.opacity(0.62)
        }
    }

    @ViewBuilder
    private var art: some View {
        switch pick.kind {
        case .personalStation: PersonalStationArt()
        case .discoveryStation: DiscoveryStationArt()
        case .mood: MoodArt(mood: pick.mood ?? .feelGood, square: false)
        case .artistAndSimilar: ArtistCollageArt(images: pick.images, palette: CollagePalette.of(pick.artistName ?? ""))
        case .latestRelease, .newReleaseMix: ReleaseArt(url: pick.images.first)
        case .featuredArtist:
            ZStack {
                RemoteImage(url: cropped(pick.images.first, 540, 720))
                LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.45), location: 0.72),
                                       .init(color: .black.opacity(0.82), location: 1)], startPoint: .top, endPoint: .bottom)
            }
        }
    }

    /** A latest release opens its album; everything else plays its queue. */
    private func open(_ label: String) {
        if pick.kind == .latestRelease, let browseId = pick.browseId {
            router.open(BrowseItem(browseId: browseId, title: pick.title, subtitle: pick.artistName ?? "",
                                   thumbnailUrl: pick.images.first, type: .album))
            return
        }
        TopPickPlayer.play(pick, label: label)
    }
}

/** Plays a pick's (or a mood's) queue once it's built. */
@MainActor
enum TopPickPlayer {
    private static var generation = 0

    static func play(_ pick: TopPick, label: String) {
        generation += 1
        let request = generation
        Task {
            let songs = await TopPicks.queue(pick)
            guard request == generation else { return }
            guard !songs.isEmpty else {
                PlayerModel.shared.showNotice("Couldn’t load tracks")
                return
            }
            PlayerModel.shared.play(songs, from: 0, source: QueueSource(title: label, kind: .playlist,
                                                                        id: pick.watch?.playlistId ?? pick.mood?.rawValue))
        }
    }
}

// MARK: - Card art (still frames)

private struct ReleaseArt: View {
    let url: String?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                Color.black
                RemoteImage(url: cropped(url, 160))
                    .frame(width: g.size.width, height: g.size.height * 0.42)
                    .blur(radius: 24)
                    .clipped()
                    .frame(maxHeight: .infinity, alignment: .bottom)
                LinearGradient(stops: [.init(color: .black.opacity(0.08), location: 0.6), .init(color: .black.opacity(0.38), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                RemoteImage(url: cropped(url, 720))
                    .frame(width: g.size.width, height: g.size.width)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.78), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
            }
        }
    }
}

private struct PersonalStationArt: View {
    private static let layers: [(rest: CGFloat, deep: UInt32, light: UInt32)] = [
        (1.00, 0xFE5E83, 0xFA6196), (0.66, 0xFE5065, 0xFC657C), (0.43, 0xFB594C, 0xFC776D), (0.21, 0xFB6729, 0xF98A48),
    ]

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(stops: [.init(color: Color(hex: 0xF7334F), location: 0), .init(color: Color(hex: 0xFA6094), location: 0.38),
                                 .init(color: Color(hex: 0xF02A4A), location: 0.75), .init(color: Color(hex: 0xEE213D), location: 1)]),
                startPoint: .zero, endPoint: CGPoint(x: w, y: 0)))
            for (index, layer) in Self.layers.enumerated() {
                let tip = index == 0 ? layer.rest : layer.rest + 0.07 * wave(0, Double(index) * 0.19)
                var path = Path()
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: w * tip, y: h / 2))
                path.addLine(to: CGPoint(x: 0, y: h))
                path.closeSubpath()
                context.fill(path, with: .linearGradient(Gradient(colors: [Color(hex: layer.deep), Color(hex: layer.light)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: w * layer.rest, y: 0)))
            }
        }
    }
}

private struct DiscoveryStationArt: View {
    private static let top: [UInt32] = [0x3A2496, 0x2F4FB0, 0x3B30A0, 0x2E7FB8, 0x27988A, 0x3C8DA8]
    private static let bottom: [UInt32] = [0x3A2496, 0x333EA4, 0x2F62B6, 0x288B99, 0x3477BA, 0x42A296]
    private static let edges: [CGFloat] = [0, 0.24, 0.44, 0.62, 0.78, 0.91, 1.02]

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let apex = CGPoint(x: w, y: h / 2)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [Color(hex: 0x2A869F), Color(hex: 0x3477BA)]), startPoint: .zero, endPoint: CGPoint(x: w, y: h)))
            func fan(_ edgeY: CGFloat, _ colors: [UInt32], _ offset: Double) {
                var previous = Self.edges[0]
                for i in 1..<Self.edges.count {
                    let rest = Self.edges[i]
                    let edge = i == Self.edges.count - 1 ? rest : rest + 0.06 * wave(0, offset + Double(i) * 0.11)
                    var path = Path()
                    path.move(to: apex)
                    path.addLine(to: CGPoint(x: w * previous, y: edgeY))
                    path.addLine(to: CGPoint(x: w * edge, y: edgeY))
                    path.closeSubpath()
                    let mid = w * (Self.edges[i - 1] + Self.edges[i]) / 2
                    let base = UIColor(hex: colors[(i - 1) % colors.count])
                    context.fill(path, with: .linearGradient(Gradient(colors: [Color(base.mixed(with: .white, 0.10)), Color(base)]),
                                                             startPoint: apex, endPoint: CGPoint(x: mid, y: edgeY)))
                    previous = edge
                }
            }
            fan(0, Self.top, 0)
            fan(h, Self.bottom, 0.5)
            var arrow = Path()
            arrow.move(to: .zero)
            arrow.addLine(to: apex)
            arrow.addLine(to: CGPoint(x: 0, y: h))
            arrow.closeSubpath()
            context.fill(arrow, with: .linearGradient(Gradient(stops: [.init(color: Color(hex: 0x502798), location: 0),
                                                                       .init(color: Color(hex: 0x421C88), location: 0.55),
                                                                       .init(color: Color(hex: 0x4A2292), location: 1)]),
                                                      startPoint: .zero, endPoint: CGPoint(x: w, y: 0)))
            let inner = 0.08 + 0.04 * wave(0, 0.25)
            var innerArrow = Path()
            innerArrow.move(to: CGPoint(x: 0, y: h * inner))
            innerArrow.addLine(to: CGPoint(x: w * (0.9 - inner), y: h / 2))
            innerArrow.addLine(to: CGPoint(x: 0, y: h * (1 - inner)))
            innerArrow.closeSubpath()
            context.fill(innerArrow, with: .color(Color(hex: 0x3C1981).opacity(0.35)))
        }
    }
}

/** sin(2π(phase + offset)): the station art's wave, read at phase 0 for a still frame. */
private func wave(_ phase: Double, _ offset: Double) -> Double { sin(2 * .pi * (phase + offset)) }

struct CollagePalette {
    let top: Color, bottom: Color, eyebrow: Color

    static let all: [CollagePalette] = [
        .init(top: Color(hex: 0x8F3F00), bottom: Color(hex: 0xFF6A0F), eyebrow: Color(hex: 0xFFC48A)),
        .init(top: Color(hex: 0x2D8A20), bottom: Color(hex: 0x4FD22C), eyebrow: Color(hex: 0xCBFFA3)),
        .init(top: Color(hex: 0x173E9E), bottom: Color(hex: 0x2F7BFF), eyebrow: Color(hex: 0xC0D8FF)),
        .init(top: Color(hex: 0x4A1E99), bottom: Color(hex: 0x8A4BFF), eyebrow: Color(hex: 0xDCC8FF)),
        .init(top: Color(hex: 0x0B6E6E), bottom: Color(hex: 0x14B8A6), eyebrow: Color(hex: 0xB5FFF3)),
        .init(top: Color(hex: 0x8E1426), bottom: Color(hex: 0xF0364F), eyebrow: Color(hex: 0xFFC4CC)),
    ]

    static func of(_ name: String) -> CollagePalette {
        all[Int(abs(Int64(MeshTexture.javaHashCode(name)))) % all.count]
    }
}

private struct ArtistCollageArt: View {
    let images: [String]
    let palette: CollagePalette

    /** Where each face sits: centre x, centre y and diameter, as shares of the card. */
    private static func slots(_ count: Int) -> [(CGFloat, CGFloat, CGFloat)] {
        switch count {
        case 0: return []
        case 1: return [(0.5, 0.34, 0.66)]
        case 2: return [(0.40, 0.28, 0.60), (0.72, 0.52, 0.36)]
        default: return [(0.37, 0.257, 0.594), (0.76, 0.48, 0.333), (0.457, 0.608, 0.29)]
        }
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let slots = Self.slots(images.count)
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [palette.top, palette.bottom], startPoint: .top, endPoint: .bottom)
                ForEach(Array(zip(slots, images).enumerated()), id: \.offset) { _, pair in
                    let (slot, url) = pair
                    let diameter = w * slot.2
                    RemoteImage(url: cropped(url, slot.2 > 0.5 ? 720 : 480))
                        .frame(width: diameter, height: diameter)
                        .background(.black.opacity(0.18))
                        .clipShape(Circle())
                        .offset(x: w * slot.0 - diameter / 2, y: h * slot.1 - diameter / 2)
                }
            }
        }
    }
}

// MARK: - Moods

/** A mood's card or tile: its colour and its line-art emblem, still. */
struct MoodArt: View {
    let mood: TopPickMood
    var square = false

    var body: some View {
        let style = mood.style
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(style.background))
            let w = size.width, h = size.height
            let frame: MoodFrame
            if square {
                let side = w * 0.70
                frame = MoodFrame(left: (w - side) / 2, top: (h - side) / 2, side: side)
            } else {
                let side = min(w * 0.84, h * 0.62)
                frame = MoodFrame(left: (w - side) / 2, top: h * 0.37 - side / 2, side: side)
            }
            MoodEmblem.draw(mood, in: &context, frame: frame, color: style.stroke, width: square ? 2 : 2.5)
        }
    }
}

struct MoodFrame {
    let left: CGFloat, top: CGFloat, side: CGFloat
    func x(_ f: CGFloat) -> CGFloat { left + side * f }
    func y(_ f: CGFloat) -> CGFloat { top + side * f }
    func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: self.x(x), y: self.y(y)) }
    var center: CGPoint { at(0.5, 0.5) }
}

/**
 * The mood emblems (drawEmblem), drawn at phase 0 — the frame the phone shows
 * with motion off. Their loops include a flashing bolt, a beating heart and
 * twinkling stars, so the still frame is the only one drawn.
 */
enum MoodEmblem {
    static func draw(_ mood: TopPickMood, in context: inout GraphicsContext, frame f: MoodFrame, color: Color, width: CGFloat) {
        let side = f.side
        let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        func stroke(_ path: Path, _ alpha: Double = 1) { context.stroke(path, with: .color(color.opacity(alpha)), style: style) }
        func line(_ a: CGPoint, _ b: CGPoint, _ alpha: Double = 1) {
            var p = Path(); p.move(to: a); p.addLine(to: b); stroke(p, alpha)
        }
        func circle(_ c: CGPoint, _ r: CGFloat, _ alpha: Double = 1) {
            stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), alpha)
        }
        func polyline(_ points: [(CGFloat, CGFloat)], close: Bool = false) -> Path {
            var p = Path()
            for (i, pt) in points.enumerated() { i == 0 ? p.move(to: f.at(pt.0, pt.1)) : p.addLine(to: f.at(pt.0, pt.1)) }
            if close { p.closeSubpath() }
            return p
        }
        /** An arc on an ellipse, angles in degrees clockwise from 3 o'clock, as Compose draws them. */
        func arc(_ rect: CGRect, _ start: Double, _ sweep: Double, into path: inout Path, moveFirst: Bool) {
            let steps = 48
            for k in 0...steps {
                let a = (start + sweep * Double(k) / Double(steps)) * .pi / 180
                let p = CGPoint(x: rect.midX + rect.width / 2 * cos(a), y: rect.midY + rect.height / 2 * sin(a))
                if k == 0 && moveFirst { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
        func edgeFade(_ share: Double) -> Double {
            let v = share > 0.85 ? (1 - share) / 0.15 : share < 0.15 ? share / 0.15 : 1
            return min(1, max(0, v))
        }
        func heartPath() -> Path {
            let r: CGFloat = 0.24
            var p = Path()
            p.move(to: f.at(0.5, 0.92))
            p.addLine(to: f.at(0.28 - r * 0.707, 0.30 + r * 0.707))
            arc(CGRect(x: f.x(0.28 - r), y: f.y(0.30 - r), width: side * 2 * r, height: side * 2 * r), 135, 195, into: &p, moveFirst: false)
            arc(CGRect(x: f.x(0.72 - r), y: f.y(0.30 - r), width: side * 2 * r, height: side * 2 * r), 210, 195, into: &p, moveFirst: false)
            p.closeSubpath()
            return p
        }
        func sparkle(_ c: CGPoint, _ r: CGFloat) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: c.x, y: c.y - r))
            p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + r * 0.12, y: c.y - r * 0.12))
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + r * 0.12, y: c.y + r * 0.12))
            p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - r * 0.12, y: c.y + r * 0.12))
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - r * 0.12, y: c.y - r * 0.12))
            p.closeSubpath()
            return p
        }
        func fivePointStar(_ c: CGPoint, _ r: CGFloat) -> Path {
            var p = Path()
            for i in 0..<10 {
                let radius = i % 2 == 0 ? r : r * 0.45
                let a = Double(i) * .pi / 5 - .pi / 2
                let pt = CGPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath()
            return p
        }

        switch mood {
        case .energy:
            stroke(polyline([(0.486, 0.123), (0.886, 0.123), (0.532, 0.509), (0.877, 0.509), (0.114, 0.895), (0.409, 0.614), (0.105, 0.614)], close: true))
        case .relax:
            for (index, stone) in [(0.17, 0.44, 0.18), (0.38, 0.68, 0.28), (0.66, 0.84, 0.36)].enumerated() {
                let sway = wave(0, Double(index) * 0.22)
                let center = CGPoint(x: f.x(0.5 + 0.015 * sway), y: f.y(stone.0))
                let rect = CGRect(x: center.x - side * stone.1 / 2, y: center.y - side * stone.2 / 2, width: side * stone.1, height: side * stone.2)
                let turn = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: 4 * sway * .pi / 180).translatedBy(x: -center.x, y: -center.y)
                stroke(Path(ellipseIn: rect).applying(turn))
            }
        case .feelingBlue:
            var p = Path()
            for k in 0...320 {
                let t = Double(k) / 320
                let a = .pi + t * 5.5 * 2 * .pi
                let rx = 0.38 * (1 - 0.72 * t), ry = 0.075 * (1 - 0.55 * t)
                let pt = f.at(0.5 + rx * cos(a), 0.10 + 0.78 * t + ry * sin(a))
                k == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            stroke(p)
        case .feelGood:
            var p = Path()
            p.move(to: f.at(0.5, 0.06))
            p.addQuadCurve(to: f.at(0.94, 0.5), control: f.at(0.56, 0.44))
            p.addQuadCurve(to: f.at(0.5, 0.94), control: f.at(0.56, 0.56))
            p.addQuadCurve(to: f.at(0.06, 0.5), control: f.at(0.44, 0.56))
            p.addQuadCurve(to: f.at(0.5, 0.06), control: f.at(0.44, 0.44))
            p.closeSubpath()
            stroke(p)
        case .focus:
            for i in 0..<4 {
                let share = Double(i + 1) / 4
                circle(f.center, side * 0.5 * share, edgeFade(share))
            }
        case .heartbreak:
            let dash = side * 0.075, gap = side * 0.055
            context.stroke(heartPath(), with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: [dash, gap]))
        case .love:
            stroke(heartPath())
        case .afterHours:
            let disc = Path(ellipseIn: CGRect(x: f.x(0.42) - side * 0.34, y: f.y(0.52) - side * 0.34, width: side * 0.68, height: side * 0.68))
            let biteR = side * 0.34 * 0.88
            let biteC = f.at(0.42 + 0.34 * 0.5, 0.52 - 0.34 * 0.3)
            let bite = Path(ellipseIn: CGRect(x: biteC.x - biteR, y: biteC.y - biteR, width: 2 * biteR, height: 2 * biteR))
            stroke(disc.subtracting(bite))
            for (index, star) in [(0.80, 0.22, 0.07), (0.86, 0.58, 0.05), (0.68, 0.82, 0.04)].enumerated() {
                let twinkle = 0.25 + 0.75 * (0.5 + 0.5 * wave(0, Double(index) / 3))
                stroke(sparkle(f.at(star.0, star.1), side * star.2), twinkle)
            }
        case .aloneTime:
            let center = f.at(0.5, 0.55)
            for i in 0..<4 {
                let share = Double(i) / 4
                let rx = side * 0.5 * share
                stroke(Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - rx * 0.42, width: rx * 2, height: rx * 0.84)), edgeFade(share))
            }
        case .chill:
            var clipped = context
            clipped.clip(to: Path(CGRect(x: f.left, y: f.top, width: side, height: side)))
            for (row, y) in [0.32, 0.5, 0.68].enumerated() {
                var p = Path()
                for k in 0...80 {
                    let u = Double(k) / 80
                    let py = y + 0.05 * sin(2 * .pi * (u / 0.33 - Double(row) * 0.15))
                    k == 0 ? p.move(to: f.at(u, py)) : p.addLine(to: f.at(u, py))
                }
                clipped.stroke(p, with: .color(color), style: style)
            }
        case .commuting:
            line(f.at(0.06, 0.95), f.at(0.44, 0.14))
            line(f.at(0.94, 0.95), f.at(0.56, 0.14))
            line(f.at(0.15, 0.14), f.at(0.85, 0.14))
            for k in 0..<5 {
                let u = Double(k) / 5
                let y0 = 0.18 + 0.77 * u * u
                let y1 = min(y0 + 0.02 + 0.08 * u, 0.95)
                line(f.at(0.5, y0), f.at(0.5, y1), edgeFade(u))
            }
        case .eatingCooking:
            var bowl = Path()
            arc(CGRect(x: f.x(0.12), y: f.y(0.25), width: side * 0.76, height: side * 0.70), 0, 180, into: &bowl, moveFirst: true)
            bowl.closeSubpath()
            stroke(bowl)
            line(f.at(0.05, 0.6), f.at(0.95, 0.6))
            for (index, x) in [0.36, 0.5, 0.64].enumerated() {
                let rise = (Double(index) / 3).truncatingRemainder(dividingBy: 1)
                var p = Path()
                for k in 0...30 {
                    let u = Double(k) / 30
                    let px = x + 0.035 * sin(2 * .pi * (u * 1.2 + rise))
                    let py = 0.5 - 0.3 * u - 0.1 * rise
                    k == 0 ? p.move(to: f.at(px, py)) : p.addLine(to: f.at(px, py))
                }
                stroke(p, sin(.pi * rise))
            }
        case .evening:
            let horizon = 0.62
            var clipped = context
            clipped.clip(to: Path(CGRect(x: f.left - side, y: f.top - side, width: side * 3, height: f.y(horizon) - (f.top - side))))
            let c = f.at(0.5, horizon - 0.02), r = side * 0.26
            clipped.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color), style: style)
            line(f.at(0.04, horizon), f.at(0.96, horizon))
            line(f.at(0.2, horizon + 0.11), f.at(0.8, horizon + 0.11))
            line(f.at(0.36, horizon + 0.22), f.at(0.64, horizon + 0.22))
        case .fitness:
            stroke(polyline([(0, 0.55), (0.28, 0.55), (0.36, 0.42), (0.44, 0.76), (0.52, 0.18), (0.6, 0.84), (0.67, 0.55), (1, 0.55)]), 0.3)
        case .gaming:
            for size in [0.9, 0.62, 0.34] {
                stroke(Path(CGRect(x: f.x(0.5 - size / 2), y: f.y(0.5 - size / 2), width: side * size, height: side * size)))
            }
        case .home:
            stroke(polyline([(0.5, 0.1), (0.94, 0.5), (0.82, 0.5), (0.82, 0.92), (0.18, 0.92), (0.18, 0.5), (0.06, 0.5)], close: true))
            stroke(Path(CGRect(x: f.x(0.41), y: f.y(0.66), width: side * 0.18, height: side * 0.26)))
            let window = Path(CGRect(x: f.x(0.27), y: f.y(0.56), width: side * 0.1, height: side * 0.1))
            context.fill(window, with: .color(color.opacity(0.15 + 0.45 * 0.5)))
            stroke(window)
        case .morning:
            let horizon = 0.72
            let sun = f.at(0.5, horizon - 0.03 - 0.05 * 0.5)
            var clipped = context
            clipped.clip(to: Path(CGRect(x: f.left - side, y: f.top - side, width: side * 3, height: f.y(horizon) - (f.top - side))))
            let r = side * 0.2
            clipped.stroke(Path(ellipseIn: CGRect(x: sun.x - r, y: sun.y - r, width: 2 * r, height: 2 * r)), with: .color(color), style: style)
            for k in 0..<9 {
                let a = Double.pi + (Double(k) + 0.5) * .pi / 9
                var p = Path()
                p.move(to: CGPoint(x: sun.x + side * 0.28 * cos(a), y: sun.y + side * 0.28 * sin(a)))
                p.addLine(to: CGPoint(x: sun.x + side * 0.38 * cos(a), y: sun.y + side * 0.38 * sin(a)))
                clipped.stroke(p, with: .color(color), style: style)
            }
            line(f.at(0.04, horizon), f.at(0.96, horizon))
        case .motivation:
            for k in 0..<3 {
                let u = Double(k) / 3
                let y = 0.82 - 0.66 * u
                stroke(polyline([(0.22, y + 0.17), (0.5, y), (0.78, y + 0.17)]), sin(.pi * u))
            }
        case .outdoors:
            stroke(polyline([(0.02, 0.86), (0.36, 0.36), (0.55, 0.62), (0.7, 0.44), (0.98, 0.86)]))
            line(f.at(0.02, 0.86), f.at(0.98, 0.86))
            circle(f.at(0.78 + 0.02 * wave(0, 0.25), 0.2), side * 0.09)
        case .party:
            for (index, star) in [(0.24, 0.24, 0.14), (0.72, 0.18, 0.11), (0.52, 0.5, 0.17), (0.2, 0.72, 0.1), (0.8, 0.66, 0.13), (0.56, 0.88, 0.08)].enumerated() {
                let pop = 0.85 + 0.15 * wave(0, Double(index) / 6)
                stroke(fivePointStar(f.at(star.0, star.1), side * star.2 * pop))
            }
        case .sleep:
            var lid = Path()
            arc(CGRect(x: f.x(0.12), y: f.y(0.2), width: side * 0.76, height: side * 0.46), 10, 160, into: &lid, moveFirst: true)
            lid.closeSubpath()
            stroke(lid)
            for k in 0..<5 {
                let a = (30 + Double(k) * 30) * .pi / 180
                let base = CGPoint(x: f.x(0.5 + 0.38 * cos(a)), y: f.y(0.43 + 0.23 * sin(a)))
                line(base, CGPoint(x: base.x + side * 0.08 * cos(a), y: base.y + side * 0.1 * sin(a)))
            }
        case .social:
            circle(f.at(0.38, 0.5), side * 0.27)
            circle(f.at(0.62, 0.5), side * 0.27)
        case .sports:
            let r = side * 0.44
            circle(f.center, r)
            var clipped = context
            clipped.clip(to: Path(ellipseIn: CGRect(x: f.center.x - r, y: f.center.y - r, width: 2 * r, height: 2 * r)))
            for dx in [-1.25, 1.25] {
                let c = CGPoint(x: f.center.x + r * dx, y: f.center.y)
                clipped.stroke(Path(ellipseIn: CGRect(x: c.x - r * 0.95, y: c.y - r * 0.95, width: r * 1.9, height: r * 1.9)), with: .color(color), style: style)
            }
        case .summertime:
            circle(f.center, side * 0.22)
            for k in 0..<12 {
                let a = Double(k) * 2 * .pi / 12
                line(CGPoint(x: f.center.x + side * 0.31 * cos(a), y: f.center.y + side * 0.31 * sin(a)),
                     CGPoint(x: f.center.x + side * 0.46 * cos(a), y: f.center.y + side * 0.46 * sin(a)))
            }
        case .holiday:
            for k in 0..<6 {
                let a = Double(k) * 2 * .pi / 6
                func point(_ d: CGFloat) -> CGPoint { CGPoint(x: f.center.x + side * d * cos(a), y: f.center.y + side * d * sin(a)) }
                line(f.center, point(0.46))
                for d in [0.22, 0.34] {
                    let base = point(d)
                    for turn in [-0.785, 0.785] {
                        line(base, CGPoint(x: base.x + side * 0.1 * cos(a + turn), y: base.y + side * 0.1 * sin(a + turn)))
                    }
                }
            }
        case .weekend:
            circle(f.center, side * 0.46)
            circle(f.center, side * 0.16)
            let dot = side * 0.025
            context.fill(Path(ellipseIn: CGRect(x: f.center.x - dot, y: f.center.y - dot, width: 2 * dot, height: 2 * dot)), with: .color(color))
            for r in [0.36, 0.27] {
                let rect = CGRect(x: f.center.x - side * r, y: f.center.y - side * r, width: side * 2 * r, height: side * 2 * r)
                var a = Path(); arc(rect, 200, 70, into: &a, moveFirst: true); stroke(a)
                var b = Path(); arc(rect, 20, 70, into: &b, moveFirst: true); stroke(b)
            }
        case .wellbeing:
            let open = 0.85
            let base = f.at(0.5, 0.84)
            for angle in [-62.0, -31, 0, 31, 62] {
                var petal = Path()
                petal.move(to: base)
                petal.addQuadCurve(to: f.at(0.5, 0.14 + (1 - open) * 0.3), control: f.at(0.66, 0.52))
                petal.addQuadCurve(to: base, control: f.at(0.34, 0.52))
                let turn = CGAffineTransform(translationX: base.x, y: base.y).rotated(by: angle * open * .pi / 180).translatedBy(x: -base.x, y: -base.y)
                stroke(petal.applying(turn))
            }
        case .work:
            stroke(Path(roundedRect: CGRect(x: f.x(0.16), y: f.y(0.18), width: side * 0.68, height: side * 0.48), cornerRadius: side * 0.03))
            line(f.at(0.04, 0.78), f.at(0.96, 0.78))
            line(f.at(0.16, 0.66), f.at(0.04, 0.78))
            line(f.at(0.84, 0.66), f.at(0.96, 0.78))
            line(f.at(0.28, 0.36), f.at(0.64, 0.36))
            line(f.at(0.28, 0.48), f.at(0.28, 0.48))
            line(f.at(0.32, 0.43), f.at(0.32, 0.53))
        }
    }
}

/** "Find Your Mood": the seven core moods as square tiles, "Show all" for every one. */
struct FindYourMoodShelf: View {
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Find Your Mood") {
                Button { router.push(.moods) } label: {
                    Text("Show all").textStyle(.titleSmall).foregroundStyle(Theme.primary)
                }
                .buttonStyle(.plain)
            }
            HorizontalShelf(spacing: 14) {
                ForEach(TopPickMood.allCases.filter(\.isCoreMood)) { mood in
                    MoodTile(mood: mood).frame(width: Metrics.shelfCardWidth)
                }
            }
        }
        .padding(.bottom, 26)
    }
}

struct MoodTile: View {
    let mood: TopPickMood

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MoodArt(mood: mood, square: true)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    Image("Logo").resizable().aspectRatio(730 / 484, contentMode: .fit).frame(height: 11)
                        .foregroundStyle(.white).padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.thumbnailBorder, lineWidth: 1) }
            Text(mood.title).textStyle(.titleMedium).foregroundStyle(Theme.onBackground).lineLimit(1).padding(.top, 10)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let hints = TopPicksStore.shared.picks?.first { $0.kind == .mood }?.hints ?? TopPicks.regionHints()
            TopPickPlayer.play(.moodStation(mood, hints: hints), label: mood.title)
        }
    }
}

/** Every mood and activity, as a grid. */
struct MoodGridPage: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        GeometryReader { geometry in
            let columns = max(2, min(5, Int((geometry.size.width - 32 + 12) / (140 + 12))))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageTitle(text: "Find Your Mood")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns), spacing: 20) {
                        ForEach(TopPickMood.allCases) { MoodTile(mood: $0) }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                .padding(.top, Metrics.contentTop)
                .padding(.bottom, Metrics.contentBottom(hasSong: player.song != nil))
            }
        }
    }
}
