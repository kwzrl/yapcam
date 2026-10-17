import SwiftUI
import YapcamCore

/// "Camera layout": Overlay / Cutout / Split with their own controls, plus hiding the camera during silence.
struct CameraLayoutSettings: View {
    @ObservedObject var model: EditorModel
    private var mode: String { model.string("camera.layout_settings.mode", default: "overlay") }
    private let p = "camera.layout_settings."

    var body: some View {
        Section("Camera") {
            ToggleRow(model: model, title: "Show camera", path: "camera.visible", defaultValue: true)
            Picker("Layout", selection: Binding(get: { mode }, set: { model.set(p + "mode", string: $0) })) {
                Text("Overlay").tag("overlay"); Text("Cutout").tag("cutout"); Text("Split").tag("split")
            }.pickerStyle(.segmented)
        }
        switch mode {
        case "cutout": cutout
        case "split": split
        default: overlay
        }
        Section("Silence") {
            Toggle("Hide the camera during silence", isOn: Binding(get: { model.bool("camera.hide_during_silence") }, set: { model.setHideDuringSilence($0) }))
            if model.bool("camera.hide_during_silence") {
                DurationRow(model: model, title: "After silence of", path: "camera.min_silence_ns", default: 5_000_000_000, range: 2...15)
                switch model.silenceRangesState {
                case .working: HStack { ProgressView().controlSize(.small); Text("Analyzing the microphone…") }
                case .failed(let m): Text(m).font(.caption).foregroundStyle(.red)
                case .idle: Text("\(model.cameraSilenceCount) silent stretch\(model.cameraSilenceCount == 1 ? "" : "es") found.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Analyze again") { model.refreshCameraSilence() }
            }
        }
    }

    @ViewBuilder private var overlay: some View {
        Section("Overlay") {
            CameraPositionRow(model: model)
            Picker("Aspect", selection: Binding(get: { aspectKey }, set: { setAspect($0) })) {
                Text("Same as the camera").tag("none"); Text("16:9").tag("16:9"); Text("4:3").tag("4:3"); Text("1:1").tag("1:1"); Text("3:4").tag("3:4"); Text("9:16").tag("9:16")
            }
            NumberRow(model: model, title: "Size", path: "camera.size", range: 0.1...0.75, unit: "%", format: "%.0f", scale: 100, defaultValue: 0.22)
            Toggle("Make smaller during zoom", isOn: Binding(get: { model.number("camera.zoom_scale", default: 1) < 0.999 },
                                                              set: { model.set("camera.zoom_scale", number: $0 ? 0.6 : 1) }))
            if model.number("camera.zoom_scale", default: 1) < 0.999 {
                NumberRow(model: model, title: "Size while zoomed", path: "camera.zoom_scale", range: 0.25...0.8, unit: "%", format: "%.0f", scale: 100, defaultValue: 0.6)
            }
        }
    }

    @ViewBuilder private var cutout: some View {
        Section("Cutout") {
            Picker("Position", selection: Binding(get: { cutoutPosition }, set: { model.set(p + "cutout_position", .array([.number($0), .number(1)])) })) {
                Text("Left").tag(0.0); Text("Center").tag(0.5); Text("Right").tag(1.0)
            }.pickerStyle(.segmented)
            NumberRow(model: model, title: "Size", path: p + "cutout_size", range: 0.2...1, unit: "%", format: "%.0f", scale: 100, defaultValue: 0.5)
            NumberRow(model: model, title: "Edge softness", path: p + "edge_softness", range: 0...1, defaultValue: 0.2)
            NumberRow(model: model, title: "Edge inset", path: p + "edge_inset", range: 0...8, unit: "px", format: "%.0f", defaultValue: 0)
        }
    }

    @ViewBuilder private var split: some View {
        Section("Split") {
            Picker("Ratio", selection: Binding(get: { ratioKey }, set: { setRatio($0) })) {
                Text("Auto").tag("auto"); Text("½").tag("half"); Text("⅔").tag("twoThirds")
            }.pickerStyle(.segmented)
            ToggleRow(model: model, title: "Flip sides", path: p + "split_flip")
            ToggleRow(model: model, title: "Padded", path: p + "split_padded")
        }
    }

    // MARK: stored values ↔ menu keys
    private var aspectKey: String {
        guard case .number(let v)? = model.value(p + "aspect") else { return "none" }
        return [("16:9", 16.0 / 9), ("4:3", 4.0 / 3), ("1:1", 1), ("3:4", 0.75), ("9:16", 9.0 / 16)].min { abs($0.1 - v) < abs($1.1 - v) }?.0 ?? "none"
    }
    private func setAspect(_ k: String) {
        let values: [String: Double] = ["16:9": 16.0 / 9, "4:3": 4.0 / 3, "1:1": 1, "3:4": 0.75, "9:16": 9.0 / 16]
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
    @State private var drag: [String: Double] = [:]        // local values while a slider is held; one commit on release
    private func slider(_ title: String, _ key: String, _ range: ClosedRange<Double>, _ d: Double, pct: Bool = false, unit: String = "") -> some View {
        SliderRow(title) {
            HStack {
                Slider(value: Binding(get: { drag[key] ?? num(key, d) }, set: { drag[key] = $0 }), in: range) { editing in
                    if !editing, let v = drag.removeValue(forKey: key) { model.setLayoutSetting(id: layout.id, key: key, .number(v)) }
                }.accessibilityLabel(title)
                let v = drag[key] ?? num(key, d)
                Text(pct ? "\(Int((v * 100).rounded())) %" : String(format: unit.isEmpty ? "%.2f" : "%.0f", v) + (unit.isEmpty ? "" : " \(unit)")).sliderValueLabel()
                Color.clear.frame(width: EditorMetrics.resetSlot, height: 1)
            }
        }
    }
    var body: some View {
        Toggle("Own settings for this section", isOn: Binding(get: { layout.settings != nil }, set: { model.setLayoutOwnSettings(id: layout.id, $0) }))
        if layout.settings != nil {
            switch layout.mode {
            case "cutout":
                slider("Size", "cutout_size", 0.2...1, 0.5, pct: true)
                slider("Edge softness", "edge_softness", 0...1, 0.2)
                slider("Edge inset", "edge_inset", 0...8, 0, unit: "px")
            case "split":
                Picker("Ratio", selection: Binding(get: { ratioKey }, set: { k in
                    model.setLayoutSetting(id: layout.id, key: "split_ratio", k == "auto" ? .null : .number(k == "half" ? 0.5 : 2.0 / 3)) })) {
                    Text("Auto").tag("auto"); Text("½").tag("half"); Text("⅔").tag("twoThirds")
                }.pickerStyle(.segmented)
                Toggle("Flip sides", isOn: Binding(get: { flag("split_flip") }, set: { model.setLayoutSetting(id: layout.id, key: "split_flip", .bool($0)) }))
                Toggle("Padded", isOn: Binding(get: { flag("split_padded") }, set: { model.setLayoutSetting(id: layout.id, key: "split_padded", .bool($0)) }))
            default:
                Text("Overlay position and size use the camera settings.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var ratioKey: String {
        guard case .number(let v)? = layout.settings?["split_ratio"] else { return "auto" }
        return abs(v - 0.5) < 0.01 ? "half" : "twoThirds"
    }
}
