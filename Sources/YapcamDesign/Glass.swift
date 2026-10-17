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
        ZStack {
            BackdropBlur(behindWindow: behindWindow)
            Yap.glassGray.opacity(1 - t.clarity)
            LinearGradient(stops: [
                .init(color: .white.opacity(t.topLight + lift), location: 0),
                .init(color: .white.opacity(lift * 0.6), location: 0.45),
                .init(color: .white.opacity(t.bottomLight + lift * 0.6), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 1, green: 0.55, blue: 0.24).opacity(t.warmth), .clear],
                           center: UnitPoint(x: 0.25, y: 1.1), startRadius: 0, endRadius: 420)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(t.rim), .white.opacity(t.rim * 0.25), .white.opacity(t.rim * 0.4)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .compositingGroup()
        .shadow(color: .black.opacity(floating ? t.shadow : 0), radius: 30, y: 16)
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
