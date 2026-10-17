import AppKit
import SwiftUI

// Small controls of the docked timeline head (ae-timeline, 2026-10-17): icon slots in a 40-pt row and a quiet
// slider for the timeline zoom. States through brightness only, like the slots of a bar.

/// An icon-only slot in a short row (transport, tools): the glyph on a platter that comes in on hover, a brighter
/// platter while `active` (a tool that is on). Label in the tooltip and for VoiceOver.
public struct IconSlot: View {
    let symbol: String
    let label: String
    var help: String
    var active: Bool
    var size: CGFloat
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    public init(_ symbol: String, label: String, help: String = "", active: Bool = false, size: CGFloat = 28, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.help = help; self.active = active; self.size = size; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(active || hover ? Yap.title : Yap.body)
                .frame(width: size, height: size)
                .background(Platter(active: active, hover: hover && enabled, radius: 8))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help(help.isEmpty ? label : help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A slot that shows a short value (clip speed "1×") in yellow instead of a glyph.
public struct ValueSlot: View {
    let value: String
    let label: String
    var help: String
    let action: () -> Void
    @State private var hover = false

    public init(_ value: String, label: String, help: String = "", action: @escaping () -> Void) {
        self.value = value; self.label = label; self.help = help; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(value).font(Yap.Font.technical).foregroundStyle(Yap.technical).lineLimit(1)
                .padding(.horizontal, 8).frame(minWidth: 28, minHeight: 28)
                .background(Platter(active: false, hover: hover, radius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help(help.isEmpty ? label : help)
        .accessibilityLabel(label).accessibilityValue(value)
    }
}

/// A thin slider: a faint groove, the part up to the value a little brighter, a small white knob. For secondary
/// settings in a row (timeline zoom) where the pill slider would be too loud. No accent colour.
public struct HairSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    @State private var hover = false

    public init(value: Binding<Double>, in range: ClosedRange<Double>, accessibilityStep step: Double = 0) {
        _value = value; self.range = range; self.step = step
    }

    /// Fraction 0…1 of `value` within `range` (clamped; an empty range is 0).
    public static func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0, value.isFinite else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    public var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = 12, usable = max(geo.size.width - knob, 1)
            let x = usable * Self.fraction(value, in: range)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 3)
                Capsule().fill(Color.white.opacity(hover ? 0.55 : 0.4)).frame(width: x + knob / 2, height: 3)
                Circle().fill(Color.white).frame(width: knob, height: knob).offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = min(max((g.location.x - knob / 2) / usable, 0), 1)
                value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 20)
        .onHover { hover = $0 }
        .animation(Yap.Motion.hover(hover), value: hover)
        .accessibilityElement()
        .accessibilityValue(String(format: "%.0f percent", Self.fraction(value, in: range) * 100))
        .accessibilityAdjustableAction { dir in
            let d = step > 0 ? step : (range.upperBound - range.lowerBound) / 20
            value = min(max(value + (dir == .increment ? d : -d), range.lowerBound), range.upperBound)
        }
    }
}
