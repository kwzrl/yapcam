import SwiftUI
import YapcamCore
import YapcamDesign

/// "Camera layout": Overlay / Cutout / Split with their own controls, plus hiding the camera during silence.
struct CameraLayoutSettings: View {
    @ObservedObject var model: EditorModel
    private var mode: String { model.string("camera.layout_settings.mode", default: "overlay") }
    private let p = "camera.layout_settings."

    var body: some View {
        InspectorGroup("Camera", first: true) {
            ToggleRow(model: model, title: "Show camera", path: "camera.visible", defaultValue: true)
            ToggleRow(model: model, title: "Mirror camera", path: "camera.mirrored", defaultValue: true)
            ChoiceRow("Layout", selection: Binding(get: { mode }, set: { model.setCameraLayoutMode($0) }),
                      options: [("Overlay", "overlay"), ("Cutout", "cutout"), ("Split", "split")])
        }
        switch mode {
        case "cutout": InspectorGroup("Cutout") { cutout }
        case "split": InspectorGroup("Split") { split }
        default: InspectorGroup("Overlay") { overlay }
        }
        InspectorGroup("Silence") { CameraSilenceRows(model: model) }
    }

    @ViewBuilder private var overlay: some View {
        CameraPositionRow(model: model)
        ChoiceRow("Aspect", selection: Binding(get: { aspectKey }, set: { setAspect($0) }),
                  options: [("Same as the camera", "none"), ("16:9", "16:9"), ("4:3", "4:3"), ("1:1", "1:1"), ("3:4", "3:4"), ("9:16", "9:16"), ("Custom…", "custom")], forceMenu: true)
        if aspectKey == "custom" {
            NumberRow(model: model, title: "Width ÷ height", path: p + "aspect", range: 0.4...3, format: "%.2f", defaultValue: 1)
        }
        NumberRow(model: model, title: "Size", path: "camera.size", range: 0.1...0.75, unit: "%", format: "%.0f", scale: 100, defaultValue: 0.22)
        SwitchRow("Make smaller during zoom", isOn: Binding(get: { model.number("camera.zoom_scale", default: 1) < 0.999 },
                                                            set: { model.set("camera.zoom_scale", number: $0 ? 0.6 : 1) }))
        if model.number("camera.zoom_scale", default: 1) < 0.999 {
            NumberRow(model: model, title: "Size while zoomed", path: "camera.zoom_scale", range: 0.25...0.8, unit: "%", format: "%.0f", scale: 100, defaultValue: 0.6)
        }
        avoidEmpty
    }

    @ViewBuilder private var cutout: some View {
        ChoiceRow("Position", selection: Binding(get: { cutoutPosition }, set: { model.set(p + "cutout_position", .array([.number($0), .number(1)])) }),
                  options: [("Left", 0.0), ("Center", 0.5), ("Right", 1.0)])
        NumberRow(model: model, title: "Size", path: p + "cutout_size", range: 0.2...1, unit: "%", format: "%.0f", scale: 100, defaultValue: 0.5)
        NumberRow(model: model, title: "Edge softness", path: p + "edge_softness", range: 0...1, defaultValue: 0.2)
        NumberRow(model: model, title: "Edge inset", path: p + "edge_inset", range: 0...8, unit: "px", format: "%.0f", defaultValue: 0)
        avoidEmpty
    }

    @ViewBuilder private var split: some View {
        ChoiceRow("Ratio", selection: Binding(get: { ratioKey }, set: { setRatio($0) }), options: [("Auto", "auto"), ("½", "half"), ("⅔", "twoThirds")])
        ChoiceRow("Direction", selection: Binding(get: { model.string(p + "split_direction", default: "auto") }, set: { model.set(p + "split_direction", string: $0) }),
                  options: [("Auto", "auto"), ("Horizontal", "horizontal"), ("Vertical", "vertical")])
        ToggleRow(model: model, title: "Flip sides", path: p + "split_flip")
        ToggleRow(model: model, title: "Padded", path: p + "split_padded")
    }

    @ViewBuilder private var avoidEmpty: some View {
        ToggleRow(model: model, title: "Avoid empty area", path: "canvas.avoid_empty_zoom_area")
        InspectorNote("Keeps a zoom from showing empty background around the screen.")
    }

    // MARK: stored values ↔ menu keys
    private var aspectKey: String {
        guard case .number(let v)? = model.value(p + "aspect") else { return "none" }
        return CameraAspect.key(for: v)
    }
    private func setAspect(_ k: String) {
        let values: [String: Double] = ["16:9": 16.0 / 9, "4:3": 4.0 / 3, "1:1": 1, "3:4": 0.75, "9:16": 9.0 / 16]
        if k == "custom" { let v = model.number(p + "aspect", default: 1); model.set(p + "aspect", .number(min(3, v + 0.01))); return }   // MKT-138
        model.set(p + "aspect", values[k].map { .number($0) } ?? .null)
    }
    private var ratioKey: String {
        guard case .number(let v)? = model.value(p + "split_ratio") else { return "auto" }
        return abs(v - 0.5) < 0.01 ? "half" : "twoThirds"
    }
    private func setRatio(_ k: String) { model.set(p + "split_ratio", k == "auto" ? .null : .number(k == "half" ? 0.5 : 2.0 / 3)) }
    private var cutoutPosition: Double {
        let c = model.numbers(p + "cutout_position"); let x = c.first ?? 1
        return [0.0, 0.5, 1.0].min { abs($0 - x) < abs($1 - x) } ?? 1
    }
}

/// Hiding the camera while nobody speaks: the switch, the minimum silence, and the analysis behind it.
private struct CameraSilenceRows: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        SwitchRow("Hide the camera during silence", isOn: Binding(get: { model.bool("camera.hide_during_silence") }, set: { model.setHideDuringSilence($0) }))
        if model.bool("camera.hide_during_silence") {
            DurationRow(model: model, title: "After silence of", path: "camera.min_silence_ns", default: 5_000_000_000, range: 2...15)
            switch model.silenceRangesState {
            case .working: InspectorBusy("Analyzing the microphone…")
            case .failed(let m): InspectorNote(m, symbol: "exclamationmark.triangle")
            case .idle: InspectorInfo("Silent stretches", "\(model.cameraSilenceCount)")
            }
            InspectorAction("Analyze again", symbol: "arrow.clockwise") { model.refreshCameraSilence() }
        }
    }
}

/// Silent stretches of the microphone, as timeline ranges core uses to hide the camera.
extension EditorModel {
    public enum SilenceRangesState: Equatable { case idle, working, failed(String) }

    public var cameraSilenceCount: Int { if case .array(let a)? = value("camera.silence_ranges") { a.count } else { 0 } }

    public func setHideDuringSilence(_ on: Bool) {
        set("camera.hide_during_silence", bool: on)
        if on { refreshCameraSilence() }
    }

    /// Re-analyzes the microphone and stores the silent stretches (merged, sorted) in `camera.silence_ranges`.
    public func refreshCameraSilence() {
        guard silenceRangesState != .working, !isClosed else { return }
        silenceRangesState = .working
        let started = revision
        silenceRangesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let spans = Self.merged(try await project.silentSpans())
                guard !isClosed, !Task.isCancelled else { return }
                // Timeline coordinates are only valid for the revision they were measured on.
                guard revision == started else { silenceRangesState = .idle; refreshCameraSilence(); return }
                let rows: [JSONValue] = spans.map { .object(["tl_start_ns": .number(Double($0.startNs)), "tl_end_ns": .number(Double($0.endNs))]) }
                set("camera.silence_ranges", .array(rows))
                silenceRangesState = lastError == nil ? .idle : .failed(lastError ?? "")
            } catch { if !isClosed { silenceRangesState = .failed(error.localizedDescription) } }
        }
    }
    public func waitForCameraSilence() async { await silenceRangesTask?.value }
}

/// Per-section camera layout settings: off = the section uses the camera layout settings above; on = its own copy.
struct LayoutOwnSettings: View {
    @ObservedObject var model: EditorModel
    let layout: LayoutSegment
    private func num(_ k: String, _ d: Double) -> Double { if case .number(let v)? = layout.settings?[k] { v } else { d } }
    private func flag(_ k: String) -> Bool { if case .bool(let v)? = layout.settings?[k] { v } else { false } }
    private func slider(_ title: String, _ key: String, _ range: ClosedRange<Double>, _ d: Double, pct: Bool = false, unit: String = "") -> some View {
        CommitSlider(title: title, range: range, get: { num(key, d) }, commit: { model.setLayoutSetting(id: layout.id, key: key, .number($0)) },
                     text: { v in pct ? "\(Int((v * 100).rounded())) %" : String(format: unit.isEmpty ? "%.2f" : "%.0f", v) + (unit.isEmpty ? "" : " \(unit)") })
    }
    var body: some View {
        if layout.mode == "overlay" { LayoutPlacementRows(model: model, layout: layout) }
        SwitchRow("Own settings for this section", isOn: Binding(get: { layout.settings != nil }, set: { model.setLayoutOwnSettings(id: layout.id, $0) }))
        if layout.settings != nil {
            switch layout.mode {
            case "cutout":
                slider("Size", "cutout_size", 0.2...1, 0.5, pct: true)
                slider("Edge softness", "edge_softness", 0...1, 0.2)
                slider("Edge inset", "edge_inset", 0...8, 0, unit: "px")
            case "split": splitRows
            default: EmptyView()
            }
        }
    }
    @ViewBuilder private var splitRows: some View {
        ChoiceRow("Ratio", selection: Binding(get: { ratioKey }, set: { k in
            model.setLayoutSetting(id: layout.id, key: "split_ratio", k == "auto" ? .null : .number(k == "half" ? 0.5 : 2.0 / 3)) }),
                  options: [("Auto", "auto"), ("½", "half"), ("⅔", "twoThirds")])
        ChoiceRow("Direction", selection: Binding(get: { if case .string(let s)? = layout.settings?["split_direction"] { s } else { "auto" } },
                                                  set: { model.setLayoutSetting(id: layout.id, key: "split_direction", .string($0)) }),
                  options: [("Auto", "auto"), ("Horizontal", "horizontal"), ("Vertical", "vertical")])
        SwitchRow("Flip sides", isOn: Binding(get: { flag("split_flip") }, set: { model.setLayoutSetting(id: layout.id, key: "split_flip", .bool($0)) }))
        SwitchRow("Padded", isOn: Binding(get: { flag("split_padded") }, set: { model.setLayoutSetting(id: layout.id, key: "split_padded", .bool($0)) }))
    }
    private var ratioKey: String {
        guard case .number(let v)? = layout.settings?["split_ratio"] else { return "auto" }
        return abs(v - 0.5) < 0.01 ? "half" : "twoThirds"
    }
}


/// The overlay camera's aspect presets; any other ratio is "custom" (MKT-138).
enum CameraAspect {
    static func key(for v: Double) -> String {
        [("16:9", 16.0 / 9), ("4:3", 4.0 / 3), ("1:1", 1), ("3:4", 0.75), ("9:16", 9.0 / 16)].first { abs($0.1 - v) < 0.005 }?.0 ?? "custom"
    }
}
