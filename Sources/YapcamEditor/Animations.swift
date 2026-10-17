import SwiftUI
import YapcamCore

/// Spring presets (stiffness / damping / mass) in the reference's value space. Core accepts mass up to 10.
struct SpringPreset: Identifiable, Equatable {
    let id: String, title: String, hint: String
    let stiffness: Double, damping: Double, mass: Double
    static let screen = [
        SpringPreset(id: "focused", title: "Focused", hint: "Settles fast, easy to read", stiffness: 250, damping: 40, mass: 2.25),
        SpringPreset(id: "smooth", title: "Smooth", hint: "Fluid, longer glide", stiffness: 170, damping: 50, mass: 3)]
    static let cursor = [
        SpringPreset(id: "smooth", title: "Smooth", hint: "Gentle cursor glide", stiffness: 470, damping: 70, mass: 3),
        SpringPreset(id: "medium", title: "Medium", hint: "Balanced", stiffness: 340, damping: 60, mass: 3),
        SpringPreset(id: "rapid", title: "Rapid", hint: "Snappy, little smoothing", stiffness: 530, damping: 40, mass: 1)]
}

extension EditorModel {
    /// Sets the zoom/pan spring (`zoom_settings`) or the cursor spring (`cursor`) as one undo step. Values are
    /// clamped to what core accepts; the named presets of core are left to "custom" so these numbers apply.
    public func setSpring(screen: Bool, stiffness: Double, damping: Double, mass: Double) {
        let prefix = screen ? "zoom_settings" : "cursor"
        let spring: JSONValue = .object(["tension": .number(min(max(stiffness, 5), 600)), "friction": .number(min(max(damping, 5), 200)),
                                         "mass": .number(min(max(mass, 0.1), 10)), "allow_overshoot": .bool(false)])
        var cmds: [EditorCommand] = [.set(path: "\(prefix).spring", value: spring), .set(path: "\(prefix).speed_preset", value: .string("custom"))]
        if screen { cmds.append(.set(path: "zoom_settings.animation_style", value: .string("custom"))) }
        else if number("cursor.smoothing") == 0 { cmds.append(.set(path: "cursor.smoothing", value: .number(0.15))) }
        perform(.batch(cmds))
    }

    /// Cursor animation "None": raw cursor movement.
    public func setCursorAnimationNone() { set("cursor.smoothing", number: 0) }

    public func springValues(screen: Bool) -> (stiffness: Double, damping: Double, mass: Double) {
        let p = screen ? "zoom_settings.spring." : "cursor.spring."
        return (number(p + "tension", default: 250), number(p + "friction", default: 28), number(p + "mass", default: 1))
    }
    public func activePreset(screen: Bool) -> String? {
        if !screen, number("cursor.smoothing") == 0 { return "none" }
        let v = springValues(screen: screen)
        return (screen ? SpringPreset.screen : SpringPreset.cursor).first {
            abs($0.stiffness - v.stiffness) < 0.5 && abs($0.damping - v.damping) < 0.5 && abs($0.mass - v.mass) < 0.05
        }?.id
    }
}

/// "Animations" inspector section: screen and cursor spring presets with Customize, then one motion-blur slider.
struct AnimationPresets: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        group(title: "Screen animation", screen: true, presets: SpringPreset.screen, offersNone: false)
        group(title: "Cursor animation", screen: false, presets: SpringPreset.cursor, offersNone: true)
    }

    @ViewBuilder private func group(title: String, screen: Bool, presets: [SpringPreset], offersNone: Bool) -> some View {
        let active = model.activePreset(screen: screen)
        Section(title) {
            ForEach(presets) { p in
                Button { model.setSpring(screen: screen, stiffness: p.stiffness, damping: p.damping, mass: p.mass) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) { Text(p.title); Text(p.hint).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if active == p.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityAddTraits(active == p.id ? [.isButton, .isSelected] : .isButton)
            }
            if offersNone {
                Button { model.setCursorAnimationNone() } label: {
                    HStack { Text("None"); Text("Raw cursor movement").font(.caption).foregroundStyle(.secondary); Spacer()
                        if active == "none" { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) } }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if active != "none" { SpringSliders(model: model, screen: screen, defaultPreset: presets[0]) }
        }
    }
}

/// "Customize": stiffness, damping, mass; commits on release (one undo step), Reset returns to the first preset.
struct SpringSliders: View {
    @ObservedObject var model: EditorModel
    let screen: Bool
    let defaultPreset: SpringPreset
    @State private var open = false
    @State private var v = (stiffness: 250.0, damping: 40.0, mass: 2.25)
    @State private var editing = false
    var body: some View {
        DisclosureGroup("Customize", isExpanded: $open) {
            slider("Rigidity", $v.stiffness, 5...600, step: 1)
            slider("Smoothness", $v.damping, 5...200, step: 1)
            slider("Momentum", $v.mass, 0.1...10, step: 0.1)
            Button("Reset") { model.setSpring(screen: screen, stiffness: defaultPreset.stiffness, damping: defaultPreset.damping, mass: defaultPreset.mass) }
                .disabled(model.activePreset(screen: screen) == defaultPreset.id)
        }
        .onAppear(perform: load)
        .onChange(of: model.revision) { _, _ in if !editing { load() } }
    }
    private func load() { v = model.springValues(screen: screen) }
    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double) -> some View {
        SliderRow(title) {
            HStack {
                Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 / step).rounded() * step }), in: range) { e in
                    editing = e
                    if !e { model.setSpring(screen: screen, stiffness: v.stiffness, damping: v.damping, mass: v.mass) }
                }
                .accessibilityLabel(title).accessibilityValue(String(format: "%.1f", value.wrappedValue))
                Text(String(format: step < 1 ? "%.1f" : "%.0f", value.wrappedValue)).sliderValueLabel()
                Color.clear.frame(width: EditorMetrics.resetSlot, height: 1)
            }
        }
    }
}
