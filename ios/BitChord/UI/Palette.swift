import SwiftUI
import UIKit

/** Colours in HSL, the space ArtworkPalette.kt does its clamping in. */
struct HSL: Sendable {
    var h: Double
    var s: Double
    var l: Double

    init(h: Double, s: Double, l: Double) {
        self.h = h
        self.s = s
        self.l = l
    }

    init(r: Double, g: Double, b: Double) {
        let maxV = max(r, g, b), minV = min(r, g, b)
        let delta = maxV - minV
        l = (maxV + minV) / 2
        s = delta == 0 ? 0 : delta / (1 - abs(2 * l - 1))
        if delta == 0 {
            h = 0
        } else if maxV == r {
            h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxV == g {
            h = 60 * ((b - r) / delta + 2)
        } else {
            h = 60 * ((r - g) / delta + 4)
        }
        if h < 0 { h += 360 }
    }

    var rgb: (Double, Double, Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }

    var color: Color {
        let (r, g, b) = rgb
        return Color(.sRGB, red: r, green: g, blue: b)
    }

    /** Saturation clamped to [range] — unless the source is near grey (S < 0.12), which keeps its own. */
    func with(l newL: Double, s range: ClosedRange<Double>) -> HSL {
        HSL(h: h, s: s < 0.12 ? s : min(max(s, range.lowerBound), range.upperBound), l: newL)
    }
}

/** A page's colours from its cover (ArtworkPalette.kt, dark theme). */
struct ArtworkPalette: Equatable, Sendable {
    var background: Color
    var wash: Color
    var elevated: Color
    var accent: Color
    var onBackgroundVariant: Color
    /** The pale player tint: L 0.88, or white when the cover has no colour. */
    var tint: Color

    static let neutral = ArtworkPalette(background: Color(hex: 0x121212), wash: Color(hex: 0x1A1A1A), elevated: Color(hex: 0x2A2A2A),
                                        accent: Theme.playingAccent, onBackgroundVariant: Color(white: 0.8), tint: .white)

    static func from(_ image: UIImage) -> ArtworkPalette? {
        guard let sample = PixelSample(image, size: 128) else { return nil }
        let swatches = Quantizer.swatches(sample.pixels, maxColors: 24)
        guard let dominant = swatches.max(by: { $0.population < $1.population }) else { return nil }
        let filtered = swatches.filter(\.passesDefaultFilter)
        let vibrant = filtered.max { $0.hsl.s * Double($0.population).squareRoot() < $1.hsl.s * Double($1.population).squareRoot() } ?? dominant
        let edge = sample.edgeMean(fraction: 0.18)

        return from(dominant: dominant.rgb, vibrant: vibrant.rgb, edge: edge)
    }

    /** A page whose source already supplied its colours (Apple's artist art): background as dominant and edge, accent as vibrant. */
    static func from(background: Int, accent: Int) -> ArtworkPalette {
        func rgb(_ hex: Int) -> (Double, Double, Double) {
            (Double(hex >> 16 & 0xFF) / 255, Double(hex >> 8 & 0xFF) / 255, Double(hex & 0xFF) / 255)
        }
        let edge = rgb(background)
        return from(dominant: edge, vibrant: rgb(accent), edge: HSL(r: edge.0, g: edge.1, b: edge.2))
    }

    private static func from(dominant: (Double, Double, Double), vibrant: (Double, Double, Double), edge: HSL) -> ArtworkPalette {
        let d = HSL(r: dominant.0, g: dominant.1, b: dominant.2), v = HSL(r: vibrant.0, g: vibrant.1, b: vibrant.2)
        func chroma(_ c: (Double, Double, Double)) -> Double { max(c.0, c.1, c.2) - min(c.0, c.1, c.2) }
        let tintSource = [d, v].enumerated().first { chroma($0.offset == 0 ? dominant : vibrant) >= 0.08 }?.element
        let tint = tintSource.map { $0.with(l: 0.88, s: 0.18...0.40).color } ?? .white
        return ArtworkPalette(
            background: d.with(l: 0.13, s: 0.20...0.62).color,
            wash: edge.with(l: min(max(edge.l, 0.14), 0.24), s: 0.18...0.58).color,
            elevated: d.with(l: 0.22, s: 0.20...0.62).color,
            accent: v.with(l: min(max(v.l, 0.62), 0.78), s: 0.55...1).color,
            onBackgroundVariant: d.with(l: 0.80, s: 0.22...0.50).color,
            tint: tint
        )
    }
}

/** An image's pixels at a small size, row 0 at the top. */
struct PixelSample {
    let width: Int
    let height: Int
    let pixels: [(Double, Double, Double)]

    init?(_ image: UIImage, size: Int) {
        guard let cg = image.cgImage else { return nil }
        let scale = Double(size) / Double(max(cg.width, cg.height))
        width = max(1, Int(Double(cg.width) * scale))
        height = max(1, Int(Double(cg.height) * scale))
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var out: [(Double, Double, Double)] = []
        out.reserveCapacity(width * height)
        for i in stride(from: 0, to: buffer.count, by: 4) {
            out.append((Double(buffer[i]) / 255, Double(buffer[i + 1]) / 255, Double(buffer[i + 2]) / 255))
        }
        pixels = out
    }

    /** The mean colour of the bottom [fraction] of the image. */
    func edgeMean(fraction: Double) -> HSL {
        let startRow = Int(Double(height) * (1 - fraction))
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for y in startRow..<height {
            for x in 0..<width {
                let p = pixels[y * width + x]
                r += p.0; g += p.1; b += p.2; n += 1
            }
        }
        return n > 0 ? HSL(r: r / n, g: g / n, b: b / n) : HSL(h: 0, s: 0, l: 0.2)
    }
}

/** A modified median cut over 5-bit colour, as androidx Palette's quantizer does. */
enum Quantizer {
    struct Swatch {
        let rgb: (Double, Double, Double)
        let population: Int

        var hsl: HSL { HSL(r: rgb.0, g: rgb.1, b: rgb.2) }
        var chroma: Double { max(rgb.0, rgb.1, rgb.2) - min(rgb.0, rgb.1, rgb.2) }

        /** Palette's default filter: not near black, not near white, not the skin-tone band. */
        var passesDefaultFilter: Bool {
            let c = hsl
            if c.l <= 0.05 || c.l >= 0.95 { return false }
            if c.h >= 10, c.h <= 37, c.s <= 0.82 { return false }
            return true
        }
    }

    static func swatches(_ pixels: [(Double, Double, Double)], maxColors: Int) -> [Swatch] {
        var histogram: [Int: Int] = [:]
        for p in pixels {
            let key = Int(p.0 * 31) << 10 | Int(p.1 * 31) << 5 | Int(p.2 * 31)
            histogram[key, default: 0] += 1
        }
        let colors = histogram.map { (key: $0.key, count: $0.value) }
        if colors.count <= maxColors {
            return colors.map { Swatch(rgb: unpack($0.key), population: $0.count) }
        }
        var boxes: [[(key: Int, count: Int)]] = [colors]
        while boxes.count < maxColors {
            // Split the box with the most volume × population along its longest axis.
            guard let index = boxes.indices.filter({ boxes[$0].count > 1 }).max(by: { weight(boxes[$0]) < weight(boxes[$1]) }) else { break }
            let box = boxes.remove(at: index)
            let axis = longestAxis(box)
            let sorted = box.sorted { component($0.key, axis) < component($1.key, axis) }
            let total = sorted.reduce(0) { $0 + $1.count }
            var running = 0
            var split = 1
            for (i, entry) in sorted.enumerated() {
                running += entry.count
                if running >= total / 2 {
                    split = max(1, min(sorted.count - 1, i + 1))
                    break
                }
            }
            boxes.append(Array(sorted[..<split]))
            boxes.append(Array(sorted[split...]))
        }
        return boxes.map { box in
            let total = box.reduce(0) { $0 + $1.count }
            var r = 0.0, g = 0.0, b = 0.0
            for entry in box {
                let c = unpack(entry.key)
                r += c.0 * Double(entry.count); g += c.1 * Double(entry.count); b += c.2 * Double(entry.count)
            }
            return Swatch(rgb: (r / Double(total), g / Double(total), b / Double(total)), population: total)
        }
    }

    private static func unpack(_ key: Int) -> (Double, Double, Double) {
        (Double(key >> 10 & 31) / 31, Double(key >> 5 & 31) / 31, Double(key & 31) / 31)
    }

    private static func component(_ key: Int, _ axis: Int) -> Int { key >> (10 - axis * 5) & 31 }

    private static func longestAxis(_ box: [(key: Int, count: Int)]) -> Int {
        (0..<3).max { a, b in range(box, a) < range(box, b) } ?? 0
    }

    private static func range(_ box: [(key: Int, count: Int)], _ axis: Int) -> Int {
        let values = box.map { component($0.key, axis) }
        return (values.max() ?? 0) - (values.min() ?? 0)
    }

    private static func weight(_ box: [(key: Int, count: Int)]) -> Int {
        let volume = (0..<3).reduce(1) { $0 * (range(box, $1) + 1) }
        return volume * box.reduce(0) { $0 + $1.count }
    }
}

/** Loads a cover's palette once and remembers it, so revisiting a page doesn't fade again. */
@MainActor
final class PaletteCache {
    static let shared = PaletteCache()
    private var cache: [URL: ArtworkPalette] = [:]

    func cached(_ url: URL?) -> ArtworkPalette? { url.flatMap { cache[$0] } }

    func palette(_ url: URL?) async -> ArtworkPalette? {
        guard let url else { return nil }
        if let hit = cache[url] { return hit }
        guard let image = await ImageLoader.shared.image(url) else { return nil }
        let palette = await Task.detached(priority: .userInitiated) { ArtworkPalette.from(image) }.value
        if let palette { cache[url] = palette }
        return palette
    }
}
