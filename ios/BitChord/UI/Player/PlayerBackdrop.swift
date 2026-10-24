import SwiftUI
import UIKit

/**
 * ArtworkMeshBackdrop: the cover averaged into a 6×6 grid (read flipped, so
 * row 0 is its bottom edge), each cell lifted a little, the rows below the
 * seam rotated by one seeded amount, then smoothly resampled to 32×32. Still:
 * it only cross-fades when the track changes.
 */
enum MeshTexture {
    static let grid = 6
    static let size = 32

    /** The mesh texture and the mean of the sleeve's bottom edge, the colour a flat backdrop holds. */
    static func make(_ image: UIImage, seedKey: String) -> (texture: UIImage, edge: Color)? {
        guard let sample = PixelSample(image, size: 120) else { return nil }
        let width = sample.width, height = sample.height
        let cols = min(grid, width), rows = min(grid, height)
        var sums = [(Double, Double, Double, Double)](repeating: (0, 0, 0, 0), count: rows * cols)
        for y in 0..<height {
            let rowBase = ((height - 1 - y) * rows / height) * cols
            for x in 0..<width {
                let cell = rowBase + x * cols / width
                let p = sample.pixels[y * width + x]
                sums[cell].0 += p.0; sums[cell].1 += p.1; sums[cell].2 += p.2; sums[cell].3 += 1
            }
        }
        var cells: [(Double, Double, Double)] = sums.map { s in
            let n = max(1, s.3)
            var hsl = HSL(r: s.0 / n, g: s.1 / n, b: s.2 / n)
            hsl.s = min(1, hsl.s * 1.12)
            hsl.l = max(hsl.l, 0.045)
            return hsl.rgb
        }
        let edgeRow = cells.prefix(cols)
        let edge = Color(red: edgeRow.map(\.0).reduce(0, +) / Double(cols),
                         green: edgeRow.map(\.1).reduce(0, +) / Double(cols),
                         blue: edgeRow.map(\.2).reduce(0, +) / Double(cols))
        // One seeded rotation for every row under the seam: same cover, same layout.
        if rows > 1 {
            var random = KotlinRandom(seed: javaHashCode(seedKey))
            let mirror = random.nextBoolean()
            let shift = random.nextInt(cols)
            let source = cells
            for row in 1..<rows {
                for x in 0..<cols {
                    let src = mirror ? cols - 1 - x : x
                    cells[row * cols + x] = source[row * cols + (src + shift) % cols]
                }
            }
        }
        // Smoothstep-weighted bilinear up to 32×32.
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        func smooth(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }
        func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
            (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
        }
        for ty in 0..<size {
            let fy = (Double(ty) + 0.5) / Double(size) * Double(rows) - 0.5
            let y0 = min(rows - 1, max(0, Int(floor(fy)))), y1 = min(y0 + 1, rows - 1)
            let wy = smooth(fy - Double(y0))
            for tx in 0..<size {
                let fx = (Double(tx) + 0.5) / Double(size) * Double(cols) - 0.5
                let x0 = min(cols - 1, max(0, Int(floor(fx)))), x1 = min(x0 + 1, cols - 1)
                let wx = smooth(fx - Double(x0))
                let top = mix(cells[y0 * cols + x0], cells[y0 * cols + x1], wx)
                let bottom = mix(cells[y1 * cols + x0], cells[y1 * cols + x1], wx)
                let c = mix(top, bottom, wy)
                let i = (ty * size + tx) * 4
                bytes[i] = UInt8(min(255, max(0, (c.0 * 255).rounded())))
                bytes[i + 1] = UInt8(min(255, max(0, (c.1 * 255).rounded())))
                bytes[i + 2] = UInt8(min(255, max(0, (c.2 * 255).rounded())))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return (UIImage(cgImage: cg), edge)
    }

    /** Java's String.hashCode, over UTF-16 units. */
    static func javaHashCode(_ string: String) -> Int32 {
        string.utf16.reduce(Int32(0)) { $0 &* 31 &+ Int32($1) }
    }
}

/** Kotlin's `Random(seed)`: XorWowRandom(seed, seed shr 31), warmed up by 64 draws. */
struct KotlinRandom {
    private var x: Int32, y: Int32, z: Int32, w: Int32, v: Int32, addend: Int32

    init(seed: Int32) {
        let seed2 = seed >> 31
        x = seed; y = seed2; z = 0; w = 0; v = ~seed
        addend = (seed << 10) ^ Int32(bitPattern: UInt32(bitPattern: seed2) >> 4)
        for _ in 0..<64 { _ = nextInt() }
    }

    mutating func nextInt() -> Int32 {
        var t = x
        t ^= Int32(bitPattern: UInt32(bitPattern: t) >> 2)
        x = y; y = z; z = w
        let v0 = v
        w = v0
        t = (t ^ (t << 1)) ^ v0 ^ (v0 << 4)
        v = t
        addend &+= 362437
        return t &+ addend
    }

    private mutating func nextBits(_ count: Int) -> Int32 {
        let value = UInt32(bitPattern: nextInt()) >> UInt32(32 - count)
        return Int32(bitPattern: value) & (count == 0 ? 0 : -1)
    }

    mutating func nextBoolean() -> Bool { nextBits(1) != 0 }

    /** nextInt(until) for until > 0, as Kotlin's Random.nextInt(from = 0, until). */
    mutating func nextInt(_ until: Int) -> Int {
        let n = Int32(until)
        if n & -n == n {
            let bits = 31 - n.leadingZeroBitCount
            return Int(nextBits(bits))
        }
        var value: Int32
        var bits: Int32
        repeat {
            bits = Int32(bitPattern: UInt32(bitPattern: nextInt()) >> 1)
            value = bits % n
        } while bits &- value &+ (n - 1) < 0
        return Int(value)
    }
}

/**
 * The player's background. Main view, under the full-bleed sleeve: flat — the
 * sleeve's bottom edge carries on just under it, then gives way to that edge's
 * mean colour, which darkens towards the controls; blurred over #121212 with a
 * soft scrim. Lyrics and queue: the whole cover, blurred, under a deeper
 * scrim. Both cross-fade.
 */
struct PlayerBackdrop: View {
    let song: Song?
    let seam: CGFloat
    let panelOpen: Bool

    @State private var mesh: (texture: UIImage, edge: Color)?
    @State private var meshKey: String?

    /** Where the darkening begins (fraction of the seam), how dark it ends, and how far below the seam the edge row lasts. */
    private static let darkenStart: CGFloat = 0.5
    private static let darkenEnd = 0.62
    private static let blendBelowSeam: CGFloat = 0.10

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(hex: 0x121212)
                if let mesh {
                    flat(mesh, height: geometry.size.height)
                        .blur(radius: 32)
                        .id(meshKey)
                        .transition(.opacity.animation(.fastOutSlowIn(0.35)))
                }
                LinearGradient(colors: [.black.opacity(0.06), .black.opacity(0.30)], startPoint: .top, endPoint: .bottom)
                // The panels' blurred cover.
                ZStack {
                    RemoteImage(url: song?.artwork(128)).scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: 40)
                        .clipped()
                    LinearGradient(stops: [.init(color: .black.opacity(0.34), location: 0), .init(color: .black.opacity(0.48), location: 0.55),
                                           .init(color: .black.opacity(0.64), location: 1)], startPoint: .top, endPoint: .bottom)
                }
                .opacity(panelOpen ? 1 : 0)
                .animation(.fastOutSlowIn(0.36), value: panelOpen)
            }
        }
        .ignoresSafeArea()
        .task(id: song?.videoId) { await build() }
    }

    /** The edge colour down the whole screen, the edge row over its top, eased into it, then the dark. */
    private func flat(_ mesh: (texture: UIImage, edge: Color), height: CGFloat) -> some View {
        let seam = max(1, min(seam, height))
        let band = min(height, seam + height * Self.blendBelowSeam)
        let from = min(seam * Self.darkenStart, band)
        return ZStack(alignment: .top) {
            mesh.edge
            // Row 0 (the cover's bottom edge) stretched over the band, each column carrying on from the art.
            Image(uiImage: mesh.texture).resizable().interpolation(.high)
                .frame(height: band * CGFloat(MeshTexture.size))
                .frame(height: band, alignment: .top)
                .clipped()
            Self.easedRamp(mesh.edge, maxOpacity: 1)
                .frame(height: band - from)
                .offset(y: from)
            Self.easedRamp(.black, maxOpacity: Self.darkenEnd)
                .frame(height: height - from)
                .offset(y: from)
        }
        .frame(height: height, alignment: .top)
    }

    /** Clear to [maxOpacity] along a smoothstep, so the ramp has no corner for the eye to find. */
    private static func easedRamp(_ color: Color, maxOpacity: Double) -> LinearGradient {
        LinearGradient(stops: [
            .init(color: color.opacity(0), location: 0),
            .init(color: color.opacity(maxOpacity * 0.156), location: 0.25),
            .init(color: color.opacity(maxOpacity * 0.5), location: 0.5),
            .init(color: color.opacity(maxOpacity * 0.844), location: 0.75),
            .init(color: color.opacity(maxOpacity), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    private func build() async {
        guard let song, let url = song.artwork(cardArtPx), let image = await ImageLoader.shared.image(url) else { return }
        let key = song.thumbnailUrl ?? song.videoId
        let made = await Task.detached(priority: .userInitiated) { MeshTexture.make(image, seedKey: key) }.value
        guard let made, !Task.isCancelled else { return }
        withAnimation(.fastOutSlowIn(0.35)) {
            mesh = made
            meshKey = key
        }
    }
}
