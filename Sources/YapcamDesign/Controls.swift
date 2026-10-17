import AppKit
import SwiftUI

// MARK: - Selection

/// Selected = a slightly brighter surface; hovered = half of that. No border, no colour.
/// (Older, static fill for rows and menus; slots in bars use the animated `Platter` in Slots.swift.)
public struct PlatterFill: ViewModifier {
    var selected: Bool
    var hover: Bool
    var radius: CGFloat
    public func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(selected ? Yap.platter : (hover ? Yap.platterHover : .clear)))
    }
}

public extension View {
    func platter(selected: Bool, hover: Bool = false, radius: CGFloat = Yap.Radius.card) -> some View {
        modifier(PlatterFill(selected: selected, hover: hover, radius: radius))
    }
}

// MARK: - Buttons

/// Capsule button. `.primary` is the brightest thing on screen (solid white, dark label);
/// `.secondary` is a platter on glass.
public struct CapsuleButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary }
    var kind: Kind
    var height: CGFloat
    public init(_ kind: Kind = .secondary, height: CGFloat = 32) { self.kind = kind; self.height = height }
    public func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, kind: kind, height: height)
    }
    private struct Styled: View {
        let configuration: Configuration
        let kind: Kind
        let height: CGFloat
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(kind == .primary ? Color.black : Yap.label)
                .padding(.horizontal, height * 0.6).frame(height: height)
                .background(Capsule().fill(kind == .primary
                    ? Color.white.opacity(configuration.isPressed ? 0.8 : 1)
                    : Color.white.opacity(configuration.isPressed ? 0.14 : (hover ? 0.11 : 0.08))))
                .shadow(color: kind == .primary ? .white.opacity(0.25) : .clear, radius: 10)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { hover = $0 }
        }
    }
}

/// Circle button (like "…"). When `active` it inverts: solid white with a dark glyph.
public struct CircleButtonStyle: ButtonStyle {
    var active: Bool
    var size: CGFloat
    public init(active: Bool = false, size: CGFloat = 32) { self.active = active; self.size = size }
    public func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, active: active, size: size)
    }
    private struct Styled: View {
        let configuration: Configuration
        let active: Bool
        let size: CGFloat
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(active ? Color.black : Yap.label)
                .frame(width: size, height: size)
                .background(Circle().fill(active ? Color.white : Color.white.opacity(configuration.isPressed ? 0.14 : (hover ? 0.14 : 0.08))))
                .scaleEffect(configuration.isPressed ? 0.94 : (hover ? 1.06 : 1))
                .animation(hover ? .snappy(duration: 0.14) : .smooth(duration: 0.3), value: hover)
                .animation(.snappy(duration: 0.12), value: configuration.isPressed)
                .contentShape(Circle())
                .onHover { hover = $0 }
        }
    }
}

// MARK: - Slider

/// Slider as a groove in the glass with a wide white pill as the thumb (passive = recessed, active = raised/light).
public struct PillSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void
    var trackHeight: CGFloat
    @State private var dragging = false

    public init(value: Binding<Double>, in range: ClosedRange<Double> = 0...1, trackHeight: CGFloat = 22,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value; self.range = range; self.trackHeight = trackHeight; self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        GeometryReader { geo in
            let thumbW = max(trackHeight * 2.2, 36), thumbH = trackHeight - 8
            let span = range.upperBound - range.lowerBound
            let f = CGFloat(span > 0 ? (value - range.lowerBound) / span : 0)
            let x = 4 + (geo.size.width - thumbW - 8) * f
            ZStack(alignment: .leading) {
                Capsule().fill(Yap.recess)
                    .overlay(Capsule().strokeBorder(LinearGradient(colors: [.black.opacity(0.5), .white.opacity(0.06)],
                                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
                Capsule().fill(Color.white)
                    .frame(width: thumbW, height: thumbH)
                    .shadow(color: .white.opacity(dragging ? 0.45 : 0.3), radius: dragging ? 12 : 8)
                    .offset(x: x)
            }
            .frame(height: trackHeight)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging { dragging = true; onEditingChanged(true) }
                    let usable = max(geo.size.width - thumbW - 8, 1)
                    let nf = min(max((g.location.x - 4 - thumbW / 2) / usable, 0), 1)
                    value = range.lowerBound + Double(nf) * span
                }
                .onEnded { _ in dragging = false; onEditingChanged(false) })
        }
        .frame(height: trackHeight)
        .accessibilityElement()
        .accessibilityValue(String(format: "%.0f percent", (value - range.lowerBound) / max(range.upperBound - range.lowerBound, .ulpOfOne) * 100))
        .accessibilityAdjustableAction { dir in
            let step = (range.upperBound - range.lowerBound) / 20
            value = min(max(value + (dir == .increment ? step : -step), range.lowerBound), range.upperBound)
            onEditingChanged(false)
        }
    }
}

// MARK: - Option row

/// Free cells separated by hairlines that fade out at top and bottom; selection is a platter.
public struct OptionRow<ID: Hashable, Cell: View>: View {
    let ids: [ID]
    @Binding var selection: ID
    let cell: (ID, Bool) -> Cell
    @State private var hover: ID?

    public init(_ ids: [ID], selection: Binding<ID>, @ViewBuilder cell: @escaping (ID, Bool) -> Cell) {
        self.ids = ids; _selection = selection; self.cell = cell
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                if i > 0 { FadingHairline() }
                Button { selection = id } label: {
                    cell(id, selection == id)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .platter(selected: selection == id, hover: hover == id, radius: Yap.Radius.card)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 ? id : (hover == id ? nil : hover) }
                .accessibilityAddTraits(selection == id ? [.isSelected] : [])
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The plainest separator: one physical pixel of light, no groove, no fade.
public struct Hairline: View {
    var axis: Axis
    @Environment(\.displayScale) private var scale
    public init(axis: Axis = .vertical) { self.axis = axis }
    public var body: some View {
        Color.white.opacity(0.16)
            .frame(width: axis == .vertical ? 1 / scale : nil, height: axis == .vertical ? nil : 1 / scale)
    }
}

/// Separator milled into the glass: a dark groove with a lit lower/right lip, fading out at both ends.
/// `axis` is the direction the line runs (vertical between items in a row, horizontal between rows).
public struct FadingHairline: View {
    var axis: Axis
    public init(axis: Axis = .vertical) { self.axis = axis }
    public var body: some View {
        let groove = Color.black.opacity(0.55), lip = Color.white.opacity(0.13)
        let fade = LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.22),
                                          .init(color: .black, location: 0.78), .init(color: .clear, location: 1)],
                                  startPoint: axis == .vertical ? .top : .leading, endPoint: axis == .vertical ? .bottom : .trailing)
        Group {
            if axis == .vertical {
                HStack(spacing: 0) { groove.frame(width: 1); lip.frame(width: 1) }.padding(.vertical, 4)
            } else {
                VStack(spacing: 0) { groove.frame(height: 1); lip.frame(height: 1) }.padding(.horizontal, 4)
            }
        }
        .mask(fade)
        .accessibilityHidden(true)
    }
}

// MARK: - Menu

/// Glass menu: centred caption, hairline, large items with checkmark plus platter for the chosen one.
public struct GlassMenu<ID: Hashable>: View {
    let caption: String?
    let items: [(id: ID, title: String)]
    @Binding var selection: ID
    @State private var hover: ID?

    public init(caption: String? = nil, items: [(id: ID, title: String)], selection: Binding<ID>) {
        self.caption = caption; self.items = items; _selection = selection
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let caption {
                Text(caption).font(Yap.Font.caption).foregroundStyle(Yap.caption)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)
                Yap.hairline.frame(height: 1).padding(.horizontal, 14)
            }
            VStack(spacing: 2) {
                ForEach(items, id: \.id) { item in
                    Button { selection = item.id } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                .opacity(selection == item.id ? 1 : 0)
                            Text(item.title).font(.system(size: 14, weight: .medium))
                            Spacer()
                        }
                        .foregroundStyle(Yap.label)
                        .padding(.horizontal, 12).frame(height: 36)
                        .platter(selected: selection == item.id, hover: hover == item.id, radius: Yap.Radius.control)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hover = $0 ? item.id : (hover == item.id ? nil : hover) }
                    .accessibilityAddTraits(selection == item.id ? [.isSelected] : [])
                }
            }
            .padding(6)
        }
    }
}

// MARK: - Field

/// Text input recessed into the glass like the slider groove; an optional trailing control sits inside.
public struct RecessedField<Trailing: View>: View {
    let prompt: String
    @Binding var text: String
    var height: CGFloat
    let trailing: Trailing

    public init(_ prompt: String, text: Binding<String>, height: CGFloat = 36, @ViewBuilder trailing: () -> Trailing) {
        self.prompt = prompt; _text = text; self.height = height; self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 6) {
            TextField(prompt, text: $text)
                .textFieldStyle(.plain).font(Yap.Font.body).foregroundStyle(Yap.label)
            trailing
        }
        .padding(.leading, 14).padding(.trailing, 4)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: height / 2, style: .continuous).fill(Yap.recess))
    }
}

public extension RecessedField where Trailing == EmptyView {
    init(_ prompt: String, text: Binding<String>, height: CGFloat = 36) {
        self.init(prompt, text: text, height: height) { EmptyView() }
    }
}

// MARK: - Disclosure

/// A section that shows its basics in one line (title, value in yellow) and opens for the fine-tuning.
public struct DisclosureSection<Content: View>: View {
    let title: String
    var value: String
    @Binding var open: Bool
    let content: Content
    @State private var hover = false

    public init(_ title: String, value: String = "", open: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title; self.value = value; _open = open; self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(Yap.Motion.select) { open.toggle() } } label: { header }
                .buttonStyle(PressStyle())
                .onHover { hover = $0 }
                .accessibilityLabel(title).accessibilityValue(value)
                .accessibilityHint(open ? "Collapses the section" : "Shows the settings")
            if open { content.padding(.horizontal, 8).padding(.bottom, 6) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title).font(Yap.Font.label).foregroundStyle(hover ? Yap.title : Yap.label)
            Spacer(minLength: 8)
            if !value.isEmpty { Text(value).technical().lineLimit(1) }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hover ? Yap.title : Yap.faint)
                .rotationEffect(.degrees(open ? 90 : 0))
        }
        .padding(.horizontal, 8).frame(height: 32)
        .background(Platter(active: false, hover: hover, radius: Yap.Radius.control))
        .contentShape(Rectangle())
    }
}

// MARK: - Inspector rows

/// A parameter: label on the left, its value in yellow on the right, the pill slider below.
public struct ValueSlider: View {
    let title: String
    let value: String
    @Binding var amount: Double

    public init(_ title: String, value: String, amount: Binding<Double>) {
        self.title = title; self.value = value; _amount = amount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(Yap.Font.body).foregroundStyle(Yap.label)
                Spacer()
                Text(value).technical()
            }
            PillSlider(value: $amount, trackHeight: 18)
                .accessibilityLabel(title)
        }
    }
}

/// A parameter with a few choices: label above, a segment switch below.
public struct ValueChoice<ID: Hashable>: View {
    let title: String
    let items: [(id: ID, title: String)]
    @Binding var selection: ID

    public init(_ title: String, items: [(id: ID, title: String)], selection: Binding<ID>) {
        self.title = title; self.items = items; _selection = selection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Yap.Font.body).foregroundStyle(Yap.label)
            SegmentSwitch(items, selection: $selection, height: 26)
        }
    }
}

/// A row in a list (chat changes, results): icon, title, a value in yellow, platter on hover.
public struct ValueRow: View {
    let symbol: String
    let title: String
    let value: String
    var help: String
    let action: () -> Void
    @State private var hover = false

    public init(symbol: String, title: String, value: String, help: String = "", action: @escaping () -> Void) {
        self.symbol = symbol; self.title = title; self.value = value; self.help = help; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(hover ? Yap.title : Yap.caption).frame(width: 18)
                Text(title).font(Yap.Font.body).foregroundStyle(hover ? Yap.title : Yap.label).lineLimit(1)
                Spacer(minLength: 6)
                Text(value).technical()
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(Platter(active: false, hover: hover, radius: Yap.Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(title).accessibilityValue(value)
    }
}

// MARK: - Switch

/// On/off as a groove with a white knob, like the pill slider: off = recessed and dim, on = lit.
public struct PillSwitch: View {
    @Binding var isOn: Bool
    public init(isOn: Binding<Bool>) { _isOn = isOn }

    public var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Color.white.opacity(0.32) : Yap.recess)
                    .overlay(Capsule().strokeBorder(LinearGradient(colors: [.black.opacity(isOn ? 0.15 : 0.5), .white.opacity(0.06)],
                                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
                Circle().fill(Color.white.opacity(isOn ? 1 : 0.7))
                    .frame(width: 14, height: 14).padding(3)
                    .shadow(color: .white.opacity(isOn ? 0.35 : 0), radius: 6)
            }
            .frame(width: 36, height: 20)
            .animation(Yap.Motion.select, value: isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// A setting that is on or off: label left, switch right; the whole row toggles.
public struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    public init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }

    public var body: some View {
        HStack {
            Text(title).font(Yap.Font.body).foregroundStyle(Yap.label)
            Spacer(minLength: 8)
            PillSwitch(isOn: $isOn).accessibilityLabel(title)
        }
        .frame(minHeight: 26)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
    }
}

// MARK: - Choice menu

/// A setting with more choices than fit a segment switch: label left, the current choice and a chevron right;
/// a click opens the system menu.
public struct ChoiceMenuRow: View {
    let title: String
    let options: [String]
    @Binding var selection: String
    @State private var hover = false

    public init(_ title: String, options: [String], selection: Binding<String>) {
        self.title = title; self.options = options; _selection = selection
    }

    public var body: some View {
        HStack {
            Text(title).font(Yap.Font.body).foregroundStyle(Yap.label)
            Spacer(minLength: 8)
            Menu {
                ForEach(options, id: \.self) { o in
                    Button { selection = o } label: { if o == selection { Label(o, systemImage: "checkmark") } else { Text(o) } }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(selection).font(Yap.Font.body)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(hover ? Yap.title : Yap.label)
                .padding(.horizontal, 10).frame(height: 26)
                .background(Platter(active: false, hover: hover, radius: 8))
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .onHover { hover = $0 }
            .accessibilityLabel(title).accessibilityValue(selection)
        }
    }
}

// MARK: - Colour

/// A colour setting: label left, the hex value in yellow and a swatch right; a click opens the colour panel.
public struct ColorSwatchRow: View {
    let title: String
    @Binding var color: Color
    @State private var hover = false

    public init(_ title: String, color: Binding<Color>) { self.title = title; _color = color }

    public var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Yap.Font.body).foregroundStyle(Yap.label)
            Spacer(minLength: 8)
            Text(Self.hex(color)).technical()
            Button { ColorPanelBridge.shared.open(color: NSColor(color)) { color = Color(nsColor: $0) } } label: {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(hover ? 0.6 : 0.25), lineWidth: 1))
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(PressStyle())
            .onHover { hover = $0 }
            .accessibilityLabel("\(title) colour")
        }
        .frame(minHeight: 26)
    }

    static func hex(_ c: Color) -> String {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
    }
}

/// Routes the shared colour panel to whichever swatch opened it last.
@MainActor final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((NSColor) -> Void)?

    func open(color: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.onChange = nil
        let panel = NSColorPanel.shared
        panel.color = color
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        self.onChange = onChange
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) { onChange?(panel.color) }
}
