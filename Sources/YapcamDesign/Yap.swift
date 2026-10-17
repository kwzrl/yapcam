import AppKit
import SwiftUI

/// Yapcam's design tokens, after the visionOS "Jupiter" panel: one tinted glass material, hierarchy through
/// brightness only, no accent colour for state. Colour comes from content (recordings, timeline items),
/// yellow only marks technical text (timecodes, sizes, values), red only marks recording.
public enum Yap {
    // Text: white at falling opacity.
    public static let title = Color.white
    public static let label = Color.white.opacity(0.9)
    public static let body = Color.white.opacity(0.6)
    public static let caption = Color.white.opacity(0.55)
    public static let faint = Color.white.opacity(0.32)

    // Brightness steps on glass.
    public static let platter = Color.white.opacity(0.08)       // selected
    public static let platterHover = Color.white.opacity(0.05)  // looked at / hovered
    public static let hairline = Color.white.opacity(0.10)
    public static let recess = Color.black.opacity(0.45)        // passive: grooves, tracks

    // The only colours chrome may use.
    public static let technical = Color(red: 0xfa / 255, green: 0xd5 / 255, blue: 0x2a / 255)   // #fad52a
    public static let record = Color(red: 1.0, green: 0.27, blue: 0.23)

    // Content colours (timeline items).
    public static let clipTop = Color(red: 0xfa / 255, green: 0xd5 / 255, blue: 0x2a / 255)
    public static let clipBottom = Color(red: 0.96, green: 0.66, blue: 0.10)
    public static let zoom = Color(red: 0.55, green: 0.45, blue: 1.0)
    public static let zoomAuto = Color(red: 0.42, green: 0.58, blue: 1.0)

    /// Ground of opaque windows (editor) and the dark end of the glass tint.
    public static let ground = Color(red: 0.075, green: 0.072, blue: 0.07)
    public static let nsGround = NSColor(srgbRed: 0.075, green: 0.072, blue: 0.07, alpha: 1)

    public enum Radius {
        public static let control: CGFloat = 10
        public static let card: CGFloat = 16
        public static let panel: CGFloat = 26
    }

    /// Radius of an element inset by `inset` inside a container of `outer` radius, so corners stay concentric.
    public static func concentric(_ outer: CGFloat, inset: CGFloat) -> CGFloat { max(outer - inset, 0) }

    public enum Font {
        public static func title(_ size: CGFloat = 22) -> SwiftUI.Font { .system(size: size, weight: .bold).width(.standard) }
        public static let label = SwiftUI.Font.system(size: 13, weight: .medium)
        public static let body = SwiftUI.Font.system(size: 13)
        public static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
        /// Technical values: monospaced digits, shown in `Yap.technical`.
        public static let technical = SwiftUI.Font.system(size: 12, weight: .medium).monospacedDigit()
    }
}

/// Live-tunable glass parameters (the design lab edits `shared`; every glass surface reads it).
@MainActor @Observable public final class GlassTuning {
    public static let shared = GlassTuning()
    /// How much of the blurred backdrop shows through (0 = opaque ground, 1 = bare system material).
    public var clarity: Double = 1.0
    /// Brightness lift of the tint at the top edge and the bottom edge ("lit from above and below").
    public var topLight: Double = 0.20
    public var bottomLight: Double = 0.16
    /// Strength of the rim light along the top edge; the rest of the edge gets a quarter of it.
    public var rim: Double = 0.21
    /// Warm ambient glow from the lower left, like light from the scene behind.
    public var warmth: Double = 0.0
    /// Atmospheric shadow under floating panels.
    public var shadow: Double = 0.65
    public init() {}

    public func reset() {
        let d = GlassTuning()
        clarity = d.clarity; topLight = d.topLight; bottomLight = d.bottomLight
        rim = d.rim; warmth = d.warmth; shadow = d.shadow
    }
}

public extension Text {
    /// Technical value styling: monospaced digits in yellow.
    func technical() -> some View { font(Yap.Font.technical).foregroundStyle(Yap.technical) }
}
