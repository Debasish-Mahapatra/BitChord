import SwiftUI
import UIKit

/**
 * The phone's Material scheme (ui/theme/Theme.kt), dark by default: a black
 * page, near-black surfaces, iOS-grey secondary text and a monochrome accent.
 */
enum Theme {
    static let background = dynamic(dark: 0x000000, light: 0xFFFFFF)
    static let onBackground = dynamic(dark: 0xFFFFFF, light: 0x000000)
    static let surface = dynamic(dark: 0x0D0D0F, light: 0xF7F7F9)
    static let onSurface = dynamic(dark: 0xFFFFFF, light: 0x000000)
    static let surfaceVariant = dynamic(dark: 0x1C1C1E, light: 0xF2F2F7)
    static let onSurfaceVariant = dynamic(dark: 0x8E8E93, light: 0x6E6E73)
    static let outline = dynamic(dark: 0x2C2C2E, light: 0xE5E5EA)
    static let primary = dynamic(dark: 0xFFFFFF, light: 0x000000)
    static let onPrimary = dynamic(dark: 0x000000, light: 0xFFFFFF)
    static let surfaceContainerHigh = dynamic(dark: 0x2B2930, light: 0xECE6F0)
    /** The current song's title on cards and rows. */
    static let playingAccent = Color(hex: 0xFB4A62)
    static let accentRed = Color(hex: 0xFA2D48)
    /** The 1pt rim on every artwork: white or black at 15%. */
    static let thumbnailBorder = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.15) : UIColor.black.withAlphaComponent(0.15) })
    /** Glass rims: white at 10%. */
    static let glassBorder = Color.white.opacity(0.10)

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .light ? UIColor(hex: light) : UIColor(hex: dark) })
    }
}

/** Common.kt's layout constants. */
enum Metrics {
    static let gutter: CGFloat = 16
    static let rowDividerInset: CGFloat = 84
    static let numberedRowDividerInset: CGFloat = 56
    static let trackNumberWidth: CGFloat = 24
    static let shelfCardWidth: CGFloat = 150
    static let gridSpacing: CGFloat = 12
    /** The 52pt top bar below the status bar. */
    static let topBarHeight: CGFloat = 52
    /** List top padding below the status bar: the bar plus a 12pt gap. */
    static let contentTop: CGFloat = topBarHeight + 12
    static func contentBottom(hasSong: Bool) -> CGFloat { hasSong ? 210 : 140 }
}

/** The type scale (Theme.kt): SF Pro Display at every size, as the phone bundles it. */
enum TextStyle {
    case displayLarge, headlineLarge, headlineMedium, titleLarge, titleMedium, titleSmall
    case bodyLarge, bodyMedium, labelLarge, labelMedium, labelSmall

    var size: CGFloat {
        switch self {
        case .displayLarge: return 34
        case .headlineLarge: return 30
        case .headlineMedium: return 22
        case .titleLarge: return 20
        case .titleMedium, .bodyLarge: return 16
        case .titleSmall, .bodyMedium, .labelLarge: return 14
        case .labelMedium: return 12
        case .labelSmall: return 11
        }
    }

    var weight: Font.Weight {
        switch self {
        case .displayLarge, .headlineLarge: return .heavy
        case .headlineMedium, .titleLarge: return .bold
        case .titleMedium, .labelMedium, .labelSmall: return .semibold
        case .titleSmall, .labelLarge: return .medium
        case .bodyLarge, .bodyMedium: return .regular
        }
    }

    var tracking: CGFloat {
        switch self {
        case .displayLarge: return -0.8
        case .headlineLarge: return -0.7
        case .headlineMedium: return -0.4
        case .titleLarge: return -0.3
        case .titleMedium: return -0.2
        case .titleSmall, .labelLarge: return 0.1
        default: return 0
        }
    }

    var font: Font { .sfDisplay(size, weight) }
}

extension Font {
    /** SF Pro Display at [size], from the bundled faces (W400–W800). */
    static func sfDisplay(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .medium: name = "SFProDisplay-Medium"
        case .semibold: name = "SFProDisplay-Semibold"
        case .bold: name = "SFProDisplay-Bold"
        case .heavy, .black: name = "SFProDisplay-Heavy"
        default: name = "SFProDisplay-Regular"
        }
        return .custom(name, size: size)
    }
}

extension View {
    func textStyle(_ style: TextStyle, weight: Font.Weight? = nil, size: CGFloat? = nil) -> some View {
        font(.sfDisplay(size ?? style.size, weight ?? style.weight)).tracking(style.tracking)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/** Compose springs (mass 1) as SwiftUI ones: damping = 2ζ√k. */
extension Animation {
    static func compose(dampingRatio: Double, stiffness: Double) -> Animation {
        .interpolatingSpring(mass: 1, stiffness: stiffness, damping: 2 * dampingRatio * stiffness.squareRoot())
    }

    /** FastOutSlowIn, cubic-bezier(0.4, 0, 0.2, 1). */
    static func fastOutSlowIn(_ seconds: Double) -> Animation {
        .timingCurve(0.4, 0, 0.2, 1, duration: seconds)
    }
}

/** Haze `regular` / `thin` over `surface` with a 0.5pt rim — the frosted chrome. */
struct FrostedBackground<S: Shape>: View {
    var shape: S
    var thin = false

    var body: some View {
        if AppSettings.shared.reduceDynamicBlur {
            // "Reduce dynamic blur": solid fills for frosted glass.
            shape
                .fill(Theme.surface)
                .overlay(shape.stroke(Theme.glassBorder, lineWidth: 0.5))
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(Theme.surface.opacity(thin ? 0.65 : 0.80)))
                .overlay(shape.stroke(Theme.glassBorder, lineWidth: 0.5))
        }
    }
}
