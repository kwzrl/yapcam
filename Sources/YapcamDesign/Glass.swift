import AppKit
import SwiftUI

/// System blur of whatever lies behind the window (or behind the view, inside a window).
public struct BackdropBlur: NSViewRepresentable {
    public var behindWindow = true
    public init(behindWindow: Bool = true) { self.behindWindow = behindWindow }
    public func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = behindWindow ? .behindWindow : .withinWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    public func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.blendingMode = behindWindow ? .behindWindow : .withinWindow
    }
}

/// One glass layer: blurred backdrop, warm-grey tint lit from top and bottom, rim light on the edge.
/// No border, no stacked effects.
public struct GlassSurface: View {
    var radius: CGFloat
    var floating: Bool
    var behindWindow: Bool
    /// Extra brightness for glass that sits in front of other glass (menus over panels).
    var lift: Double
    @State private var t = GlassTuning.shared

    public init(radius: CGFloat, floating: Bool = true, behindWindow: Bool = true, lift: Double = 0) {
        self.radius = radius; self.floating = floating; self.behindWindow = behindWindow; self.lift = lift
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let body = t.body + lift
        ZStack {
            // Strong blur of what lies behind; only its light comes through.
            BackdropBlur(behindWindow: behindWindow)
            // Warm-grey glass, lit from above, darker in the middle, light returning at the bottom.
            LinearGradient(stops: [
                .init(color: Color(red: 120 / 255, green: 120 / 255, blue: 125 / 255).opacity(body + t.topLight), location: 0),
                .init(color: Color(red: 70 / 255, green: 70 / 255, blue: 75 / 255).opacity(body), location: 0.55),
                .init(color: Color(red: 92 / 255, green: 92 / 255, blue: 97 / 255).opacity(body + t.bottomLight), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            // Ambient light of the scene, from the lower left.
            RadialGradient(colors: [Color(red: 1, green: 140 / 255, blue: 60 / 255).opacity(t.warmth), .clear],
                           center: UnitPoint(x: 0.3, y: 1.1), startRadius: 0, endRadius: 360)
        }
        .clipShape(shape)
        // Rim light, strongest on top, plus a barely-there edge. No grey line.
        .overlay(shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(t.rim), location: 0),
                                                           .init(color: .white.opacity(0.06), location: 0.35),
                                                           .init(color: .white.opacity(0.06), location: 1)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .compositingGroup()
        .shadow(color: .black.opacity(floating ? t.shadow : 0), radius: 40, y: 20)
    }
}

public extension View {
    /// Places the view on a glass panel. `behindWindow` blurs the desktop (floating panels); false blurs
    /// window content (sheets, popovers inside the editor).
    func glassPanel(radius: CGFloat = Yap.Radius.panel, floating: Bool = true, behindWindow: Bool = true, lift: Double = 0) -> some View {
        background(GlassSurface(radius: radius, floating: floating, behindWindow: behindWindow, lift: lift))
    }

    /// Dark-only window content with Yapcam's neutral tint (no accent colour for controls).
    func yapWindow() -> some View {
        environment(\.colorScheme, .dark).tint(Color.white)
    }
}

public extension NSWindow {
    /// Opaque dark window chrome for document windows (editor, settings).
    func applyYapChrome() {
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = Yap.nsGround
        titlebarAppearsTransparent = true
    }

    /// Fully transparent window whose SwiftUI content draws its own glass.
    func makeGlassHost() {
        appearance = NSAppearance(named: .darkAqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
    }
}
