import SwiftUI
import YapcamCore
import YapcamDesign

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
    /// clamped to what core accepts. `preset` is the named screen style to store (`animation_style`); nil means hand-tuned values
    /// ("custom"). A named preset is never overwritten by "custom" (BS-4).
    public func setSpring(screen: Bool, stiffness: Double, damping: Double, mass: Double, preset: String? = nil) {
        let prefix = screen ? "zoom_settings" : "cursor"
        let spring: JSONValue = .object(["tension": .number(min(max(stiffness, 5), 600)), "friction": .number(min(max(damping, 5), 200)),
                                         "mass": .number(min(max(mass, 0.1), 10)), "allow_overshoot": .bool(false)])
        var cmds: [EditorCommand] = [.set(path: "\(prefix).spring", value: spring), .set(path: "\(prefix).speed_preset", value: .string("custom"))]
        if screen { cmds.append(.set(path: "zoom_settings.animation_style", value: .string(preset ?? "custom"))) }
        else if number("cursor.smoothing") == 0 { cmds.append(.set(path: "cursor.smoothing", value: .number(0.15))) }
        perform(.batch(cmds))
    }

    /// Cursor animation "None": raw cursor movement.
    public func setCursorAnimationNone() { set("cursor.smoothing", number: 0) }

    /// Applies a cursor animation preset by id ("smooth", "medium", "rapid", "none"). Shared by Animations and the Cursor section (BS-2).
    public func chooseCursorAnimation(_ id: String) {
        if id == "none" { setCursorAnimationNone(); return }
        guard let p = SpringPreset.cursor.first(where: { $0.id == id }) else { return }
        setSpring(screen: false, stiffness: p.stiffness, damping: p.damping, mass: p.mass, preset: p.id)
    }

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

/// "Animations" inspector section: screen and cursor spring presets with Customize, the zoom settings, one motion-blur slider.
struct AnimationsSection: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AnimationPresets(model: model)
            InspectorGroup("Zooms") { zooms }
            InspectorGroup("Motion blur") {
                NumberRow(model: model, title: "Motion blur", path: "canvas.motion_blur", range: 0...1, defaultValue: model.factoryMotionBlur)
                InspectorNote("One strength for zoom, screen movement and cursor.")
                InspectorMore("Advanced motion blur settings") {
                    NumberRow(model: model, title: "Cursor movement", path: "cursor.motion_blur", range: 0...1)
                    InheritedBlurRow(model: model, title: "Screen zooming in", path: "canvas.motion_blur_settings.zoom")
                    InspectorNote("Blur while zooming in or out.")
                    InheritedBlurRow(model: model, title: "Screen moving", path: "canvas.motion_blur_settings.pan")
                    InspectorNote("Blur panning while zoomed, not zooming.")
                }
            }
        }
    }

    @ViewBuilder private var zooms: some View {
        if model.hasMouseData {        // automatic zooms and cursor following both need recorded mouse data
            ToggleRow(model: model, title: "Automatic zooms", path: "zoom_settings.automatic", defaultValue: true)
            ToggleRow(model: model, title: "Follow cursor while zoomed", path: "zoom_settings.follow_cursor", defaultValue: true)
        }
        PickerRow(model: model, title: "Transition speed", path: "zoom_settings.speed_preset", options: inspectorSpeedPresets)
        ToggleRow(model: model, title: "Start animation early", path: "zoom_settings.start_early")
        NumberRow(model: model, title: "Default zoom level", path: "zoom_settings.default_scale", range: 1...4, unit: "×", format: "%.1f", defaultValue: 2)
        if model.hasMouseData { InspectorAction("Regenerate automatic zooms", symbol: "arrow.clockwise") { model.regenerateAutoZooms() } }
    }
}

/// Screen and cursor spring presets as segment switches, the active one's hint below, "Customize" behind a click.
struct AnimationPresets: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        InspectorGroup("Screen animation", first: true) { group(screen: true, presets: SpringPreset.screen, offersNone: false) }
        InspectorGroup("Cursor animation") { group(screen: false, presets: SpringPreset.cursor, offersNone: true) }
    }

    @ViewBuilder private func group(screen: Bool, presets: [SpringPreset], offersNone: Bool) -> some View {
        let active = model.activePreset(screen: screen) ?? ""
        let items = presets.map { (id: $0.id, title: $0.title) } + (offersNone ? [(id: "none", title: "None")] : [])
        SegmentSwitch(items, selection: Binding(get: { active }, set: { id in choose(id, screen: screen, presets: presets) }), height: 26)
            .padding(.horizontal, -4)
            .accessibilityLabel(screen ? "Screen animation" : "Cursor animation")
        InspectorNote(hint(active, presets: presets))
        if active != "none" { SpringSliders(model: model, screen: screen, defaultPreset: presets[0]) }
    }

    private func hint(_ active: String, presets: [SpringPreset]) -> String {
        if active == "none" { return "Raw cursor movement" }
        return presets.first { $0.id == active }?.hint ?? "Custom: your own values"
    }

    private func choose(_ id: String, screen: Bool, presets: [SpringPreset]) {
        if !screen { model.chooseCursorAnimation(id); return }
        guard let p = presets.first(where: { $0.id == id }) else { return }
        model.setSpring(screen: true, stiffness: p.stiffness, damping: p.damping, mass: p.mass, preset: p.id)
    }
}

/// "Customize": stiffness, damping, mass; commits on release (one undo step), Reset returns to the first preset.
struct SpringSliders: View {
    @ObservedObject var model: EditorModel
    let screen: Bool
    let defaultPreset: SpringPreset
    var body: some View {
        InspectorMore("Customize") {
            slider("Rigidity", 5...600, step: 1, \.stiffness)
            slider("Smoothness", 5...200, step: 1, \.damping)
            slider("Momentum", 0.1...10, step: 0.1, \.mass)
            InspectorAction("Reset") { model.setSpring(screen: screen, stiffness: defaultPreset.stiffness, damping: defaultPreset.damping, mass: defaultPreset.mass, preset: defaultPreset.id) }
                .disabled(model.activePreset(screen: screen) == defaultPreset.id)
        }
    }
    private func slider(_ title: String, _ range: ClosedRange<Double>, step: Double,
                        _ key: WritableKeyPath<SpringValues, Double>) -> some View {
        CommitSlider(title: title, range: range, get: { SpringValues(model.springValues(screen: screen))[keyPath: key] },
                     commit: { v in var s = SpringValues(model.springValues(screen: screen)); s[keyPath: key] = v
                               model.setSpring(screen: screen, stiffness: s.stiffness, damping: s.damping, mass: s.mass) },
                     text: { String(format: step < 1 ? "%.1f" : "%.0f", $0) }, step: step)
    }
}

/// Mutable copy of a spring (stiffness, damping, mass).
struct SpringValues {
    var stiffness: Double, damping: Double, mass: Double
    init(_ v: (stiffness: Double, damping: Double, mass: Double)) { stiffness = v.stiffness; damping = v.damping; mass = v.mass }
}

/// The one cursor-animation control in the Cursor section: mirrors Animations › Cursor animation (same model state).
/// Hand-tuned or legacy values show no segment as active; "Customize" lives only in Animations.
struct CursorAnimationRow: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        let items = SpringPreset.cursor.map { (id: $0.id, title: $0.title) } + [(id: "none", title: "None")]
        let active = model.activePreset(screen: false) ?? ""
        VStack(alignment: .leading, spacing: 4) {
            Text("Animation").font(.system(size: 11)).foregroundStyle(.secondary)
            SegmentSwitch(items, selection: Binding(get: { active }, set: { model.chooseCursorAnimation($0) }), height: 26)
                .padding(.horizontal, -4)
                .accessibilityLabel("Cursor animation")
            if active.isEmpty { InspectorNote("Custom values. Adjust them in Animations.") }
        }
    }
}
