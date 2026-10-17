import SwiftUI

// MARK: - Selection

/// Selected = a slightly brighter surface; hovered = half of that. No border, no colour.
public struct Platter: ViewModifier {
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
        modifier(Platter(selected: selected, hover: hover, radius: radius))
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
