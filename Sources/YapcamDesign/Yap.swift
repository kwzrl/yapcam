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

    /// Body of the glass: a neutral grey that is almost opaque (user preferred it over see-through glass).
    public static let glassGray = Color(white: 0.21)

    /// Ground of opaque windows (the editor's stage): neutral, a breath cool like the toolbar glass, never warm
    /// (#1C1C1E; tuned in the lab with `ToneTuning`).
    public static let ground = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    public static let nsGround = NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
    /// Docked columns of a document window (inspector, chat, timeline, title row): a step above the ground, so the
    /// stage in the middle reads as the darkest, calmest place. Separated from it by a plain hairline only (#242426).
    public static let dock = Color(red: 36 / 255, green: 36 / 255, blue: 38 / 255)
    /// Hairlines between docked columns: fainter than on glass.
    public static let dockHairline = 0.09

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
    /// Opacity of the warm-grey glass body over the blur (tuned in the lab 2026-10-17).
    public var body: Double = 0.19
    /// Extra opacity of the body's light at the top edge and at the bottom edge.
    public var topLight: Double = 0.01
    public var bottomLight: Double = 0.02
    /// Rim light along the top edge.
    public var rim: Double = 0.29
    /// Warm ambient glow from the lower left (light of the scene behind).
    public var warmth: Double = 0.0
    /// Atmospheric shadow under floating panels.
    public var shadow: Double = 0.57
    /// Specular sheen on surfaces that opt in (`glassPanel(sheen: true)`).
    public var sheen: Double = 0.09
    public init() {}

    public func reset() {
        let d = GlassTuning()
        body = d.body; topLight = d.topLight; bottomLight = d.bottomLight
        rim = d.rim; warmth = d.warmth; shadow = d.shadow; sheen = d.sheen
    }
}

/// Live-tunable tones of opaque windows (the design lab edits `shared`; the lab's editor reads it). Grey levels with
/// red = green and blue `cool` above, so nothing turns brown. Defaults equal `Yap.ground`, `Yap.dock`, `Yap.dockHairline`.
@MainActor @Observable public final class ToneTuning {
    public static let shared = ToneTuning()
    /// Grey level of the stage, 0…1.
    public var stage: Double = 28 / 255
    /// Grey level of docked columns and the title row, 0…1.
    public var dock: Double = 36 / 255
    /// White opacity of the hairlines between them.
    public var hairline: Double = Yap.dockHairline
    /// How much more blue than red and green (0 = neutral grey).
    public var cool: Double = 2 / 255
    public init() {}

    public var stageColor: Color { grey(stage) }
    public var dockColor: Color { grey(dock) }
    public func grey(_ level: Double) -> Color { Color(red: level, green: level, blue: min(level + cool, 1)) }

    public func hex(_ level: Double) -> String {
        let v = Int((level * 255).rounded()), b = Int((min(level + cool, 1) * 255).rounded())
        return String(format: "#%02X%02X%02X", v, v, b)
    }

    public func reset() {
        let d = ToneTuning()
        stage = d.stage; dock = d.dock; hairline = d.hairline; cool = d.cool
    }
}

public extension Text {
    /// Technical value styling: monospaced digits in yellow.
    func technical() -> some View { font(Yap.Font.technical).foregroundStyle(Yap.technical) }
}
