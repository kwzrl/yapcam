import AppKit
import SwiftUI

// Inspector parts the kit did not have yet (ae-inspector, 2026-10-17): a value slider that reports editing, so the
// editor commits on release (one undo step), with a reset slot; a colour row with editable hex, alpha and eyedropper;
// group, note, info and list rows; a small icon button; a selectable tile and a multi-line recessed field.

// MARK: - Layout

public extension Yap {
    /// Fixed columns of inspector rows, so the sliders of a section line up.
    enum Inspector {
        public static let rail: CGFloat = Yap.Grid.bar
        public static let column: CGFloat = 300
        /// Rail, hairline and content column: the width of the docked inspector.
        public static let width: CGFloat = rail + column
        public static let gutter: CGFloat = 12
        public static let slider: CGFloat = 92
        public static let readout: CGFloat = 44
        public static let resetSlot: CGFloat = 14
        /// Gap between the columns of a slider row.
        public static let gap: CGFloat = 6
        public static let rowHeight: CGFloat = 26
    }
}

// MARK: - Slider

/// A parameter in one row: label left, pill slider, value in yellow and a reset slot right, in fixed columns. When the
/// label is too long the slider moves under it. `amount` is 0…1; `onEditingChanged(false)` marks the end of a drag.
public struct InspectorSlider: View {
    let title: String
    let value: String
    @Binding var amount: Double
    var changed: Bool
    var reset: (() -> Void)?
    var onEditingChanged: (Bool) -> Void

    public init(_ title: String, value: String, amount: Binding<Double>, changed: Bool = false, reset: (() -> Void)? = nil,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title; self.value = value; _amount = amount; self.changed = changed; self.reset = reset
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Yap.Inspector.gap) {
                label.fixedSize()
                Spacer(minLength: 0)
                slider.frame(width: Yap.Inspector.slider)
                HStack(spacing: 0) { readout.frame(width: Yap.Inspector.readout, alignment: .trailing); resetSlot }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) { label; Spacer(minLength: 4); readout; resetSlot }
                slider
            }
        }
        .frame(minHeight: Yap.Inspector.rowHeight)
        .contextMenu { if let reset { Button("Reset to default", action: reset).disabled(!changed) } }
    }

    private var label: some View { Text(title).font(Yap.Font.body).foregroundStyle(Yap.label).lineLimit(1) }
    private var readout: some View {
        Text(value).technical().lineLimit(1).minimumScaleFactor(0.75).accessibilityHidden(true)
    }
    private var slider: some View {
        PillSlider(value: $amount, trackHeight: 16, onEditingChanged: onEditingChanged)
            .accessibilityLabel(title).accessibilityValue(value)
    }
    @ViewBuilder private var resetSlot: some View {
        if let reset {
            ResetGlyph(title: title, enabled: changed, action: reset)
        } else {
            Color.clear.frame(width: Yap.Inspector.resetSlot, height: 1)
        }
    }
}

/// The reset arrow of a slider row: only visible when the value differs from its default.
private struct ResetGlyph: View {
    let title: String
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hover ? Yap.title : Yap.faint)
                .frame(width: Yap.Inspector.resetSlot, height: Yap.Inspector.rowHeight, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
        .help("Reset to default")
        .accessibilityLabel("Reset \(title)")
        .accessibilityHidden(!enabled)
    }
}

// MARK: - Groups and text rows

/// A group of settings under a quiet caption; groups are separated by a plain hairline.
public struct InspectorGroup<Content: View>: View {
    let title: String
    var first: Bool
    let content: Content

    public init(_ title: String = "", first: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title; self.first = first; self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !first { Hairline(axis: .horizontal, opacity: Yap.dockHairline).padding(.bottom, 4) }
            if !title.isEmpty {
                Text(title).font(Yap.Font.caption).foregroundStyle(Yap.caption).accessibilityAddTraits(.isHeader)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
    }
}

/// Fine-tuning stays folded until asked for.
public struct InspectorMore<Content: View>: View {
    let title: String
    var value: String
    let content: Content
    @State private var open: Bool
    @Environment(\.inspectorExpandsAll) private var expandsAll

    public init(_ title: String = "More", value: String = "", initiallyOpen: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title; self.value = value; self.content = content(); _open = State(initialValue: initiallyOpen)
    }

    public var body: some View {
        DisclosureSection(title, value: value, open: Binding(get: { open || expandsAll }, set: { open = $0 })) {
            VStack(alignment: .leading, spacing: 12) { content }
        }
        .padding(.horizontal, -8)
    }
}

public extension EnvironmentValues {
    /// Opens every "More" of the inspector (review snapshots).
    @Entry var inspectorExpandsAll = false
}

/// A quiet explanation under a setting.
public struct InspectorNote: View {
    let text: String
    var symbol: String?
    public init(_ text: String, symbol: String? = nil) { self.text = text; self.symbol = symbol }
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(Yap.Font.caption).foregroundStyle(Yap.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A read-only value: label left, value in yellow right.
public struct InspectorInfo: View {
    let title: String
    let value: String
    public init(_ title: String, _ value: String) { self.title = title; self.value = value }
    public var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Yap.Font.body).foregroundStyle(Yap.label)
            Spacer(minLength: 8)
            Text(value).technical().lineLimit(1)
        }
        .frame(minHeight: Yap.Inspector.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// Work in progress (transcribing, analysing): a small spinner and one line.
public struct InspectorBusy: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Yap.label)
            Text(text).font(Yap.Font.body).foregroundStyle(Yap.body)
        }
        .frame(minHeight: Yap.Inspector.rowHeight)
    }
}

/// A selectable line in a list (captions, tracks, chords): optional time in yellow, text, trailing accessories.
public struct InspectorListRow<Trailing: View>: View {
    let time: String
    let text: String
    var selected: Bool
    var dim: Bool
    let action: () -> Void
    let trailing: Trailing
    @State private var hover = false

    public init(time: String = "", text: String, selected: Bool = false, dim: Bool = false, action: @escaping () -> Void,
                @ViewBuilder trailing: () -> Trailing) {
        self.time = time; self.text = text; self.selected = selected; self.dim = dim; self.action = action; self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 8) {
                    if !time.isEmpty { Text(time).technical().lineLimit(1) }
                    Text(text).font(Yap.Font.body).foregroundStyle(dim ? Yap.faint : (hover || selected ? Yap.title : Yap.label)).lineLimit(1)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            trailing
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(Platter(active: selected, hover: hover, radius: Yap.Radius.control))
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

public extension InspectorListRow where Trailing == EmptyView {
    init(time: String = "", text: String, selected: Bool = false, dim: Bool = false, action: @escaping () -> Void) {
        self.init(time: time, text: text, selected: selected, dim: dim, action: action) { EmptyView() }
    }
}

// MARK: - Buttons

/// A small glyph button in a row (play, remove, hide): icon only, platter on hover, tooltip and VoiceOver label.
public struct InspectorIconButton: View {
    let symbol: String
    let label: String
    var active: Bool
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    public init(symbol: String, label: String, active: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.active = active; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active || hover ? Yap.title : Yap.caption)
                .frame(width: 24, height: 24)
                .background(Platter(active: active, hover: hover && enabled, radius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .opacity(enabled ? 1 : 0.35)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A tile in a grid of choices (camera looks, cursor sets): content on a platter, the chosen one brighter.
public struct InspectorTile<Content: View>: View {
    var selected: Bool
    let label: String
    let action: () -> Void
    let content: Content
    @State private var hover = false

    public init(selected: Bool, label: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.selected = selected; self.label = label; self.action = action; self.content = content()
    }

    public var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(selected || hover ? Yap.title : Yap.label)
                .frame(maxWidth: .infinity)
                .padding(6)
                .background(Platter(active: selected, hover: hover, radius: Yap.Radius.control))
                .background(RoundedRectangle(cornerRadius: Yap.Radius.control, style: .continuous).fill(Color.white.opacity(0.04)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Text

/// Multi-line text input recessed into the surface (caption and text content).
public struct RecessedTextArea: View {
    let prompt: String
    @Binding var text: String
    var lines: ClosedRange<Int>
    let onSubmit: () -> Void

    public init(_ prompt: String, text: Binding<String>, lines: ClosedRange<Int> = 1...4, onSubmit: @escaping () -> Void = {}) {
        self.prompt = prompt; _text = text; self.lines = lines; self.onSubmit = onSubmit
    }

    public var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .lineLimit(lines)
            .textFieldStyle(.plain).font(Yap.Font.body).foregroundStyle(Yap.label)
            .onSubmit(onSubmit)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Yap.Radius.control, style: .continuous).fill(Yap.recess))
    }
}

// MARK: - Colour

/// A colour setting: label left; the hex value in yellow (editable), a swatch that opens the colour panel and an
/// eyedropper right. `rgba` is 0…1; every change is reported through `onChange` (the editor batches them).
public struct ColorValueRow: View {
    let title: String
    let rgba: [Double]
    var alpha: Bool
    let onChange: ([Double]) -> Void
    @State private var hex = ""
    @State private var token = UUID()
    @FocusState private var focused: Bool

    public init(_ title: String, rgba: [Double], alpha: Bool = false, onChange: @escaping ([Double]) -> Void) {
        self.title = title; self.rgba = rgba.count >= 4 ? rgba : rgba + Array(repeating: 1, count: max(0, 4 - rgba.count))
        self.alpha = alpha; self.onChange = onChange
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Yap.Font.body).foregroundStyle(Yap.label).lineLimit(1)
            Spacer(minLength: 6)
            hexField
            ColorSwatchButton(title: title, rgba: rgba, open: openPanel)
            InspectorIconButton(symbol: "eyedropper", label: "Pick \(title) from the screen", action: sample)
        }
        .frame(minHeight: Yap.Inspector.rowHeight)
        .onAppear { hex = YapHex.string(rgba, alpha: alpha) }
        .onChange(of: rgba) { _, c in if !focused { hex = YapHex.string(c, alpha: alpha) } }
        .onChange(of: focused) { _, f in if !f { commitHex() } }
        .onDisappear { ColorWellBridge.shared.detach(token) }
    }

    private var hexField: some View {
        TextField("Hex", text: $hex)
            .textFieldStyle(.plain).font(Yap.Font.technical).foregroundStyle(Yap.technical)
            .multilineTextAlignment(.trailing)
            .frame(width: alpha ? 82 : 64)
            .focused($focused)
            .onSubmit(commitHex)
            .accessibilityLabel("\(title) hex value")
    }

    private func commitHex() {
        if let c = YapHex.parse(hex, keepAlpha: rgba[3]) { onChange(alpha ? c : [c[0], c[1], c[2], rgba[3]]) }
        hex = YapHex.string(rgba, alpha: alpha)
    }

    private func openPanel() {
        let keep = rgba[3], withAlpha = alpha, report = onChange
        ColorWellBridge.shared.open(token, color: YapHex.nsColor(rgba), alpha: alpha) { n in
            guard let s = n.usingColorSpace(.sRGB) else { return }
            report([Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent), withAlpha ? Double(s.alphaComponent) : keep])
        }
    }

    private func sample() {
        let keep = rgba[3], report = ColorReport(onChange)
        NSColorSampler().show { picked in
            guard let s = picked?.usingColorSpace(.sRGB) else { return }
            let c = [Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent), keep]
            Task { @MainActor in report.send(c) }
        }
    }
}

/// Hands a row's change callback across the sampler's completion (it is only called back on the main actor).
private final class ColorReport: @unchecked Sendable {
    private let call: ([Double]) -> Void
    init(_ call: @escaping ([Double]) -> Void) { self.call = call }
    @MainActor func send(_ c: [Double]) { call(c) }
}

private struct ColorSwatchButton: View {
    let title: String
    let rgba: [Double]
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button(action: open) {
            // The colour as it will look (with its opacity) over a recess, the opaque colour as a strip along the bottom.
            ZStack(alignment: .bottom) {
                shape.fill(Yap.recess)
                shape.fill(Color(.sRGB, red: rgba[0], green: rgba[1], blue: rgba[2], opacity: rgba[3]))
                if rgba[3] < 0.99 { Color(.sRGB, red: rgba[0], green: rgba[1], blue: rgba[2]).frame(height: 5) }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(hover ? 0.6 : 0.25), lineWidth: 1))
            .frame(width: 26, height: 22)
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help("Choose \(title)")
        .accessibilityLabel("\(title) colour")
    }
}

/// "#RRGGBB" / "#RRGGBBAA" ↔ [r, g, b, a] in 0…1.
public enum YapHex {
    public static func string(_ c: [Double], alpha: Bool) -> String {
        let b = c.prefix(4).map { Int(min(max(($0 * 255).rounded(), 0), 255)) }
        guard b.count >= 3 else { return "#000000" }
        let base = String(format: "#%02X%02X%02X", b[0], b[1], b[2])
        return alpha ? base + String(format: "%02X", b.count > 3 ? b[3] : 255) : base
    }

    public static func parse(_ text: String, keepAlpha: Double) -> [Double]? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6 || t.count == 8, let v = UInt64(t, radix: 16) else { return nil }
        let a = t.count == 8
        let r = Double((v >> (a ? 24 : 16)) & 255) / 255, g = Double((v >> (a ? 16 : 8)) & 255) / 255
        let b = Double((v >> (a ? 8 : 0)) & 255) / 255
        return [r, g, b, a ? Double(v & 255) / 255 : keepAlpha]
    }

    public static func nsColor(_ c: [Double]) -> NSColor {
        NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? c[3] : 1)
    }
}

/// Routes the shared colour panel to the row that opened it last; a row that goes away stops receiving.
@MainActor final class ColorWellBridge: NSObject {
    static let shared = ColorWellBridge()
    private var owner: UUID?
    private var onChange: ((NSColor) -> Void)?

    func open(_ owner: UUID, color: NSColor, alpha: Bool, onChange: @escaping (NSColor) -> Void) {
        self.onChange = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = alpha
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        self.owner = owner
        self.onChange = onChange
        panel.orderFront(nil)
    }

    func detach(_ owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil; onChange = nil
    }

    @objc private func changed(_ panel: NSColorPanel) { onChange?(panel.color) }
}
