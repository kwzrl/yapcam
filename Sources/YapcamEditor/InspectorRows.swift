import SwiftUI
import YapcamCore
import YapcamDesign

// MARK: setting rows (all bound to project paths; sliders commit on release = one undo step)

/// Kit slider bound to the model: previews locally while dragged and commits once on release (one undo step).
struct CommitSlider: View {
    let title: String
    let range: ClosedRange<Double>
    let get: () -> Double
    let commit: (Double) -> Void
    let text: (Double) -> String
    var step = 0.0                       // 0 = continuous
    var snaps: [Double] = []             // stored values the slider sticks to
    var snapDistance = 0.012             // fraction of the range
    var defaultValue: Double? = nil      // shows a reset arrow when the value differs
    @State private var drag: Double?

    var body: some View {
        let v = drag ?? get()
        InspectorSlider(title, value: text(v), amount: fraction(v), changed: changed(v), reset: resetAction,
                        onEditingChanged: { editing in if !editing { finish() } })
    }

    private var span: Double { max(range.upperBound - range.lowerBound, .ulpOfOne) }
    private func fraction(_ v: Double) -> Binding<Double> {
        Binding(get: { (min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span },
                set: { drag = shaped(range.lowerBound + $0 * span) })
    }
    private func changed(_ v: Double) -> Bool { defaultValue.map { abs(v - $0) > 1e-9 } ?? false }
    private var resetAction: (() -> Void)? { defaultValue.map { d in { drag = nil; commit(d) } } }
    private func finish() {
        guard let d = drag else { return }
        drag = nil
        if abs(d - get()) > 1e-12 { commit(d) }
    }
    private func shaped(_ raw: Double) -> Double {
        var v = step > 0 ? (raw / step).rounded() * step : raw
        v = min(max(v, range.lowerBound), range.upperBound)
        let tolerance = span * snapDistance
        if let nearest = snaps.filter(range.contains).min(by: { abs($0 - v) < abs($1 - v) }), abs(nearest - v) <= tolerance { return nearest }
        return v
    }
}

struct NumberRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String
    let range: ClosedRange<Double>
    var unit = "", format = "%.2f", scale = 1.0      // scale: display = stored * scale
    var defaultValue: Double? = nil                  // shows a reset button when the value differs
    var snaps: [Double] = []                         // suggested values the slider sticks to (in stored units × scale)
    var snapDistance = 0.012                         // fraction of the range

    var body: some View {
        CommitSlider(title: title, range: range, get: { model.number(path) }, commit: { model.set(path, number: $0) },
                     text: { String(format: format, $0 * scale) + (unit.isEmpty ? "" : " \(unit)") },
                     snaps: snaps.map { $0 / scale }, snapDistance: snapDistance, defaultValue: defaultValue)
    }
}

struct ToggleRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String
    var defaultValue = false
    var body: some View {
        SwitchRow(title, isOn: Binding(get: { model.bool(path, default: defaultValue) }, set: { model.set(path, bool: $0) }))
    }
}

/// A few short choices as a segment switch, more as a menu.
struct ChoiceRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(label: String, value: Value)]
    var forceMenu = false

    init(_ title: String, selection: Binding<Value>, options: [(String, Value)], forceMenu: Bool = false) {
        self.title = title; _selection = selection; self.options = options.map { (label: $0.0, value: $0.1) }; self.forceMenu = forceMenu
    }

    /// A stored value the menu does not list (older projects, missing keys): shown as is, "Default" when empty.
    static func unlisted(_ v: Value) -> String { let t = String(describing: v); return t.isEmpty ? "Default" : t }

    static func fitsSegments(_ labels: [String]) -> Bool { labels.count <= 4 && labels.joined().count <= 26 }

    var body: some View {
        if !forceMenu && Self.fitsSegments(options.map(\.label)) {
            ValueChoice(title, items: options.map { (id: $0.value, title: $0.label) }, selection: $selection)
        } else {
            ChoiceMenuRow(title, options: options.map(\.label), selection: labelBinding)
        }
    }

    private var labelBinding: Binding<String> {
        Binding(get: { options.first { $0.value == selection }?.label ?? Self.unlisted(selection) },
                set: { label in if let o = options.first(where: { $0.label == label }) { selection = o.value } })
    }
}

struct PickerRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String
    let options: [(label: String, value: String)]
    var body: some View {
        ChoiceRow(title, selection: Binding(get: { model.string(path) }, set: { model.set(path, string: $0) }),
                  options: options.map { ($0.label, $0.value) })
    }
}

struct ColorRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String
    var opacity = false          // true: the picker edits alpha too
    var body: some View {
        RestingColorPicker(title: title, opacity: opacity, get: { model.color(path) }, set: { model.set(path, color: $0) })
    }
}

/// Colour row that previews locally while the panel moves and commits once when it rests (or the view goes away), so one
/// drag is one undo step, one journal write and one preview rebuild instead of one per tick.
struct RestingColorPicker: View {
    let title: String
    var opacity = true
    let get: () -> [Double]
    let set: ([Double]) -> Void
    var transform: ([Double]) -> [Double] = { $0 }        // e.g. keep the stored alpha for pickers without opacity
    @State private var pending: [Double]?
    @State private var task: Task<Void, Never>?

    private var current: [Double] { let c = pending ?? get(); return c.count >= 4 ? c : c + Array(repeating: 1, count: 4 - c.count) }
    private func stage(_ c: [Double]) {
        pending = opacity ? c : [c[0], c[1], c[2], get().count > 3 ? get()[3] : 1]
        task?.cancel()
        task = Task { try? await Task.sleep(for: .milliseconds(350)); if !Task.isCancelled { flush() } }
    }
    var body: some View {
        ColorValueRow(title, rgba: current, alpha: opacity, onChange: stage)
            .onDisappear { task?.cancel(); flush() }
    }
    private func flush() { if let p = pending { pending = nil; set(transform(p)) } }
}

struct DurationRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String
    var `default` = 400_000_000.0
    var range: ClosedRange<Double> = 0.1...5
    var body: some View {
        CommitSlider(title: title, range: range, get: { model.number(path, default: `default`) / 1e9 },
                     commit: { model.set(path, number: ($0 * 1e9).rounded()) }, text: { String(format: "%.1f s", $0) })
    }
}

/// A normalized rectangle (left, top, width, height) as four sliders under a caption; width and height stay inside.
struct RectRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String, fallback: [Double]
    private static let parts = ["Left", "Top", "Width", "Height"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Yap.Font.caption).foregroundStyle(Yap.caption)
            ForEach(0..<4, id: \.self) { i in part(i) }
        }
    }
    private func current() -> [Double] { let n = model.numbers(path); return n.count == 4 ? n : fallback }
    private func part(_ i: Int) -> some View {
        CommitSlider(title: Self.parts[i], range: i < 2 ? 0...0.95 : 0.05...1, get: { current()[i] },
                     commit: { v in var r = current(); r[i] = v; r[2] = min(r[2], 1 - r[0]); r[3] = min(r[3], 1 - r[1]); model.set(path, color: r) },
                     text: { "\(Int(($0 * 100).rounded())) %" })
    }
}

/// A picker whose first entry means "unset" (stored as JSON null).
struct NullableChoiceRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String, automatic: String
    let options: [(label: String, value: String)]
    var body: some View {
        ChoiceRow(title, selection: Binding(get: { if case .string(let s)? = model.value(path) { s } else { "" } },
                                            set: { model.set(path, $0.isEmpty ? .null : .string($0)) }),
                  options: [(automatic, "")] + options.map { ($0.label, $0.value) }, forceMenu: true)
    }
}

/// A secondary capsule action (no colour; destructive actions are worded, not red).
struct InspectorAction: View {
    let title: String
    var symbol: String?
    let action: () -> Void
    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) { self.title = title; self.symbol = symbol; self.action = action }
    var body: some View {
        Button(action: action) {
            if let symbol { Label(title, systemImage: symbol).lineLimit(1) } else { Text(title).lineLimit(1) }
        }
        .buttonStyle(CapsuleButtonStyle(.secondary, height: 28))
    }
}

/// A failure line with its dismiss button (no red: red only marks recording).
struct InspectorFailure: View {
    let message: String
    var button = "Dismiss"
    let dismiss: () -> Void
    var body: some View {
        InspectorNote(message, symbol: "exclamationmark.triangle")
        InspectorAction(button, action: dismiss)
    }
}
