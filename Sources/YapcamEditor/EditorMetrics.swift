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
    /// Quiet neutral behind the preview: a hair darker than the window in light mode, the under-page color in dark mode.
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

/// The one primary action of a view: filled with the accent color in every window state (the system prominent style
/// turns gray in inactive windows), dimmed while pressed or disabled.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.fontWeight(.semibold).foregroundStyle(.white)
            .padding(.horizontal, EditorMetrics.m + 2).padding(.vertical, EditorMetrics.xs + 1)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(!enabled ? 0.4 : configuration.isPressed ? 0.75 : 1)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: theme (own colors; structure follows the reference editor: dark stage, floating inspector card)

enum EditorTheme {
    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    /// Window / stage behind everything.
    static let stage = dynamic(dark: NSColor(srgbRed: 0.055, green: 0.058, blue: 0.075, alpha: 1), light: NSColor(srgbRed: 0.914, green: 0.918, blue: 0.933, alpha: 1))
    /// Floating inspector card and popovers.
    static let card = dynamic(dark: NSColor(srgbRed: 0.086, green: 0.090, blue: 0.118, alpha: 1), light: NSColor(white: 1, alpha: 1))
    /// Fill of option pills and fields inside the card.
    static let control = dynamic(dark: NSColor(white: 1, alpha: 0.07), light: NSColor(white: 0, alpha: 0.06))
    static let hairline = dynamic(dark: NSColor(white: 1, alpha: 0.10), light: NSColor(white: 0, alpha: 0.10))
    static let cardRadius: CGFloat = 14, pillRadius: CGFloat = 9
}

/// Option group as separate rounded pills (selected = filled and outlined), like the reference's background type row.
/// Pills size to their text with equal padding; when the row does not fit it scrolls sideways instead of squeezing the text.
struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(label: String, value: Value)]
    var accessibilityTitle = ""

    private func pill(_ o: (label: String, value: Value), fill: Bool) -> some View {
        let on = o.value == selection
        return Button { selection = o.value } label: {
            Text(o.label).font(.callout).lineLimit(1).fixedSize()
                .padding(.horizontal, EditorMetrics.m + 2).frame(maxWidth: fill ? .infinity : nil, minHeight: 28)
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .background(on ? Color.accentColor.opacity(0.22) : EditorTheme.control, in: RoundedRectangle(cornerRadius: EditorTheme.pillRadius))
                .overlay(RoundedRectangle(cornerRadius: EditorTheme.pillRadius).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 1.5))
                .contentShape(RoundedRectangle(cornerRadius: EditorTheme.pillRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(o.label).accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: EditorMetrics.xs + 2) { ForEach(Array(options.enumerated()), id: \.offset) { _, o in pill(o, fill: true) } }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: EditorMetrics.xs + 2) { ForEach(Array(options.enumerated()), id: \.offset) { _, o in pill(o, fill: false) } }
            }
        }
    }
}

/// "#RRGGBB" / "#RRGGBBAA" ↔ [r, g, b, a] in 0…1.
enum HexColor {
    static func string(_ c: [Double], alpha: Bool) -> String {
        let b = c.prefix(4).map { Int(($0 * 255).rounded().clamped(0, 255)) }
        let base = String(format: "#%02X%02X%02X", b[0], b[1], b[2])
        return alpha ? base + String(format: "%02X", b.count > 3 ? b[3] : 255) : base
    }
    static func parse(_ text: String, keepAlpha: Double) -> [Double]? {
        var t = text.trimmingCharacters(in: .whitespaces); if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6 || t.count == 8, let v = UInt64(t, radix: 16) else { return nil }
        let hasA = t.count == 8
        let r = Double((v >> (hasA ? 24 : 16)) & 255) / 255, g = Double((v >> (hasA ? 16 : 8)) & 255) / 255, b = Double((v >> (hasA ? 8 : 0)) & 255) / 255
        return [r, g, b, hasA ? Double(v & 255) / 255 : keepAlpha]
    }
}
private extension Double { func clamped(_ lo: Double, _ hi: Double) -> Double { min(max(self, lo), hi) } }

/// Title on the left, pill options on the right when they fit, else stacked below (long labels).
struct LabeledPills<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(label: String, value: Value)]
    init(_ title: String, selection: Binding<Value>, options: [(String, Value)]) {
        self.title = title; self._selection = selection; self.options = options.map { (label: $0.0, value: $0.1) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: EditorMetrics.xs + 2) {
            Text(title)
            PillPicker(selection: $selection, options: options, accessibilityTitle: title)
        }
        .padding(.vertical, EditorMetrics.xs)
    }
}
