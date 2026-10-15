import AppKit
import SwiftUI

/// Surface for floating panels: translucent material normally, solid when the user turned on
/// Reduce Transparency; stronger outline with Increase Contrast.
struct PanelSurface: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if reduceTransparency { shape.fill(Color(nsColor: .windowBackgroundColor)) }
                else { shape.fill(.regularMaterial) }
            }
            .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.6 : 0.12), lineWidth: contrast == .increased ? 1.5 : 1))
    }
}

extension View {
    func panelSurface(cornerRadius: CGFloat = 14) -> some View { modifier(PanelSurface(cornerRadius: cornerRadius)) }
}

/// Opacity helpers that respect Increase Contrast.
struct ContrastOpacity {
    let increased: Bool
    var hoverFill: Double { increased ? 0.2 : 0.08 }
    var activeFill: Double { increased ? 0.32 : 0.14 }
    var subtleFill: Double { increased ? 0.14 : 0.06 }
    var outline: Double { increased ? 0.55 : 0.15 }
}

extension EnvironmentValues {
    var contrastOpacity: ContrastOpacity { ContrastOpacity(increased: colorSchemeContrast == .increased) }
}

/// Spoken announcements for state changes that happen without focus (recording started, paused…).
@MainActor enum Announcer {
    static func say(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    static func timeDescription(_ t: TimeInterval) -> String {
        let s = Int(t), h = s / 3600, m = (s / 60) % 60, sec = s % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) hour\(h == 1 ? "" : "s")") }
        if m > 0 { parts.append("\(m) minute\(m == 1 ? "" : "s")") }
        if sec > 0 || parts.isEmpty { parts.append("\(sec) second\(sec == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }
}
