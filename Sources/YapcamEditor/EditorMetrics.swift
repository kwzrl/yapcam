import AppKit
import SwiftUI

/// One spacing scale and the shared geometry of inspector rows, so every slider row lines up.
enum EditorMetrics {
    /// Spacing scale: 4 / 8 / 12 / 16 / 24.
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24
    /// Width of the right-aligned value label next to a slider ("48 pt", "0.30", "1.5 s").
    static let valueWidth: CGFloat = 62
    /// Room kept for the "reset to default" button, even when a row has none, so slider tracks have equal length.
    static let resetSlot: CGFloat = 16
}

extension View {
    /// Right-aligned, tabular-digit value label of a slider row.
    func sliderValueLabel() -> some View {
        monospacedDigit().foregroundStyle(.secondary).frame(width: EditorMetrics.valueWidth, alignment: .trailing).accessibilityHidden(true)
    }
}

extension NSColor {
    /// Quiet neutral behind the preview: a hair darker than the window in light mode, the under-page colour in dark mode.
    static let previewSurround = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .underPageBackgroundColor : NSColor(white: 0.93, alpha: 1)
    }
}

/// Label column + control that fills the rest of the row (sliders get the full remaining width in every panel).
struct SliderRow<Content: View>: View {
    static var labelWidth: CGFloat { 104 }
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        HStack(spacing: EditorMetrics.s) {
            Text(title).lineLimit(2).fixedSize(horizontal: false, vertical: true).frame(width: Self.labelWidth, alignment: .leading)
            // Inside a Form a control with a hidden-less empty label gets a leading label column of its own (it squeezed every
            // slider track to ~47 pt, right-aligned); hiding the label lets the track fill the remaining width.
            content.labelsHidden().frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The one primary action of a view: filled with the accent colour in every window state (the system prominent style
/// turns grey in inactive windows), dimmed while pressed or disabled.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.fontWeight(.semibold).foregroundStyle(.white)
            .padding(.horizontal, EditorMetrics.m + 2).padding(.vertical, EditorMetrics.xs + 1)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(!enabled ? 0.4 : configuration.isPressed ? 0.75 : 1)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
