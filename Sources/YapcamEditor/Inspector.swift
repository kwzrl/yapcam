import SwiftUI
import UniformTypeIdentifiers
import YapcamCore

// MARK: setting rows (all bound to project paths; sliders commit on release = one undo step)

struct NumberRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String
    let range: ClosedRange<Double>
    var unit = "", format = "%.2f", scale = 1.0      // scale: display = stored * scale
    var defaultValue: Double? = nil                  // shows a reset button when the value differs
    @State private var value = 0.0
    @State private var editing = false

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range) { isEditing in
                    editing = isEditing
                    if !isEditing { model.set(path, number: value) }
                }
                    .accessibilityLabel(title)
                    .accessibilityValue(String(format: format, value * scale) + (unit.isEmpty ? "" : " \(unit)"))
                Text(String(format: format, value * scale) + (unit.isEmpty ? "" : " \(unit)"))
                    .monospacedDigit().frame(width: 62, alignment: .trailing).accessibilityHidden(true)
                if let d = defaultValue {
                    Button { value = d; model.set(path, number: d) } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless).help("Reset to default").accessibilityLabel("Reset \(title)")
                        .opacity(abs(value - d) > 1e-9 ? 1 : 0.25).disabled(abs(value - d) <= 1e-9)
                }
            }
        }
        .onAppear { value = model.number(path) }
        .onChange(of: model.revision) { _, _ in if !editing { value = model.number(path) } }
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
    var opacity = false          // true: the picker edits alpha too
    var body: some View {
        ColorPicker(title, selection: Binding(
            get: { let c = model.color(path); return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: c[3]) },
            set: { let n = NSColor($0).usingColorSpace(.sRGB) ?? .black
                   model.set(path, color: [n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent].map { Double($0) }) }),
                    supportsOpacity: opacity)
    }
}

// MARK: inspector

/// Output aspect ratios, as in the reference: Auto (recording plus padding), 16:9, 1:1, 4:3, 9:16, 3:4, 4:5.
public enum AspectPreset: String, CaseIterable {
    case auto = "source", wide = "16:9", square = "1:1", classic = "4:3", vertical = "9:16", tall = "3:4", portrait = "4:5"
    var label: String {
        switch self {
        case .auto: "Auto"; case .wide: "Wide 16:9"; case .square: "Square 1:1"; case .classic: "Classic 4:3"
        case .vertical: "Vertical 9:16"; case .tall: "Tall 3:4"; case .portrait: "Portrait 4:5"
        }
    }
    var hint: String {
        switch self {
        case .auto: "Fits the recording plus padding"; case .wide: "YouTube, presentations"; case .square: "Social posts"
        case .classic: "Older screens, slides"; case .vertical: "Stories, Reels, Shorts"; case .tall: "Tall feed posts"; case .portrait: "Instagram portrait"
        }
    }
    /// Output size to store with the aspect (height sets the export height); nil keeps the current size (Auto).
    var outputSize: [Double]? {
        switch self {
        case .auto: nil; case .wide: [1920, 1080]; case .square: [1080, 1080]; case .classic: [1440, 1080]
        case .vertical: [1080, 1920]; case .tall: [1080, 1440]; case .portrait: [1080, 1350]
        }
    }
}

public enum InspectorSection: String, CaseIterable, Identifiable {
    case background, cursor, cameraLayout, cameraStyle, captions, transcript, audio, keys, animations, extras
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .background: "Background"; case .cursor: "Cursor"; case .cameraLayout: "Camera layout"; case .cameraStyle: "Camera style"
        case .captions: "Captions"; case .transcript: "Edit by transcript"; case .audio: "Audio"; case .keys: "Keyboard shortcuts"
        case .animations: "Animations"; case .extras: "Text, regions & intro/outro"
        }
    }
    public var symbol: String {
        switch self {
        case .background: "photo.on.rectangle.angled"; case .cursor: "cursorarrow"; case .cameraLayout: "rectangle.inset.filled.and.person.filled"
        case .cameraStyle: "person.crop.rectangle"; case .captions: "captions.bubble"; case .transcript: "text.quote"
        case .audio: "speaker.wave.2"; case .keys: "command"; case .animations: "point.topleft.down.curvedto.point.bottomright.up"
        case .extras: "textformat"
        }
    }
    /// ⌘ digit that selects the section (1…9, then 0).
    public var shortcutDigit: Character { Self.digits[Self.allCases.firstIndex(of: self)!] }
    private static let digits: [Character] = Array("1234567890")
    @MainActor public func isAvailable(in m: EditorModel) -> Bool {
        switch self {
        case .background, .audio, .animations, .extras: true
        case .cursor: m.hasMouseData
        case .cameraLayout: m.hasCamera
        case .cameraStyle: m.hasCamera && m.bool("camera.visible", default: true)
        case .captions, .transcript: m.hasMic
        case .keys: m.hasKeystrokes
        }
    }
}

extension EditorModel {
    public var availableSections: [InspectorSection] { InspectorSection.allCases.filter { $0.isAvailable(in: self) } }
    /// ⌘ digit handler: selects the section bound to `digit` when it is available (and leaves any item inspector).
    @discardableResult public func selectInspector(digit: Character) -> Bool {
        guard let s = InspectorSection.allCases.first(where: { $0.shortcutDigit == digit }), s.isAvailable(in: self) else { return false }
        showSection(s); return true
    }
    public func showSection(_ s: InspectorSection) {
        if case .zoom = selection { selection = .none } else if case .clip = selection { selection = .none }
        inspectorSection = s
    }
}

/// Vertical icon rail (right of the preview) that picks the inspector section.
struct InspectorRail: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        let section = model.inspectorSection
        VStack(spacing: 4) {
            ForEach(model.availableSections) { s in
                Button { model.showSection(s) } label: {
                    Image(systemName: s.symbol).font(.system(size: 15)).frame(width: 34, height: 34)
                        .background(section == s ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(section == s ? Color.accentColor : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(s.title) (⌘\(String(s.shortcutDigit)))")
                .accessibilityLabel(s.title)
                .accessibilityAddTraits(section == s ? [.isButton, .isSelected] : .isButton)
            }
            Spacer()
        }
        .padding(.vertical, 8).padding(.horizontal, 5)
        .frame(width: 44)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct InspectorView: View {
    @ObservedObject var model: EditorModel
    private let initialSection: InspectorSection?
    init(model: EditorModel, initialSection: InspectorSection? = nil) { self.model = model; self.initialSection = initialSection }

    /// A selected zoom or clip replaces the section with that item's settings.
    private var itemTitle: String? {
        switch model.selection { case .zoom: "Zoom"; case .clip: "Clip"; default: nil }
    }
    private var section: InspectorSection {
        model.availableSections.contains(model.inspectorSection) ? model.inspectorSection : .background
    }

    var body: some View {
        HStack(spacing: 0) {
            InspectorRail(model: model)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(itemTitle ?? section.title).font(.headline); Spacer()
                    if itemTitle != nil { Button("Done") { model.selection = .none }.buttonStyle(.borderless).help("Back to the section (Esc)") }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(nsColor: .windowBackgroundColor))
                Divider()
                Form {
                    if itemTitle != nil { itemInspector } else { sectionBody }
                }.formStyle(.grouped)
            }
        }
        .onAppear { if let initialSection { model.inspectorSection = initialSection } }
        .onChange(of: model.selection) { _, s in
            switch s {
            case .layout: model.inspectorSection = .cameraLayout
            case .cursorHide: model.inspectorSection = .cursor
            case .highlight, .text(.annotation, _), .text(.reaction, _): model.inspectorSection = .extras
            case .text(.caption, _): model.inspectorSection = .captions
            case .music: model.inspectorSection = .audio
            case .zoom, .clip, .none: break
            }
        }
    }

    @ViewBuilder private var sectionBody: some View {
        switch section {
        case .background: BackgroundPanel(model: model)
        case .cursor: cursor
        case .cameraLayout: cameraLayout
        case .cameraStyle: cameraStyle
        case .captions: CaptionSection(model: model)
        case .transcript: TranscriptPanel(model: model)
        case .audio: audio
        case .keys: keys
        case .animations: animations
        case .extras: extras
        }
    }

    @ViewBuilder private var itemInspector: some View {
        if let z = model.selectedZoom { zoomSection(z) }
        if case .clip(let id) = model.selection, let c = model.clips.first(where: { $0.id == id }) { speedSection(c) }
    }

    @ViewBuilder private var animations: some View {
        AnimationPresets(model: model)
        Section("Zooms") {
            ToggleRow(model: model, title: "Automatic zooms", path: "zoom_settings.automatic", defaultValue: true)
            ToggleRow(model: model, title: "Follow cursor while zoomed", path: "zoom_settings.follow_cursor", defaultValue: true)
            PickerRow(model: model, title: "Transition speed", path: "zoom_settings.speed_preset", options: speedPresets)
            PickerRow(model: model, title: "Screen animation", path: "zoom_settings.animation_style",
                      options: [("Custom", "custom"), ("Focused (settles fast)", "focused"), ("Smooth (fluid)", "smooth")])
            Button("Regenerate automatic zooms") { model.regenerateAutoZooms() }
        }
        Section("Motion blur") {
            NumberRow(model: model, title: "Motion blur", path: "canvas.motion_blur", range: 0...1, defaultValue: 0)
            Text("One strength for zoom, screen movement and cursor.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var keys: some View {
        Section("Key overlay") {
            ToggleRow(model: model, title: "Show typed keys", path: "cursor.key_overlay.enabled")
            if model.bool("cursor.key_overlay.enabled") {
                Toggle("Show single-key presses", isOn: Binding(get: { !model.bool("cursor.key_overlay.shortcuts_only", default: true) },
                                                                set: { model.set("cursor.key_overlay.shortcuts_only", bool: !$0) }))
                DurationRow(model: model, title: "Stays visible", path: "cursor.key_overlay.duration_ns", default: 1_000_000_000)
                RectRow(model: model, title: "Position", path: "cursor.key_overlay.rect", fallback: [0.3, 0.82, 0.4, 0.12])
                let h = max(model.numbers("canvas.output_size").last ?? 1080, 1)
                NumberRow(model: model, title: "Size", path: "cursor.key_overlay.style.font_size", range: 0.075 * h...0.25 * h, unit: "%", format: "%.1f", scale: 100 / h, defaultValue: 0.10 * h)
                ColorRow(model: model, title: "Text", path: "cursor.key_overlay.style.color")
                ColorRow(model: model, title: "Background", path: "cursor.key_overlay.style.background", opacity: true)
                NumberRow(model: model, title: "Corner radius", path: "cursor.key_overlay.style.radius", range: 0...48, unit: "px", format: "%.0f")
                NumberRow(model: model, title: "Opacity", path: "cursor.key_overlay.style.opacity", range: 0...1)
            }
            Text("Needs “Record keystrokes” turned on before recording.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var extras: some View {
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
        Section("Text and reactions") {
            if case .text(let kind, let id) = model.selection, kind != .caption, let t = model.textItems(kind).first(where: { $0.id == id }) { TextControls(model: model, item: t) }
            Button("Add text at playhead") { model.addText(.annotation) }
            HStack(spacing: 4) {
                ForEach(reactionGlyphs, id: \.self) { g in
                    Button(g) { model.addText(.reaction, text: g) }.buttonStyle(.bordered).accessibilityLabel("Add reaction \(g)")
                }
            }
            Text("Drag the text box in the preview to place it.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Intro and outro") {
            Picker("Intro", selection: Binding(get: { model.string("canvas.animation.entrance", default: "none") }, set: { model.set("canvas.animation.entrance", string: $0) })) {
                ForEach(animationModes(intro: true), id: \.value) { Text($0.label).tag($0.value) }
            }
            if model.string("canvas.animation.entrance", default: "none") != "none" {
                DurationRow(model: model, title: "Intro length", path: "canvas.animation.entrance_duration_ns")
            }
            Picker("Outro", selection: Binding(get: { model.string("canvas.animation.exit", default: "none") }, set: { model.set("canvas.animation.exit", string: $0) })) {
                ForEach(animationModes(intro: false), id: \.value) { Text($0.label).tag($0.value) }
            }
            if model.string("canvas.animation.exit", default: "none") != "none" {
                DurationRow(model: model, title: "Outro length", path: "canvas.animation.exit_duration_ns")
            }
        }
    }

    private func animationModes(intro: Bool) -> [(label: String, value: String)] {
        [("None", "none"), (intro ? "Fade in" : "Fade out", "fade"), (intro ? "Zoom in" : "Zoom out", "zoom"),
         ("Slide from left", "slide_left"), ("Slide from right", "slide_right"), ("Slide from top", "slide_up"), ("Slide from bottom", "slide_down")]
    }

    private var speedPresets: [(label: String, value: String)] {
        [("Custom", "custom"), ("Slow", "slow"), ("Mellow", "mellow"), ("Quick", "quick"), ("Rapid", "rapid")]
    }

    private func zoomSection(_ z: TimelineZoom) -> some View {
        Section(z.mode == .auto ? "Zoom (automatic)" : "Zoom") {
            Picker("Type", selection: Binding(get: { z.mode }, set: { model.setZoomMode(id: z.id, $0) })) {
                Text("Auto").tag(TimelineZoom.Mode.auto); Text("Manual").tag(TimelineZoom.Mode.manual)
            }.pickerStyle(.segmented)
            ZoomScaleRow(model: model, zoom: z)
            LabeledContent("Focus") { Text(String(format: "%.0f%%, %.0f%%", z.focusX * 100, z.focusY * 100)).monospacedDigit() }
            Text("Click in the preview to set the focus point.").font(.caption).foregroundStyle(.secondary)
            Toggle("Instant animation", isOn: Binding(get: { z.easeInNs == 0 && z.easeOutNs == 0 },
                                                       set: { model.setZoomEase(id: z.id, inNs: $0 ? 0 : 300_000_000, outNs: $0 ? 0 : 300_000_000) }))
            Toggle("Enabled", isOn: Binding(get: { z.enabled }, set: { model.setZoomEnabled(id: z.id, $0) }))
            LabeledContent("Time") { Text("\(formatTimecode(z.startNs)) – \(formatTimecode(z.endNs))").monospacedDigit() }
            Button("Apply this level to all other zooms") { model.applyZoomLevelToAll() }.disabled(model.zooms.count < 2)
            HStack {
                Button("Duplicate") { model.duplicateSelectedZoom() }
                Button("Delete zoom", role: .destructive) { model.deleteSelection() }
            }
            Text("Keys: A auto · M manual · D disable · ⌘D duplicate · 1–9 level · 0 default · = / − step · ⌫ remove")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func speedSection(_ c: TimelineClip) -> some View {
        Section("Clip") {
            Picker("Speed", selection: Binding(get: { c.speed }, set: { model.setSpeed(clipID: c.id, $0) })) {
                ForEach(clipSpeedOptions, id: \.self) { Text($0 == 1 ? "1x (normal)" : speedText($0)).tag($0) }
                if !clipSpeedOptions.contains(c.speed) { Text(speedText(c.speed)).tag(c.speed) }
            }
            Button("Apply this speed to all clips") { model.applySpeedToAll(c.speed) }.disabled(model.clips.count < 2)
            LabeledContent("Length") { Text(formatTimecode(c.timelineDurationNs)).monospacedDigit() }
            Button("Delete clip", role: .destructive) { model.deleteSelection() }
        }
    }

    @ViewBuilder private var cursor: some View {
        Section("Cursor") {
            ToggleRow(model: model, title: "Show cursor", path: "cursor.visible", defaultValue: true)
            NumberRow(model: model, title: "Size", path: "cursor.size", range: 0.5...4, unit: "×")
            NumberRow(model: model, title: "Smoothing", path: "cursor.smoothing", range: 0...1)
            PickerRow(model: model, title: "Movement speed", path: "cursor.speed_preset", options: speedPresets)
            ToggleRow(model: model, title: "Hide when idle", path: "cursor.hide_when_idle")
            if model.bool("cursor.hide_when_idle") {
                DurationRow(model: model, title: "Idle after", path: "cursor.idle_timeout_ns", default: 2_000_000_000, range: 0.5...5)
            }
            ToggleRow(model: model, title: "Always use the default arrow", path: "cursor.always_default")
            ToggleRow(model: model, title: "Tilt while moving", path: "cursor.rotate_on_move")
            ToggleRow(model: model, title: "Remove tiny shakes", path: "cursor.remove_shakes")
            ToggleRow(model: model, title: "Reduce cursor-type flicker", path: "cursor.optimize_types")
            HoldCursorRow(model: model)
            PickerRow(model: model, title: "Click effect", path: "cursor.click_effect",
                      options: [("None", "none"), ("Circle", "ring"), ("Ripple", "highlight")])
            ToggleRow(model: model, title: "Loop cursor to start", path: "cursor.loop_to_start")
            if model.bool("cursor.loop_to_start") {
                DurationRow(model: model, title: "Loop position takes", path: "cursor.loop_duration_ns", default: 400_000_000, range: 1...4)
            }
            PickerRow(model: model, title: "Cursor style", path: "cursor.style",
                      options: [("Recorded", "recorded"), ("Pointer", "pointer"), ("Touch", "touch"), ("Arrow", "arrow")])
            NullableChoiceRow(model: model, title: "Cursor set", path: "cursor.set_id", automatic: "Recorded", options: cursorSets)
            NullableChoiceRow(model: model, title: "Cursor shape", path: "cursor.shape", automatic: "Automatic", options: cursorShapes)
            PickerRow(model: model, title: "Cursor size", path: "cursor.logical_size", options: cursorSizes)
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

    @ViewBuilder private var cameraLayout: some View {
        Section("Camera") {
            ToggleRow(model: model, title: "Show camera", path: "camera.visible", defaultValue: true)
            NumberRow(model: model, title: "Size", path: "camera.size", range: 0.1...0.75, unit: "%", format: "%.0f", scale: 100, defaultValue: 0.22)
            Toggle("Make smaller during zoom", isOn: Binding(get: { model.number("camera.zoom_scale", default: 1) < 0.999 },
                                                              set: { model.set("camera.zoom_scale", number: $0 ? 0.6 : 1) }))
            if model.number("camera.zoom_scale", default: 1) < 0.999 {
                NumberRow(model: model, title: "Size while zoomed", path: "camera.zoom_scale", range: 0.25...0.8, unit: "%", format: "%.0f", scale: 100, defaultValue: 0.6)
            }
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

    @ViewBuilder private var cameraStyle: some View {
        Section("Camera style") {
            PickerRow(model: model, title: "Shape", path: "camera.shape",
                      options: [("Rounded rectangle", "rounded_rect"), ("Circle", "circle"), ("Squircle", "squircle")])
            NumberRow(model: model, title: "Corner radius", path: "camera.radius", range: 0...64, unit: "pt", format: "%.0f", defaultValue: 24)
            NumberRow(model: model, title: "Opacity", path: "camera.opacity", range: 0...1, defaultValue: 1)
            ToggleRow(model: model, title: "Mirror", path: "camera.mirrored", defaultValue: true)
            NumberRow(model: model, title: "Shadow", path: "camera.shadow_radius", range: 0...60, unit: "pt", format: "%.0f", defaultValue: 0)
            ToggleRow(model: model, title: "Remove background", path: "camera.background_removal")
            ToggleRow(model: model, title: "Frame face", path: "camera.face_framing")
        }
    }

    @ViewBuilder private var audio: some View {
        Section("Automatic edits") {
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
        Section("Click sounds") {
            ToggleRow(model: model, title: "Play a sound on clicks", path: "audio.click_sound.enabled")
            PickerRow(model: model, title: "Sound", path: "audio.click_sound.variant", options: [("Soft", "soft"), ("Crisp", "crisp")])
            NumberRow(model: model, title: "Volume", path: "audio.click_sound.gain_db", range: -48...12, unit: "dB", format: "%.0f")
        }
        MusicSection(model: model)
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
                VoiceCleanupSection(model: model)
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
        LabeledContent("Level") {
            HStack {
                Slider(value: $value, in: zoomLevelRange) { e in editing = e; if !e { model.setZoomScale(id: zoom.id, value) } }
                    .accessibilityLabel("Zoom level").accessibilityValue("\(Int((value * 100).rounded())) percent")
                Text("\(Int((value * 100).rounded()))%").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
        }
        .onAppear { value = zoom.scale }
        .onChange(of: zoom.scale) { _, v in if !editing { value = v } }
        .onChange(of: zoom.id) { _, _ in value = zoom.scale }
    }
}

/// 8-point position grid (corners and edge midpoints, no center).
struct CameraPositionRow: View {
    @ObservedObject var model: EditorModel
    static let xs = [0.18, 0.5, 0.82], ys = [0.22, 0.5, 0.78]
    var body: some View {
        LabeledContent("Position") {
            let cur = model.numbers("camera.position")
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { c in
                            if r == 1 && c == 1 { Color.clear.frame(width: 26, height: 20) }
                            else {
                                let on = cur.count == 2 && abs(cur[0] - Self.xs[c]) < 0.02 && abs(cur[1] - Self.ys[r]) < 0.02
                                Button { model.set("camera.position", .array([.number(Self.xs[c]), .number(Self.ys[r])])) } label: {
                                    RoundedRectangle(cornerRadius: 4).fill(on ? Color.accentColor : Color.primary.opacity(0.15)).frame(width: 26, height: 20)
                                }
                                .buttonStyle(.plain).accessibilityLabel("Camera position \(["top", "middle", "bottom"][r]) \(["left", "center", "right"][c])")
                                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                            }
                        }
                    }
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
                    .accessibilityLabel("Crop \(title.lowercased())").accessibilityValue("\(Int(v.wrappedValue * 100)) percent")
                Text("\(Int(v.wrappedValue * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }
}

struct DurationRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String
    var `default` = 400_000_000.0
    var range: ClosedRange<Double> = 0.1...5
    @State private var seconds = 0.4
    @State private var editing = false
    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $seconds, in: range) { e in editing = e; if !e { model.set(path, number: (seconds * 1e9).rounded()) } }
                    .accessibilityLabel(title).accessibilityValue(String(format: "%.1f seconds", seconds))
                Text(String(format: "%.1f s", seconds)).monospacedDigit().frame(width: 46, alignment: .trailing).accessibilityHidden(true)
            }
        }
        .onAppear { seconds = model.number(path, default: `default`) / 1e9 }
        .onChange(of: model.revision) { _, _ in if !editing { seconds = model.number(path, default: `default`) / 1e9 } }
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
            Stepper("Dim outside \(Int(region.dimOpacity * 100))%", value: Binding(get: { region.dimOpacity }, set: { v in model.updateHighlight(id: id) { $0.dimOpacity = min(max(v, 0.1), 0.9) } }), in: 0.1...0.9, step: 0.1)
            Button("Apply to all highlights") { model.applyHighlightStyleToAll(from: id) }.disabled(model.highlights.count < 2)
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

struct RectRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String, fallback: [Double]
    @State private var r: [Double] = [0, 0, 1, 1]
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout)
            ForEach(0..<4, id: \.self) { i in
                HStack {
                    Text(["Left", "Top", "Width", "Height"][i]).font(.caption).frame(width: 44, alignment: .leading)
                    Slider(value: Binding(get: { r[i] }, set: { r[i] = $0 }), in: i < 2 ? 0...0.95 : 0.05...1) { e in
                        editing = e
                        if !e { commit() }
                    }
                    .accessibilityLabel("\(title) \(["left", "top", "width", "height"][i])")
                    .accessibilityValue("\(Int(r[i] * 100)) percent")
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.revision) { _, _ in if !editing { load() } }
    }
    private func load() { let n = model.numbers(path); r = n.count == 4 ? n : fallback }
    private func commit() {
        var v = r; v[2] = min(v[2], 1 - v[0]); v[3] = min(v[3], 1 - v[1])
        model.set(path, color: v)      // 4-number array
    }
}

struct TextControls: View {
    @ObservedObject var model: EditorModel
    let item: TextItem
    @State private var draft = ""
    var body: some View {
        let kind = item.kind, id = item.id
        TextField(kind == .reaction ? "Emoji" : "Text", text: $draft, axis: .vertical)
            .lineLimit(1...4)
            .onSubmit { commitText() }
            .onChange(of: item.id) { _, _ in draft = item.text }
            .onAppear { draft = item.text }
            .accessibilityLabel("Text content")
        Button("Apply text") { commitText() }.disabled(draft == item.text)
        Picker("Follows", selection: Binding(get: { item.space }, set: { v in model.updateText(kind, id: id) { $0.space = v } })) {
            Text("Canvas (fixed)").tag("canvas"); Text("Screen (zoom/crop)").tag("source")
        }
        LabeledContent("Time") { Text("\(formatTimecode(item.startNs)) – \(formatTimecode(item.endNs))").monospacedDigit() }
        Stepper("Size \(Int(item.fontSize)) px", value: Binding(get: { item.fontSize }, set: { v in model.updateText(kind, id: id) { $0.fontSize = min(max(v, 8), 400) } }), in: 8...400, step: 4)
        TextColor(title: "Text color", get: { item.color }, set: { c in model.updateText(kind, id: id) { $0.color = c } })
        TextColor(title: "Background", get: { item.background }, set: { c in model.updateText(kind, id: id) { $0.background = c } })
        Stepper("Corner radius \(Int(item.radius)) px", value: Binding(get: { item.radius }, set: { v in model.updateText(kind, id: id) { $0.radius = max(0, v) } }), in: 0...64, step: 2)
        Stepper("Opacity \(Int(item.opacity * 100))%", value: Binding(get: { item.opacity }, set: { v in model.updateText(kind, id: id) { $0.opacity = min(max(v, 0), 1) } }), in: 0...1, step: 0.1)
        Button("Delete", role: .destructive) { model.deleteSelection() }
    }
    private func commitText() { model.updateText(item.kind, id: item.id) { $0.text = draft } }
}

struct TextColor: View {
    let title: String
    let get: () -> [Double]
    let set: ([Double]) -> Void
    var body: some View {
        ColorPicker(title, selection: Binding(
            get: { let c = get(); return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: c[3]) },
            set: { let n = NSColor($0).usingColorSpace(.sRGB) ?? .black
                   set([Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent), Double(n.alphaComponent)]) }),
                    supportsOpacity: true)
    }
}

struct CaptionSection: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        let captions = model.textItems(.caption)
        Section("Captions") {
            switch model.captionState {
            case .working: HStack { ProgressView().controlSize(.small); Text("Transcribing on this Mac…") }
            case .failed(let m): Text(m).foregroundStyle(.red); Button("Dismiss") { model.captionState = .idle }
            case .idle: Button(captions.isEmpty ? "Generate captions from speech" : "Regenerate captions") { model.generateCaptions() }
            }
            CaptionStyleControls(model: model)
            if case .text(.caption, let id) = model.selection, let t = captions.first(where: { $0.id == id }) { TextControls(model: model, item: t) }
            Button("Add caption at playhead") { model.addText(.caption) }
            if !captions.isEmpty {
                Text("\(captions.count) caption\(captions.count == 1 ? "" : "s") — click one to edit text, timing and style.").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(captions) { c in
                            Button { model.selection = .text(.caption, c.id); model.seek(toNs: c.startNs) } label: {
                                HStack {
                                    Text(formatTimecode(c.startNs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(c.text).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.vertical, 2).padding(.horizontal, 6)
                                .background(model.selection == .text(.caption, c.id) ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 180)
            }
        }
    }
}

struct MusicSection: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        Section("Background music") {
            if case .music(let id) = model.selection, let m = model.music.first(where: { $0.id == id }) { MusicControls(model: model, item: m) }
            HStack {
                ForEach(builtInMusic) { src in Button(src.name) { model.addBuiltInMusic(src) } }
                Button("Add file…") { chooseFile() }
            }
            ForEach(model.music) { m in
                Button { model.selection = .music(m.id) } label: {
                    HStack { Text("♪ " + m.title).lineLimit(1); Spacer(); Text(formatTimecode(m.startNs, showFraction: false)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }.buttonStyle(.plain)
            }
            Text("Built-in tracks are original. Music starts at the playhead and runs to the end.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.importMusicFile(url) }
    }
}

struct MusicControls: View {
    @ObservedObject var model: EditorModel
    let item: MusicItem
    @State private var gain = -18.0
    @State private var editing = false
    var body: some View {
        let id = item.id
        LabeledContent("Volume") {
            HStack {
                Slider(value: $gain, in: -48...6) { e in editing = e; if !e { model.setMusicGain(id: id, gain) } }
                    .accessibilityLabel("Music volume").accessibilityValue("\(Int(gain)) decibels")
                Text("\(Int(gain)) dB").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
        .onAppear { gain = item.gainDb }
        .onChange(of: item.gainDb) { _, v in if !editing { gain = v } }
        .onChange(of: item.id) { _, _ in gain = item.gainDb }
        Toggle("Loop", isOn: Binding(get: { item.loop }, set: { model.setMusicLoop(id: id, $0) }))
        Stepper("Fade in \(String(format: "%.1f", Double(item.fadeInNs) / 1e9)) s", value: Binding(get: { Double(item.fadeInNs) / 1e9 }, set: { model.setMusicFades(id: id, inNs: Int64($0 * 1e9), outNs: item.fadeOutNs) }), in: 0...10, step: 0.5)
        Stepper("Fade out \(String(format: "%.1f", Double(item.fadeOutNs) / 1e9)) s", value: Binding(get: { Double(item.fadeOutNs) / 1e9 }, set: { model.setMusicFades(id: id, inNs: item.fadeInNs, outNs: Int64($0 * 1e9)) }), in: 0...10, step: 0.5)
        Toggle("Lower during speech", isOn: Binding(get: { item.duckEnabled }, set: { model.setMusicDucking(id: id, enabled: $0, gainDb: item.duckGainDb) }))
        if item.duckEnabled {
            Stepper("Lower by \(Int(-item.duckGainDb)) dB", value: Binding(get: { -item.duckGainDb }, set: { model.setMusicDucking(id: id, enabled: true, gainDb: -$0) }), in: 0...48, step: 3)
            Text("Uses caption timing as speech. Generate captions first.").font(.caption).foregroundStyle(.secondary)
        }
        Button("Remove music", role: .destructive) { model.deleteSelection() }
    }
}

struct WallpaperThumb: View {
    @ObservedObject var model: EditorModel
    let info: WallpaperInfo
    let busy: Bool
    var selected = false
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(16.0 / 9, contentMode: .fill) }
            else { Rectangle().fill(Color.primary.opacity(0.08)) }
            if busy { ProgressView().controlSize(.small) }
        }
        .frame(height: 50).clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: selected ? 3 : 1))
        .task { image = await model.project.wallpaperThumbnail(id: info.id) }
    }
}

/// 0 = off. Holds the cursor still for the last N seconds of the video.
struct HoldCursorRow: View {
    @ObservedObject var model: EditorModel
    private let path = "cursor.stop_before_end_ns"
    var body: some View {
        let on = model.number(path) > 0
        Toggle("Stop cursor before the end", isOn: Binding(get: { on }, set: { model.set(path, number: $0 ? 1_000_000_000 : 0) }))
        if on { DurationRow(model: model, title: "Stops", path: path, default: 1_000_000_000) }
    }
}

/// A motion-blur strength that either inherits the general setting (null) or has its own value.
struct InheritedBlurRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String
    private var inherits: Bool { if case .number? = model.value(path) { false } else { true } }
    var body: some View {
        Toggle("\(title): same as motion blur", isOn: Binding(
            get: { inherits },
            set: { model.set(path, $0 ? .null : .number(model.number("canvas.motion_blur"))) }))
        if !inherits { NumberRow(model: model, title: title, path: path, range: 0...1) }
    }
}

struct VoiceCleanupSection: View {
    @ObservedObject var model: EditorModel
    private let p = "audio.speech_enhancement_settings."
    var body: some View {
        ToggleRow(model: model, title: "Clean up voice", path: "audio.speech_enhancement")
        if model.bool("audio.speech_enhancement") {
            NumberRow(model: model, title: "Noise reduction", path: p + "noise_reduction_db", range: 0...60, unit: "dB", format: "%.0f")
            NumberRow(model: model, title: "Noise gate", path: p + "noise_threshold_db", range: -70 ... -15, unit: "dB", format: "%.0f")
            NumberRow(model: model, title: "Low cut", path: p + "high_pass_hz", range: 20...300, unit: "Hz", format: "%.0f")
            NumberRow(model: model, title: "Compression", path: p + "compressor_ratio", range: 1...10, unit: ":1", format: "%.1f")
            ToggleRow(model: model, title: "Even out loudness", path: p + "normalize_loudness", defaultValue: true)
            if model.bool(p + "normalize_loudness", default: true) {
                NumberRow(model: model, title: "Target loudness", path: p + "target_lufs", range: -36 ... -10, unit: "LUFS", format: "%.0f")
            }
            Text("Processed offline on this Mac; the recording file is never changed. Preview re-prepares audio after a change.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A picker whose first entry means "unset" (stored as JSON null).
struct NullableChoiceRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String, automatic: String
    let options: [(label: String, value: String)]
    var body: some View {
        Picker(title, selection: Binding(
            get: { if case .string(let s)? = model.value(path) { s } else { "" } },
            set: { model.set(path, $0.isEmpty ? .null : .string($0)) })) {
            Text(automatic).tag("")
            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
        }
    }
}

/// Mirrors core's `cursor_library` query (a test keeps these lists in step with the real core).
let cursorSets: [(label: String, value: String)] = [
    ("Classic", "classic"), ("Paper", "paper"), ("Soft slate", "soft-slate"), ("Soft cloud", "soft-cloud"), ("Lagoon", "lagoon"), ("Coral", "coral"),
    ("Sage", "sage"), ("Violet", "violet"), ("Gold", "gold"), ("Precision dark", "precision-dark"), ("Precision light", "precision-light"), ("Signal", "signal")]
let cursorShapes: [(label: String, value: String)] = [
    ("Arrow", "arrow"), ("Pointing hand", "pointing_hand"), ("Touch", "touch"), ("Text", "text"), ("Resize horizontal", "resize_horizontal"),
    ("Resize vertical", "resize_vertical"), ("Resize diagonal ↘", "resize_diagonal_nwse"), ("Resize diagonal ↗", "resize_diagonal_nesw"),
    ("Open hand", "open_hand"), ("Closed hand", "closed_hand")]
let cursorSizes: [(label: String, value: String)] = [("Small", "small"), ("Regular", "regular"), ("Large", "large"), ("Extra large", "extra_large")]
