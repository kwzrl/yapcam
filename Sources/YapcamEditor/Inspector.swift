import SwiftUI
import YapcamCore

// MARK: setting rows (all bound to project paths; sliders commit on release = one undo step)

struct NumberRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String
    let range: ClosedRange<Double>
    var unit = "", format = "%.2f", scale = 1.0      // scale: display = stored * scale
    @State private var value = 0.0
    @State private var editing = false

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range) { isEditing in
                    editing = isEditing
                    if !isEditing { model.set(path, number: value) }
                }
                Text(String(format: format, value * scale) + (unit.isEmpty ? "" : " \(unit)"))
                    .monospacedDigit().frame(width: 62, alignment: .trailing)
            }
        }
        .onAppear { value = model.number(path) }
        .onChange(of: model.revision) { _, _ in if !editing { value = model.number(path) } }
        .accessibilityElement(children: .combine)
    }
}

struct ToggleRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String
    var defaultValue = false
    var body: some View {
        Toggle(title, isOn: Binding(get: { model.bool(path, default: defaultValue) }, set: { model.set(path, bool: $0) }))
    }
}

struct PickerRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String
    let options: [(label: String, value: String)]
    var body: some View {
        Picker(title, selection: Binding(get: { model.string(path) }, set: { model.set(path, string: $0) })) {
            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
        }
    }
}

struct ColorRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String
    var body: some View {
        ColorPicker(title, selection: Binding(
            get: { let c = model.color(path); return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: c[3]) },
            set: { let n = NSColor($0).usingColorSpace(.sRGB) ?? .black
                   model.set(path, color: [n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent].map { Double($0) }) }),
                    supportsOpacity: false)
    }
}

// MARK: inspector

public enum AspectPreset: String, CaseIterable {
    case wide = "16:9", standard = "4:3", square = "1:1", vertical = "9:16", ultra = "21:9", source, custom
    var label: String { switch self { case .source: "Match source"; case .custom: "Custom"; default: rawValue } }
    var outputSize: [Double]? {
        switch self {
        case .wide: [1920, 1080]; case .standard: [1440, 1080]; case .square: [1080, 1080]
        case .vertical: [1080, 1920]; case .ultra: [2520, 1080]; default: nil
        }
    }
}

struct InspectorView: View {
    @ObservedObject var model: EditorModel
    @State private var tab: Tab
    init(model: EditorModel, initialTab: Tab = .appearance) { self.model = model; _tab = State(initialValue: initialTab) }
    enum Tab: String, CaseIterable { case appearance = "Look", overlays = "Overlays", cursor = "Cursor", camera = "Camera", audio = "Audio" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(10)
            Form {
                switch tab {
                case .appearance: appearance
                case .overlays: overlays
                case .cursor: cursor
                case .camera: camera
                case .audio: audio
                }
            }.formStyle(.grouped)
        }
        .onChange(of: model.selection) { _, s in
            switch s {
            case .zoom, .clip: tab = .appearance
            case .layout: tab = .camera
            case .cursorHide: tab = .cursor
            case .highlight: tab = .overlays
            case .none: break
            }
        }
    }

    @ViewBuilder private var appearance: some View {
        if let z = model.selectedZoom { zoomSection(z) }
        if case .clip(let id) = model.selection, let c = model.clips.first(where: { $0.id == id }) { speedSection(c) }
        Section("Zooms") {
            ToggleRow(model: model, title: "Automatic zooms", path: "zoom_settings.automatic", defaultValue: true)
            ToggleRow(model: model, title: "Follow cursor while zoomed", path: "zoom_settings.follow_cursor", defaultValue: true)
            PickerRow(model: model, title: "Transition speed", path: "zoom_settings.speed_preset", options: speedPresets)
            Button("Regenerate automatic zooms") { model.regenerateAutoZooms() }
        }
        Section("Background") {
            PickerRow(model: model, title: "Type", path: "canvas.background.kind",
                      options: [("Solid", "solid"), ("Gradient", "gradient"), ("Blurred screen", "blurred_screen")])
            ColorRow(model: model, title: model.string("canvas.background.kind") == "gradient" ? "From" : "Color", path: "canvas.background.color")
            if model.string("canvas.background.kind") == "gradient" {
                ColorRow(model: model, title: "To", path: "canvas.background.color2")
                NumberRow(model: model, title: "Angle", path: "canvas.background.angle_deg", range: 0...360, unit: "°", format: "%.0f")
            }
            if model.string("canvas.background.kind") == "blurred_screen" {
                NumberRow(model: model, title: "Blur", path: "canvas.background.blur", range: 0...80, format: "%.0f")
            }
        }
        Section("Frame") {
            Picker("Aspect ratio", selection: Binding(get: { AspectPreset(rawValue: model.string("canvas.aspect")) ?? .custom },
                                                       set: { model.setAspect($0) })) {
                ForEach(AspectPreset.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            NumberRow(model: model, title: "Padding", path: "canvas.padding", range: 0...200, unit: "pt", format: "%.0f")
            NumberRow(model: model, title: "Corner radius", path: "canvas.radius", range: 0...64, unit: "pt", format: "%.0f")
            NumberRow(model: model, title: "Shadow", path: "canvas.shadow.opacity", range: 0...1)
            NumberRow(model: model, title: "Shadow blur", path: "canvas.shadow.radius", range: 0...80, unit: "pt", format: "%.0f")
            NumberRow(model: model, title: "Inset", path: "canvas.inset", range: 0...24, unit: "pt", format: "%.0f")
            if model.number("canvas.inset") > 0 { ColorRow(model: model, title: "Inset color", path: "canvas.inset_color") }
            NumberRow(model: model, title: "Zoom motion blur", path: "canvas.motion_blur", range: 0...1)
            ToggleRow(model: model, title: "Window frame", path: "canvas.window_chrome")
            NumberRow(model: model, title: "Background noise", path: "canvas.background.noise", range: 0...1)
        }
        CropSection(model: model)
    }

    @ViewBuilder private var overlays: some View {
        Section("Masks and highlights") {
            if case .highlight(let id) = model.selection, let h = model.highlights.first(where: { $0.id == id }) { HighlightControls(model: model, region: h) }
            HStack {
                Button("Highlight") { model.addHighlightAtPlayhead(kind: .highlight) }
                Button("Spotlight") { model.addHighlightAtPlayhead(kind: .spotlight) }
                Button("Mask") { model.addHighlightAtPlayhead(kind: .mask) }
            }
            Text("Adds a 3 s region at the playhead. Drag its box in the preview; drag the yellow bar on the timeline to retime it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Intro and outro") {
            Picker("Intro", selection: Binding(get: { model.string("canvas.animation.entrance", default: "none") }, set: { model.set("canvas.animation.entrance", string: $0) })) {
                Text("None").tag("none"); Text("Fade in").tag("fade")
            }
            if model.string("canvas.animation.entrance", default: "none") == "fade" {
                DurationRow(model: model, title: "Intro length", path: "canvas.animation.entrance_duration_ns")
            }
            Picker("Outro", selection: Binding(get: { model.string("canvas.animation.exit", default: "none") }, set: { model.set("canvas.animation.exit", string: $0) })) {
                Text("None").tag("none"); Text("Fade out").tag("fade")
            }
            if model.string("canvas.animation.exit", default: "none") == "fade" {
                DurationRow(model: model, title: "Outro length", path: "canvas.animation.exit_duration_ns")
            }
        }
    }

    private var speedPresets: [(label: String, value: String)] {
        [("Custom", "custom"), ("Slow", "slow"), ("Mellow", "mellow"), ("Quick", "quick"), ("Rapid", "rapid")]
    }

    private func zoomSection(_ z: TimelineZoom) -> some View {
        Section(z.mode == .auto ? "Zoom (automatic)" : "Zoom") {
            LabeledContent("Start") { Text(formatTimecode(z.startNs)).monospacedDigit() }
            LabeledContent("Duration") { Text(formatTimecode(z.endNs - z.startNs)).monospacedDigit() }
            ZoomScaleRow(model: model, zoom: z)
            LabeledContent("Focus") { Text(String(format: "%.0f%%, %.0f%%", z.focusX * 100, z.focusY * 100)).monospacedDigit() }
            Text("Click in the preview to set the focus point.").font(.caption).foregroundStyle(.secondary)
            Picker("Mode", selection: Binding(get: { z.mode }, set: { model.setZoomMode(id: z.id, $0) })) {
                Text("Automatic").tag(TimelineZoom.Mode.auto); Text("Manual").tag(TimelineZoom.Mode.manual)
            }
            Toggle("Instant (no easing)", isOn: Binding(get: { z.easeInNs == 0 && z.easeOutNs == 0 },
                                                         set: { model.setZoomEase(id: z.id, inNs: $0 ? 0 : 300_000_000, outNs: $0 ? 0 : 300_000_000) }))
            Toggle("Enabled", isOn: Binding(get: { z.enabled }, set: { model.setZoomEnabled(id: z.id, $0) }))
            Button("Delete zoom", role: .destructive) { model.deleteSelection() }
        }
    }

    private func speedSection(_ c: TimelineClip) -> some View {
        Section("Clip speed") {
            Picker("Speed", selection: Binding(get: { c.speed }, set: { model.setSpeed(clipID: c.id, $0) })) {
                ForEach([0.25, 0.5, 1, 1.5, 2, 4, 8], id: \.self) { Text($0 == 1 ? "Normal" : "\($0.formatted())×").tag($0) }
                if ![0.25, 0.5, 1, 1.5, 2, 4, 8].contains(c.speed) { Text("\(c.speed.formatted(.number.precision(.fractionLength(0...2))))×").tag(c.speed) }
            }
        }
    }

    @ViewBuilder private var cursor: some View {
        Section("Cursor") {
            ToggleRow(model: model, title: "Show cursor", path: "cursor.visible", defaultValue: true)
            NumberRow(model: model, title: "Size", path: "cursor.size", range: 0.5...4, unit: "×")
            NumberRow(model: model, title: "Smoothing", path: "cursor.smoothing", range: 0...1)
            PickerRow(model: model, title: "Movement speed", path: "cursor.speed_preset", options: speedPresets)
            ToggleRow(model: model, title: "Hide when idle", path: "cursor.hide_when_idle")
            PickerRow(model: model, title: "Click effect", path: "cursor.click_effect",
                      options: [("None", "none"), ("Ring", "ring"), ("Highlight", "highlight")])
            ToggleRow(model: model, title: "Loop cursor to start", path: "cursor.loop_to_start")
            PickerRow(model: model, title: "Cursor style", path: "cursor.style",
                      options: [("Recorded", "recorded"), ("Pointer", "pointer"), ("Touch", "touch")])
            NumberRow(model: model, title: "Motion blur", path: "cursor.motion_blur", range: 0...1)
            NumberRow(model: model, title: "Spotlight radius", path: "cursor.spotlight_radius", range: 0...600, unit: "px", format: "%.0f")
        }
        Section("Hidden sections") {
            if case .cursorHide(let i) = model.selection, let h = model.cursorHides.first(where: { $0.index == i }) {
                LabeledContent("Hidden") { Text("\(formatTimecode(h.span.startNs)) – \(formatTimecode(h.span.endNs))").monospacedDigit() }
                Button("Show cursor again", role: .destructive) { model.deleteSelection() }
            }
            Button("Hide cursor from playhead") { model.addCursorHideAtPlayhead() }
            Text("Drag a gray section on the timeline to move or resize it.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var camera: some View {
        if model.value("camera") == nil || !model.hasCamera {
            Section("Camera") { Text("This recording has no camera track.").foregroundStyle(.secondary) }
        } else {
            Section("Camera") {
                ToggleRow(model: model, title: "Show camera", path: "camera.visible", defaultValue: true)
                PickerRow(model: model, title: "Shape", path: "camera.shape",
                          options: [("Rounded rectangle", "rounded_rect"), ("Circle", "circle"), ("Squircle", "squircle")])
                NumberRow(model: model, title: "Size", path: "camera.size", range: 0.05...0.6, unit: "%", format: "%.0f", scale: 100)
                NumberRow(model: model, title: "Corner radius", path: "camera.radius", range: 0...64, unit: "pt", format: "%.0f")
                NumberRow(model: model, title: "Opacity", path: "camera.opacity", range: 0...1)
                ToggleRow(model: model, title: "Mirror", path: "camera.mirrored", defaultValue: true)
                NumberRow(model: model, title: "Shadow", path: "camera.shadow_radius", range: 0...60, unit: "pt", format: "%.0f")
                ToggleRow(model: model, title: "Remove background", path: "camera.background_removal")
                ToggleRow(model: model, title: "Frame face", path: "camera.face_framing")
                CameraPositionRow(model: model)
            }
            Section("Layout over time") {
                if case .layout(let id) = model.selection, let l = model.layouts.first(where: { $0.id == id }) {
                    Picker("Layout", selection: Binding(get: { l.mode }, set: { model.setLayoutMode(id: l.id, $0) })) {
                        ForEach(layoutModes, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    LabeledContent("Time") { Text("\(formatTimecode(l.startNs)) – \(formatTimecode(l.endNs))").monospacedDigit() }
                    Button("Remove layout", role: .destructive) { model.deleteSelection() }
                }
                Button("Add layout at playhead") { model.addLayoutAtPlayhead() }
                Text("Outside layout sections the default camera settings apply.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var audio: some View {
        Section("Automatic edits") {
            Button("Speed up typing") { model.speedUpTyping() }
            switch model.silenceState {
            case .idle: Button("Find silent parts…") { model.findSilences() }
            case .analyzing: HStack { ProgressView().controlSize(.small); Text("Analyzing audio…") }
            case .found(let spans):
                if spans.isEmpty { Text("No silent parts found.").foregroundStyle(.secondary); Button("OK") { model.dismissSilences() } }
                else {
                    let total = Double(spans.reduce(0) { $0 + $1.durationNs }) / 1e9
                    Text("\(spans.count) silent parts, \(String(format: "%.1f", total)) s in total")
                    HStack {
                        Button("Cut them") { model.applySilences(speed: nil) }
                        Button("Speed up 4×") { model.applySilences(speed: 4) }
                        Button("Dismiss") { model.dismissSilences() }
                    }
                }
            case .failed(let msg): Text(msg).foregroundStyle(.red); Button("OK") { model.dismissSilences() }
            }
        }
        Section("System audio") {
            ToggleRow(model: model, title: "Mute", path: "audio.system_muted")
            NumberRow(model: model, title: "Volume", path: "audio.system_gain_db", range: -48...12, unit: "dB", format: "%.0f")
        }
        Section("Volume changes over time") {
            ForEach(model.audioRanges) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(r.track == "mic" ? "Microphone" : "System audio").font(.callout.weight(.medium))
                        Spacer()
                        Text("\(formatTimecode(r.span.startNs, showFraction: false)) – \(formatTimecode(r.span.endNs, showFraction: false))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button(role: .destructive) { model.removeAudioRange(id: r.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove volume change")
                    }
                    HStack {
                        Stepper("From \(Int(r.startGainDb)) dB", value: Binding(get: { r.startGainDb }, set: { model.updateAudioRange(id: r.id, startGainDb: $0) }), in: -96...24, step: 3)
                        Stepper("To \(Int(r.endGainDb)) dB", value: Binding(get: { r.endGainDb }, set: { model.updateAudioRange(id: r.id, endGainDb: $0) }), in: -96...24, step: 3)
                    }.font(.caption)
                }
            }
            HStack {
                Button("Lower system audio here") { model.addAudioRangeAtPlayhead(track: "system_audio") }
                if model.hasMic { Button("Lower mic here") { model.addAudioRangeAtPlayhead(track: "mic") } }
            }
        }
        Section("Microphone") {
            if model.hasMic {
                ToggleRow(model: model, title: "Mute", path: "audio.mic_muted")
                NumberRow(model: model, title: "Volume", path: "audio.mic_gain_db", range: -48...12, unit: "dB", format: "%.0f")
            } else { Text("This recording has no microphone track.").foregroundStyle(.secondary) }
        }
    }
}

struct ZoomScaleRow: View {
    @ObservedObject var model: EditorModel
    let zoom: TimelineZoom
    @State private var value = 2.0
    @State private var editing = false
    var body: some View {
        LabeledContent("Scale") {
            HStack {
                Slider(value: $value, in: 1...6) { e in editing = e; if !e { model.setZoomScale(id: zoom.id, value) } }
                Text(String(format: "%.1f×", value)).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
        .onAppear { value = zoom.scale }
        .onChange(of: zoom.scale) { _, v in if !editing { value = v } }
        .onChange(of: zoom.id) { _, _ in value = zoom.scale }
    }
}

struct CameraPositionRow: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        let corners: [(String, [Double])] = [("↖", [0.18, 0.22]), ("↗", [0.82, 0.22]), ("↙", [0.18, 0.78]), ("↘", [0.82, 0.78])]
        LabeledContent("Position") {
            HStack {
                ForEach(corners, id: \.0) { c in
                    Button(c.0) { model.set("camera.position", .array(c.1.map { .number($0) })) }
                        .buttonStyle(.bordered).accessibilityLabel("Camera corner \(c.0)")
                }
            }
        }
    }
}

struct CropSection: View {
    @ObservedObject var model: EditorModel
    @State private var l = 0.0
    @State private var t = 0.0
    @State private var r = 0.0
    @State private var b = 0.0
    @State private var editing = false
    var body: some View {
        Section("Crop recording") {
            row("Left", $l); row("Top", $t); row("Right", $r); row("Bottom", $b)
            Button("Reset crop") { l = 0; t = 0; r = 0; b = 0; model.setCrop(left: 0, top: 0, right: 0, bottom: 0) }
                .disabled(l + t + r + b == 0)
        }
        .onAppear(perform: load)
        .onChange(of: model.revision) { _, _ in if !editing { load() } }
    }
    private func load() { let c = model.cropInsets; l = c.left; t = c.top; r = c.right; b = c.bottom }
    private func row(_ title: String, _ v: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: v, in: 0...0.9) { e in editing = e; if !e { model.setCrop(left: l, top: t, right: r, bottom: b) } }
                Text("\(Int(v.wrappedValue * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }
}

struct DurationRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String
    @State private var seconds = 0.4
    @State private var editing = false
    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $seconds, in: 0.1...3) { e in editing = e; if !e { model.set(path, number: (seconds * 1e9).rounded()) } }
                Text(String(format: "%.1f s", seconds)).monospacedDigit().frame(width: 46, alignment: .trailing)
            }
        }
        .onAppear { seconds = model.number(path, default: 400_000_000) / 1e9 }
        .onChange(of: model.revision) { _, _ in if !editing { seconds = model.number(path, default: 400_000_000) / 1e9 } }
    }
}

struct HighlightControls: View {
    @ObservedObject var model: EditorModel
    let region: HighlightRegion
    var body: some View {
        let id = region.id
        Picker("Style", selection: Binding(get: { region.kind }, set: { model.setHighlightKind(id: id, $0) })) {
            ForEach(HighlightRegion.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker("Follows", selection: Binding(get: { region.space }, set: { v in model.updateHighlight(id: id) { $0.space = v } })) {
            Text("Screen (zoom/crop)").tag("source"); Text("Canvas (fixed)").tag("canvas")
        }
        LabeledContent("Time") { Text("\(formatTimecode(region.startNs)) – \(formatTimecode(region.endNs))").monospacedDigit() }
        regionColor("Fill", get: { region.fill }, set: { c in model.updateHighlight(id: id) { $0.fill = c } })
        if region.kind != .mask { regionColor("Outline", get: { region.stroke }, set: { c in model.updateHighlight(id: id) { $0.stroke = c } }) }
        Stepper("Outline width \(Int(region.strokeWidth)) pt", value: Binding(get: { region.strokeWidth }, set: { v in model.updateHighlight(id: id) { $0.strokeWidth = v } }), in: 0...16)
        Stepper("Corner radius \(Int(region.radius)) pt", value: Binding(get: { region.radius }, set: { v in model.updateHighlight(id: id) { $0.radius = v } }), in: 0...64, step: 2)
        if region.kind != .mask {
            Stepper("Dim outside \(Int(region.dimOpacity * 100))%", value: Binding(get: { region.dimOpacity }, set: { v in model.updateHighlight(id: id) { $0.dimOpacity = min(max(v, 0), 1) } }), in: 0...1, step: 0.1)
        }
        Button("Remove region", role: .destructive) { model.deleteSelection() }
    }
    private func regionColor(_ title: String, get: @escaping () -> [Double], set: @escaping ([Double]) -> Void) -> some View {
        ColorPicker(title, selection: Binding(
            get: { let c = get(); return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: 1) },
            set: { let n = NSColor($0).usingColorSpace(.sRGB) ?? .black
                   let alpha = get()[3]; set([Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent), alpha == 0 ? 0.3 : alpha]) }),
                    supportsOpacity: false)
    }
}
