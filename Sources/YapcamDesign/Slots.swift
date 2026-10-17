import AppKit
import SwiftUI

// Slots: the 42-pt cells of a bar (toolbar, editor), their platter and their motion. Moved here from the
// toolbar (lab variant B, 2026-10-17) so the editor uses the same pieces.

public extension Yap {
    /// One grid for every bar: 42-pt cells in a 54-pt bar, 6 pt inset, concentric corners (16 → 10).
    enum Grid {
        public static let cell: CGFloat = 42
        public static let bar: CGFloat = 54
        public static let inset: CGFloat = 6
        public static let barRadius: CGFloat = 16
        public static let cellRadius: CGFloat = Yap.concentric(barRadius, inset: inset)
    }

    /// Hover comes in fast and leaves softly; a press scales to 0.95.
    enum Motion {
        public static let hoverIn = Animation.snappy(duration: 0.14)
        public static let hoverOut = Animation.smooth(duration: 0.3)
        public static let press = Animation.snappy(duration: 0.12)
        public static let select = Animation.snappy(duration: 0.18)
        public static func hover(_ on: Bool) -> Animation { on ? hoverIn : hoverOut }
    }
}

/// Hover/selection platter behind a slot: comes in fast and grows from 90 %, leaves softly.
/// Selected 24 % white, hover 8 % (more with Increase Contrast).
public struct Platter: View {
    var active: Bool
    var hover: Bool
    var radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    public init(active: Bool, hover: Bool, radius: CGFloat = Yap.Grid.cellRadius) {
        self.active = active; self.hover = hover; self.radius = radius
    }

    public var body: some View {
        let on = active || hover, increased = contrast == .increased
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(active ? (increased ? 0.36 : 0.24) : (increased ? 0.16 : 0.08)))
            .opacity(on ? 1 : 0)
            .scaleEffect(on ? 1 : 0.9)
            .animation(Yap.Motion.hover(on), value: on)
            .animation(Yap.Motion.select, value: active)
    }
}

/// Press feedback for slots: scale to 0.95, a little dimmer.
public struct PressStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(Yap.Motion.press, value: configuration.isPressed)
    }
}

/// A slot in a bar: icon over a 10-pt label on a platter, or icon only (`compact`) with the label in the
/// tooltip and for VoiceOver. States through brightness only.
public struct SlotButton: View {
    public static let size: CGFloat = Yap.Grid.cell
    let symbol: String
    let label: String
    var help: String
    /// Selected (open source, open menu, current tool): a brighter platter and full white. No colour.
    var active: Bool
    /// Off state (no camera, mic muted): dimmed, never a colour.
    var dim: Bool
    var enabled: Bool
    /// Icon only; the label stays in the tooltip and for VoiceOver.
    var compact: Bool
    /// A picture in place of the symbol (the toolbar's Edit button shows the latest recording).
    var image: NSImage?
    let action: () -> Void
    @State private var hover = false

    public init(symbol: String, label: String, help: String = "", active: Bool, dim: Bool = false, enabled: Bool = true,
                compact: Bool = false, image: NSImage? = nil, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.help = help; self.active = active; self.dim = dim
        self.enabled = enabled; self.compact = compact; self.image = image; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(active || hover ? Yap.title : (dim ? Yap.caption : Yap.label))
                .opacity(enabled ? 1 : 0.35)
                .background(Platter(active: active, hover: hover && enabled))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(help.isEmpty ? label : help)
        .accessibilityLabel(label)
        .accessibilityHint(help == label ? "" : help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        if compact {
            glyph(17).frame(width: Self.size, height: Self.size)
        } else {
            VStack(spacing: 3) {
                glyph(16).frame(height: 19)
                Text(label).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8).truncationMode(.tail)
                    .frame(maxWidth: 104)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: Self.size, minHeight: Self.size, maxHeight: Self.size)
        }
    }

    @ViewBuilder private func glyph(_ size: CGFloat) -> some View {
        if let image {
            let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: 30, height: 19).clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        } else {
            Image(systemName: symbol).font(.system(size: size, weight: .regular))
        }
    }
}
