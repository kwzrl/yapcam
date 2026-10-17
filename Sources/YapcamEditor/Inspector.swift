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
        SliderRow(title) {
            HStack {
                Slider(value: $value, in: range) { isEditing in
                    editing = isEditing
                    if !isEditing { model.set(path, number: value) }
                }
                    .accessibilityLabel(title)
                    .accessibilityValue(String(format: format, value * scale) + (unit.isEmpty ? "" : " \(unit)"))
                Text(String(format: format, value * scale) + (unit.isEmpty ? "" : " \(unit)"))
                    .sliderValueLabel()
                if let d = defaultValue {
                    Button { value = d; model.set(path, number: d) } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless).help("Reset to default").accessibilityLabel("Reset \(title)")
                        .opacity(abs(value - d) > 1e-9 ? 1 : 0.25).disabled(abs(value - d) <= 1e-9)
                        .frame(width: EditorMetrics.resetSlot)
                } else { Color.clear.frame(width: EditorMetrics.resetSlot, height: 1) }
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
        RestingColorPicker(title: title, opacity: opacity, get: { model.color(path) }, set: { model.set(path, color: $0) })
    }
}

/// Color well that previews locally while the wheel moves and commits once when it rests (or the view goes away), so one
/// drag is one undo step, one journal write and one preview rebuild instead of one per tick.
struct RestingColorPicker: View {
    let title: String
    var opacity = true
    let get: () -> [Double]
    let set: ([Double]) -> Void
    var transform: ([Double]) -> [Double] = { $0 }        // e.g. keep the stored alpha for pickers without opacity
    @State private var pending: [Double]?
    @State private var task: Task<Void, Never>?
    @State private var hexText = ""
    @State private var editingHex = false
    @FocusState private var hexFocused: Bool

    private var current: [Double] { pending ?? get() }
    private func stage(_ c: [Double]) {
        pending = c
        task?.cancel()
        task = Task { try? await Task.sleep(for: .milliseconds(350)); if !Task.isCancelled { flush() } }
    }
    /// Swatch + hex field + eyedropper, like the reference's colour row.
    var body: some View {
        SliderRow(title) {
            HStack(spacing: EditorMetrics.s) {
                ColorPicker(title, selection: Binding(
                    get: { let c = current; return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: opacity ? c[3] : 1) },
                    set: { let n = NSColor($0).usingColorSpace(.sRGB) ?? .black
                           stage([n.redComponent, n.greenComponent, n.blueComponent, opacity ? n.alphaComponent : get()[3]].map { Double($0) }) }),
                            supportsOpacity: opacity)
                    .labelsHidden()
                TextField("Hex", text: $hexText)
                    .textFieldStyle(.plain).font(.system(.callout, design: .monospaced)).focused($hexFocused)
                    .padding(.horizontal, EditorMetrics.s).frame(height: 26)
                    .background(EditorTheme.control, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel("\(title) hex value")
                    .onSubmit { commitHex() }
                    .onChange(of: hexFocused) { _, f in editingHex = f; if !f { commitHex() } }
                Button { sample() } label: { Image(systemName: "eyedropper").frame(width: 26, height: 26) }
                    .buttonStyle(.plain).background(EditorTheme.control, in: RoundedRectangle(cornerRadius: 7))
                    .help("Pick a colour from the screen").accessibilityLabel("Pick \(title) from the screen")
            }
        }
        .onAppear { hexText = HexColor.string(current, alpha: opacity) }
        .onChange(of: current) { _, c in if !editingHex { hexText = HexColor.string(c, alpha: opacity) } }
        .onDisappear { task?.cancel(); flush() }
    }
    private func commitHex() {
        if let c = HexColor.parse(hexText, keepAlpha: current[3]) { stage(opacity ? c : [c[0], c[1], c[2], get()[3]]) }
        hexText = HexColor.string(current, alpha: opacity)
    }
    private func sample() {
        NSColorSampler().show { picked in
            guard let n = picked?.usingColorSpace(.sRGB) else { return }
            DispatchQueue.main.async { stage([n.redComponent, n.greenComponent, n.blueComponent, opacity ? current[3] : get()[3]].map { Double($0) }) }
        }
    }
    private func flush() { if let p = pending { pending = nil; set(transform(p)) } }
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
        VStack(spacing: 6) {
            ForEach(model.availableSections) { s in
                Button { model.showSection(s) } label: {
                    Image(systemName: s.symbol).font(.system(size: 19)).frame(width: 44, height: 44)
                        .background(section == s ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 10))
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
        .padding(.vertical, EditorMetrics.m).padding(.horizontal, EditorMetrics.xs)
        .frame(width: 54)
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
            VStack(spacing: 0) {
                HStack {
                    Text(itemTitle ?? section.title).font(.title3.weight(.semibold)); Spacer()
                    if itemTitle != nil { Button("Done") { model.selection = .none }.buttonStyle(.borderless).help("Back to the section (Esc)") }
                }
                .padding(.horizontal, EditorMetrics.l).padding(.vertical, EditorMetrics.m)
                Form {
                    if itemTitle != nil { itemInspector } else { sectionBody }
                }.formStyle(.grouped).scrollContentBackground(.hidden)
            }
            // Floating card on the stage, like the reference: rounded, own colour, hairline edge.
            .background(EditorTheme.card, in: RoundedRectangle(cornerRadius: EditorTheme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: EditorTheme.cardRadius).strokeBorder(EditorTheme.hairline))
            .clipShape(RoundedRectangle(cornerRadius: EditorTheme.cardRadius))
            .padding(.vertical, EditorMetrics.s).padding(.trailing, EditorMetrics.s)
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
            ToggleRow(model: model, title: "Start animation early", path: "zoom_settings.start_early")
            NumberRow(model: model, title: "Default zoom level", path: "zoom_settings.default_scale", range: 1...4, unit: "×", format: "%.1f", defaultValue: 2)
            Button("Regenerate automatic zooms") { model.regenerateAutoZooms() }
        }
        Section("Motion blur") {
            NumberRow(model: model, title: "Motion blur", path: "canvas.motion_blur", range: 0...1, defaultValue: model.factoryMotionBlur)
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
                Button("Blur mask") { model.addHighlightAtPlayhead(kind: .blur) }
                Button("Cover mask") { model.addHighlightAtPlayhead(kind: .mask) }
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
            LabeledPills("Type", selection: Binding(get: { z.mode }, set: { model.setZoomMode(id: z.id, $0) }), options: [("Auto", TimelineZoom.Mode.auto), ("Manual", TimelineZoom.Mode.manual)])
            LabeledPills("Style", selection: Binding(get: { z.lens != nil }, set: { model.setZoomLens(id: z.id, $0 ? ZoomLensParams() : nil) }), options: [("Classic", false), ("Glass loupe", true)])
            if let l = z.lens { ZoomLensRows(model: model, zoomID: z.id, lens: l) }
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
            if model.hasMic { ClipVolumeRow(model: model, title: "Microphone volume", system: false, clip: c) }
            ClipVolumeRow(model: model, title: "System audio volume", system: true, clip: c)
            Toggle("Hide the cursor in this part", isOn: Binding(get: { c.hideCursor }, set: { model.setClipCursor(hide: $0) }))
            Toggle("Smooth cursor movement off", isOn: Binding(get: { c.disableSmoothing }, set: { model.setClipCursor(smoothingOff: $0) }))
            LabeledContent("Length") { Text(formatTimecode(c.timelineDurationNs)).monospacedDigit() }
            Button("Delete clip", role: .destructive) { model.deleteSelection() }
        }
    }

    @ViewBuilder private var cursor: some View {
        Section("Appearance") {
            ToggleRow(model: model, title: "Show cursor", path: "cursor.visible", defaultValue: true)
            if model.usesCursorPoints {
                NumberRow(model: model, title: "Size", path: "cursor.size_points", range: 16...128, unit: "px", format: "%.0f", defaultValue: 48)
            } else {
                NumberRow(model: model, title: "Size", path: "cursor.size", range: 0.5...4, unit: "×")
            }
            NumberRow(model: model, title: "Smoothing", path: "cursor.smoothing", range: 0...1)
            PickerRow(model: model, title: "Movement speed", path: "cursor.speed_preset", options: speedPresets)
            ToggleRow(model: model, title: "Hide when idle", path: "cursor.hide_when_idle")
            if model.bool("cursor.hide_when_idle") {
                DurationRow(model: model, title: "Idle after", path: "cursor.idle_timeout_ns", default: 2_000_000_000, range: 0.5...5)
            }
            ToggleRow(model: model, title: "Always use the default arrow", path: "cursor.always_default")
            PickerRow(model: model, title: "Rotation", path: "cursor.rotation_mode", options: [("Fixed angle", "static"), ("Follow movement", "tilt")])
            if model.string("cursor.rotation_mode", default: "static") == "tilt" {
                NumberRow(model: model, title: "Tilt amount", path: "cursor.tilt_amount", range: 0...2, defaultValue: 1)
            } else {
                NumberRow(model: model, title: "Angle", path: "cursor.rotation_degrees", range: -180...180, unit: "°", format: "%.0f", defaultValue: 0)
            }
            ToggleRow(model: model, title: "Remove tiny shakes", path: "cursor.remove_shakes")
            if model.bool("cursor.remove_shakes") {
                NumberRow(model: model, title: "Shake threshold", path: "cursor.shake_threshold", range: 100...2000, unit: "pt", format: "%.2f", scale: 0.001, defaultValue: 500)
            }
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
            CursorSetCarousel(model: model)
            CursorVariantPicker(model: model)
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
        CameraLayoutSettings(model: model)
        Section("Layout over time") {
            if case .layout(let id) = model.selection, let l = model.layouts.first(where: { $0.id == id }) {
                Picker("Layout", selection: Binding(get: { l.mode }, set: { model.setLayoutMode(id: l.id, $0) })) {
                    ForEach(layoutModes, id: \.value) { Text($0.label).tag($0.value) }
                }
                if ["overlay", "cutout", "split"].contains(l.mode) { LayoutOwnSettings(model: model, layout: l) }
                LabeledContent("Time") { Text("\(formatTimecode(l.startNs)) – \(formatTimecode(l.endNs))").monospacedDigit() }
                Button("Remove layout", role: .destructive) { model.deleteSelection() }
            }
            Button("Add layout at playhead") { model.addLayoutAtPlayhead() }
            Text("Outside layout sections the default camera settings apply.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cameraStyle: some View { CameraStylePanel(model: model) }

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
                ToggleRow(model: model, title: "Keep stereo microphone", path: "audio.stereo_mic")
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
        SliderRow("Level") {
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
    var path = "canvas.crop"
    var title = "Crop recording"
    @State private var l = 0.0
    @State private var t = 0.0
    @State private var r = 0.0
    @State private var b = 0.0
    @State private var editing = false
    var body: some View {
        Section(title) {
            row("Left", $l); row("Top", $t); row("Right", $r); row("Bottom", $b)
            Button("Reset crop") { l = 0; t = 0; r = 0; b = 0; model.setCrop(path: path, left: 0, top: 0, right: 0, bottom: 0) }
                .disabled(l + t + r + b == 0)
        }
        .onAppear(perform: load)
        .onChange(of: model.revision) { _, _ in if !editing { load() } }
    }
    private func load() { let c = model.cropInsets(path: path); l = c.left; t = c.top; r = c.right; b = c.bottom }
    private func row(_ title: String, _ v: Binding<Double>) -> some View {
        SliderRow(title) {
            HStack {
                Slider(value: v, in: 0...0.9) { e in editing = e; if !e { model.setCrop(path: path, left: l, top: t, right: r, bottom: b) } }
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
        SliderRow(title) {
            HStack {
                Slider(value: $seconds, in: range) { e in editing = e; if !e { model.set(path, number: (seconds * 1e9).rounded()) } }
                    .accessibilityLabel(title).accessibilityValue(String(format: "%.1f seconds", seconds))
                Text(String(format: "%.1f s", seconds)).sliderValueLabel()
                Color.clear.frame(width: EditorMetrics.resetSlot, height: 1)
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
        if region.kind == .blur { BlurStrengthRow(model: model, region: region) }
        if region.kind != .blur { regionColor("Fill", get: { region.fill }, set: { c in model.updateHighlight(id: id) { $0.fill = c } }) }
        if region.kind != .mask && region.kind != .blur { regionColor("Outline", get: { region.stroke }, set: { c in model.updateHighlight(id: id) { $0.stroke = c } }) }
        if region.kind != .blur { Stepper("Outline width \(Int(region.strokeWidth)) pt", value: Binding(get: { region.strokeWidth }, set: { v in model.updateHighlight(id: id) { $0.strokeWidth = v } }), in: 0...16) }
        Stepper("Corner radius \(Int(region.radius)) pt", value: Binding(get: { region.radius }, set: { v in model.updateHighlight(id: id) { $0.radius = v } }), in: 0...64, step: 2)
        if region.kind != .mask && region.kind != .blur {
            Stepper("Dim outside \(Int(region.dimOpacity * 100))%", value: Binding(get: { region.dimOpacity }, set: { v in model.updateHighlight(id: id) { $0.dimOpacity = min(max(v, 0.1), 0.9) } }), in: 0.1...0.9, step: 0.1)
            Button("Apply to all highlights") { model.applyHighlightStyleToAll(from: id) }.disabled(model.highlights.count < 2)
        }
        Button("Remove region", role: .destructive) { model.deleteSelection() }
    }
    private func regionColor(_ title: String, get: @escaping () -> [Double], set: @escaping ([Double]) -> Void) -> some View {
        RestingColorPicker(title: title, opacity: false, get: get, set: set,
                           transform: { c in var c = c; if c[3] == 0 { c[3] = 0.3 }; return c })
    }
}

/// Blur strength of a blur mask: previews while dragging, one undo step on release.
struct BlurStrengthRow: View {
    @ObservedObject var model: EditorModel
    let region: HighlightRegion
    @State private var drag: Double?
    var body: some View {
        let range = HighlightRegion.blurRadiusRange
        SliderRow("Blur strength") {
            HStack {
                Slider(value: Binding(get: { drag ?? region.blurRadius }, set: { drag = $0 }), in: range, step: 1) { editing in
                    if !editing, let v = drag { drag = nil; if v != region.blurRadius { model.updateHighlight(id: region.id) { $0.blurRadius = v } } }
                }.accessibilityLabel("Blur strength")
                Text("\(Int(drag ?? region.blurRadius)) px").sliderValueLabel()
                Color.clear.frame(width: EditorMetrics.resetSlot, height: 1)
            }
        }
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
        RestingColorPicker(title: title, opacity: true, get: get, set: set)
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
            case .idle:
                if captions.isEmpty { Button("Generate captions from speech") { model.generateCaptions() } } else { RegenerateButton(model: model) }
            }
            if captions.isEmpty || model.captionState != .idle { TranscriptionOptionControls(model: model) }
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
        SliderRow("Volume") {
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
            PickerRow(model: model, title: "Voice preset", path: "audio.mic_preset",
                      options: [("Voice", "voice"), ("Noise reduction", "noise_reduction"), ("Podcast", "podcast")])
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

/// Cursor shapes and sizes mirror core's `cursor_library` query (a test keeps them in step); sets come from render's catalog.
let cursorShapes: [(label: String, value: String)] = [
    ("Arrow", "arrow"), ("Pointing hand", "pointing_hand"), ("Touch", "touch"), ("Text", "text"), ("Resize horizontal", "resize_horizontal"),
    ("Resize vertical", "resize_vertical"), ("Resize diagonal ↘", "resize_diagonal_nwse"), ("Resize diagonal ↗", "resize_diagonal_nesw"),
    ("Open hand", "open_hand"), ("Closed hand", "closed_hand")]
let cursorSizes: [(label: String, value: String)] = [("Small", "small"), ("Regular", "regular"), ("Large", "large"), ("Extra large", "extra_large")]

struct ClipVolumeRow: View {
    @ObservedObject var model: EditorModel
    let title: String
    let system: Bool
    let clip: TimelineClip
    @State private var value = 100.0
    @State private var editing = false
    var body: some View {
        SliderRow(title) {
            HStack {
                Slider(value: $value, in: 0...100, step: 5) { e in editing = e; if !e { model.setVolume(percent: Int(value), system: system) } }
                    .accessibilityLabel(title).accessibilityValue("\(Int(value)) percent")
                Text(value == 0 ? "Muted" : "\(Int(value))%").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
        .onAppear { value = (system ? clip.systemGain : clip.micGain) * 100 }
        .onChange(of: clip.systemGain) { _, v in if !editing && system { value = v * 100 } }
        .onChange(of: clip.micGain) { _, v in if !editing && !system { value = v * 100 } }
        .onChange(of: clip.id) { _, _ in value = (system ? clip.systemGain : clip.micGain) * 100 }
    }
}

/// Glass loupe parameters: size of the lens, edge bevel and colour fringing.
struct ZoomLensRows: View {
    @ObservedObject var model: EditorModel
    let zoomID: String
    let lens: ZoomLensParams
    @State private var drag: ZoomLensParams?          // local value while a slider is held; committed once on release
    private func row(_ title: String, _ range: ClosedRange<Double>, _ get: @escaping (ZoomLensParams) -> Double, _ set: @escaping (inout ZoomLensParams, Double) -> Void) -> some View {
        SliderRow(title) {
            HStack {
                Slider(value: Binding(get: { get(drag ?? lens) }, set: { v in var l = drag ?? lens; set(&l, v); drag = l }), in: range) { editing in
                    if !editing, let l = drag { drag = nil; model.setZoomLens(id: zoomID, l) }
                }.accessibilityLabel(title)
                Text(String(format: "%.2f", get(drag ?? lens))).sliderValueLabel()
                Color.clear.frame(width: EditorMetrics.resetSlot, height: 1)
            }
        }
    }
    var body: some View {
        row("Lens size", ZoomLensParams.radiusRange, { $0.radius }) { $0.radius = $1 }
        row("Bevel", 0...1, { $0.bevel }) { $0.bevel = $1 }
        row("Color fringing", 0...1, { $0.chromaticAberration }) { $0.chromaticAberration = $1 }
    }
}
