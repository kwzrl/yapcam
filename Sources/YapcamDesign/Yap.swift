import AppKit
import SwiftUI

/// Yapcam's design tokens. Black ground, white text in three steps, one warm accent used sparingly
/// (active state, selection, primary action). Everything else is hairlines and spacing.
public enum Yap {
    // Ground and surfaces, darkest first.
    public static let bg = Color.black
    public static let surface = Color(white: 0.055)
    public static let raised = Color(white: 0.10)
    public static let hairline = Color.white.opacity(0.08)
    public static let hairlineStrong = Color.white.opacity(0.16)

    // Text.
    public static let text = Color.white
    public static let textSecondary = Color.white.opacity(0.56)
    public static let textTertiary = Color.white.opacity(0.32)

    // Accent (#fad52a, same as the website and icon) and what sits on it.
    public static let accent = Color(red: 0xfa / 255, green: 0xd5 / 255, blue: 0x2a / 255)
    public static let onAccent = Color.black
    public static let amber = Color(red: 0.96, green: 0.66, blue: 0.10)
    public static let violet = Color(red: 0.55, green: 0.45, blue: 1.0)
    public static let violetSoft = Color(red: 0.42, green: 0.58, blue: 1.0)
    public static let record = Color(red: 1.0, green: 0.27, blue: 0.23)
    public static let warning = Color(red: 1.0, green: 0.72, blue: 0.30)

    public static let nsBg = NSColor.black
    public static let nsAccent = NSColor(srgbRed: 0xfa / 255, green: 0xd5 / 255, blue: 0x2a / 255, alpha: 1)

    public enum Radius {
        public static let control: CGFloat = 8
        public static let card: CGFloat = 12
        public static let panel: CGFloat = 18
    }
}

public extension View {
    /// Root of every Yapcam window: dark, accent tint, black ground.
    func yapWindow() -> some View {
        environment(\.colorScheme, .dark).tint(Yap.accent).background(Yap.bg)
    }

    /// Grouped forms on black instead of the system gray.
    func yapForm() -> some View {
        formStyle(.grouped).scrollContentBackground(.hidden).background(Yap.bg)
    }
}

public extension NSWindow {
    /// Black window chrome that matches `yapWindow()`.
    func applyYapChrome() {
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = Yap.nsBg
        titlebarAppearsTransparent = true
    }
}
