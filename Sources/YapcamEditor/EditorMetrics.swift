import AppKit
import SwiftUI
import YapcamDesign

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
    /// Behind the preview: the stage ground (dark only).
    static let previewSurround = Yap.nsGround
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

/// The one primary action of a view: the white capsule of the kit (the brightest thing on screen, dark label),
/// the same in every window state, dimmed while pressed or disabled. Never the system accent.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { CapsuleButtonStyle(.primary, height: 28).makeBody(configuration: configuration) }
}

// MARK: theme (Yap tokens: neutral, a breath cool, dark only; no accent colour)

/// The editor's surfaces, mapped onto the Yap tokens of the approved docked design. Kept as names so section files
/// keep compiling while they move to the kit; nothing here is warm or blue.
enum EditorTheme {
    /// Stage behind the preview (`Yap.ground`, #1C1C1E).
    static let stage = Yap.ground
    /// Docked columns: inspector, chat, timeline, title row (`Yap.dock`, #242426). No longer a floating card.
    static let card = Yap.dock
    /// Fill of option pills and fields on a docked column.
    static let control = Color.white.opacity(0.07)
    /// Selected pill or field: brightness, not colour.
    static let controlSelected = Color.white.opacity(0.24)
    static let hairline = Color.white.opacity(Yap.dockHairline)
    /// Docked surfaces have no corners.
    static let cardRadius: CGFloat = 0, pillRadius: CGFloat = Yap.Radius.control
}

/// Option group as separate rounded pills (selected = brighter fill), like the reference's background type row.
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
                .background(on ? EditorTheme.controlSelected : EditorTheme.control, in: RoundedRectangle(cornerRadius: EditorTheme.pillRadius))
                .contentShape(RoundedRectangle(cornerRadius: EditorTheme.pillRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(o.label).accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: EditorMetrics.xs + 2) { ForEach(Array(options.enumerated()), id: \.offset) { _, o in pill(o, fill: true) } }
            ScrollingPills(options: options.map(\.value), selected: selection) { index in pill(options[index], fill: false) }
        }
    }
}

/// The row that does not fit: scrolls sideways, brings the selected pill into view, and fades the edge where more pills continue.
struct ScrollingPills<Value: Hashable, Pill: View>: View {
    let options: [Value]
    let selected: Value
    let pill: (Int) -> Pill
    @State private var offset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    init(options: [Value], selected: Value, @ViewBuilder pill: @escaping (Int) -> Pill) { self.options = options; self.selected = selected; self.pill = pill }
    private let fade: CGFloat = 22
    /// Which edges have more pills beyond them: (leading, trailing). `offset` is where the content starts inside the viewport.
    static func edgesWithMore(offset: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat) -> (leading: Bool, trailing: Bool) {
        (offset < -1, contentWidth + offset > viewportWidth + 1)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: EditorMetrics.xs + 2) {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, _ in pill(i).id(i) }
                }
                .background(GeometryReader { g in
                    let f = g.frame(in: .named("pills"))
                    Color.clear
                        .onAppear { offset = f.minX; contentWidth = f.width }
                        .onChange(of: f.minX) { _, v in offset = v }
                        .onChange(of: f.width) { _, w in contentWidth = w }
                })
            }
            .coordinateSpace(name: "pills")
            .background(GeometryReader { g in Color.clear.onAppear { viewportWidth = g.size.width }.onChange(of: g.size.width) { _, w in viewportWidth = w } })
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(Self.edgesWithMore(offset: offset, contentWidth: contentWidth, viewportWidth: viewportWidth).leading ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing).frame(width: fade)
                    Rectangle().fill(.black)
                    LinearGradient(colors: [.black, .black.opacity(Self.edgesWithMore(offset: offset, contentWidth: contentWidth, viewportWidth: viewportWidth).trailing ? 0 : 1)], startPoint: .leading, endPoint: .trailing).frame(width: fade)
                }
            )
            .onAppear { if let i = options.firstIndex(of: selected) { proxy.scrollTo(i, anchor: nil) } }
            .onChange(of: selected) { _, new in if let i = options.firstIndex(of: new) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(i, anchor: nil) } } }
        }
        .frame(height: 30)
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
