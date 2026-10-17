import SwiftUI
import YapcamCore
import YapcamDesign

// Sections of the inspector that have no file of their own: cursor, camera layout over time, audio, keys, extras.

let inspectorSpeedPresets: [(label: String, value: String)] = [("Custom", "custom"), ("Slow", "slow"), ("Mellow", "mellow"), ("Quick", "quick"), ("Rapid", "rapid")]

// MARK: cursor

struct CursorSection: View {
    @ObservedObject var model: EditorModel
    private var visible: Bool { model.bool("cursor.visible", default: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .cursorHide(let i) = model.selection, let h = model.cursorHides.first(where: { $0.index == i }) {
                SelectedItemGroup(model: model, title: "Hidden cursor", span: h.span) {
                    InspectorAction("Show cursor again", symbol: "cursorarrow") { model.deleteSelection() }
                }
            }
            InspectorGroup("Appearance", first: true) { appearance }
            if visible { InspectorGroup("Cursor set") { CursorArtwork(model: model) } }
            InspectorGroup("Hidden sections") {
                InspectorAction("Hide cursor from playhead", symbol: "eye.slash") { model.addCursorHideAtPlayhead() }
                InspectorNote("Drag a gray section on the timeline to move or resize it.")
            }
        }
    }

    @ViewBuilder private var appearance: some View {
        SwitchRow("Hide cursor", isOn: Binding(get: { !visible }, set: { model.set("cursor.visible", bool: !$0) }))
        if visible {
            if model.usesCursorPoints {
                NumberRow(model: model, title: "Size", path: "cursor.size_points", range: 16...128, unit: "px", format: "%.0f", defaultValue: 48)
            } else {
                NumberRow(model: model, title: "Size", path: "cursor.size", range: 0.5...4, unit: "×")
            }
            NumberRow(model: model, title: "Smoothing", path: "cursor.smoothing", range: 0...1)
            PickerRow(model: model, title: "Movement speed", path: "cursor.speed_preset", options: inspectorSpeedPresets)
            ToggleRow(model: model, title: "Hide when idle", path: "cursor.hide_when_idle")
            if model.bool("cursor.hide_when_idle") {
                DurationRow(model: model, title: "Idle after", path: "cursor.idle_timeout_ns", default: 2_000_000_000, range: 0.5...5)
            }
            PickerRow(model: model, title: "Click effect", path: "cursor.click_effect", options: [("None", "none"), ("Circle", "ring"), ("Ripple", "highlight")])
            InspectorMore { CursorMore(model: model) }
        }
    }
}

/// Fine-tuning of the cursor: default arrow, rotation, hold before the end, shakes, flicker, loop, blur, spotlight.
private struct CursorMore: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        ToggleRow(model: model, title: "Always use the default arrow", path: "cursor.always_default")
        NumberRow(model: model, title: "Rotate cursor", path: "cursor.rotation_degrees", range: -180...180, unit: "°", format: "%.0f", defaultValue: 0)
        ChoiceRow("Rotate while moving", selection: Binding(get: { model.string("cursor.rotation_mode", default: "static") },
                                                           set: { model.set("cursor.rotation_mode", string: $0) }),
                  options: [("Off", "static"), ("Tilt", "tilt"), ("Follow", "follow")])
        if model.string("cursor.rotation_mode", default: "static") == "tilt" {
            NumberRow(model: model, title: "Tilt amount", path: "cursor.tilt_amount", range: 0...2, defaultValue: 1)
        }
        HoldCursorRow(model: model)
        ToggleRow(model: model, title: "Remove tiny shakes", path: "cursor.remove_shakes")
        if model.bool("cursor.remove_shakes") {
            NumberRow(model: model, title: "Shake threshold", path: "cursor.shake_threshold", range: 100...2000, unit: "pt", format: "%.2f", scale: 0.001, defaultValue: 500)
        }
        ToggleRow(model: model, title: "Reduce cursor-type flicker", path: "cursor.optimize_types")
        // Turning the loop on sets 1 s (the reference's value); it is one undo step with the switch.
        SwitchRow("Loop cursor to start", isOn: Binding(get: { model.bool("cursor.loop_to_start") }, set: { on in
            var items: [(path: String, value: JSONValue)] = [("cursor.loop_to_start", .bool(on))]
            if on && model.number("cursor.loop_duration_ns") < 1_000_000_000 { items.append(("cursor.loop_duration_ns", .number(1_000_000_000))) }
            model.setMany(items) }))
        if model.bool("cursor.loop_to_start") {
            DurationRow(model: model, title: "Loop position takes", path: "cursor.loop_duration_ns", default: 1_000_000_000, range: 1...4)
        }
        NumberRow(model: model, title: "Motion blur", path: "cursor.motion_blur", range: 0...1)
        NumberRow(model: model, title: "Spotlight radius", path: "cursor.spotlight_radius", range: 0...600, unit: "px", format: "%.0f")
    }
}

/// Which artwork draws the cursor: style, set, and per-type shape, size and variants behind "More".
private struct CursorArtwork: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        PickerRow(model: model, title: "Cursor style", path: "cursor.style",
                  options: [("Recorded", "recorded"), ("Pointer", "pointer"), ("Touch", "touch"), ("Arrow", "arrow")])
        CursorSetCarousel(model: model)
        InspectorMore("Shape and variants") {
            NullableChoiceRow(model: model, title: "Cursor shape", path: "cursor.shape", automatic: "Automatic", options: cursorShapes)
            PickerRow(model: model, title: "Cursor size", path: "cursor.logical_size", options: cursorSizes)
            CursorVariantPicker(model: model)
        }
    }
}

/// 0 = off. Holds the cursor still for the last N seconds of the video.
struct HoldCursorRow: View {
    @ObservedObject var model: EditorModel
    private let path = "cursor.stop_before_end_ns"
    var body: some View {
        let on = model.number(path) > 0
        SwitchRow("Stop cursor before the end", isOn: Binding(get: { on }, set: { model.set(path, number: $0 ? 1_000_000_000 : 0) }))
        if on { DurationRow(model: model, title: "Stops", path: path, default: 1_000_000_000) }
    }
}

/// A motion-blur strength that either inherits the general setting (null) or has its own value.
struct InheritedBlurRow: View {
    @ObservedObject var model: EditorModel
    let title: String, path: String
    private var inherits: Bool { if case .number? = model.value(path) { false } else { true } }
    var body: some View {
        SwitchRow("\(title): same as motion blur", isOn: Binding(
            get: { inherits },
            set: { model.set(path, $0 ? .null : .number(model.number("canvas.motion_blur"))) }))
        if !inherits { NumberRow(model: model, title: title, path: path, range: 0...1) }
    }
}

/// Cursor shapes and sizes mirror core's `cursor_library` query (a test keeps them in step); sets come from render's catalog.
let cursorShapes: [(label: String, value: String)] = [
    ("Arrow", "arrow"), ("Pointing hand", "pointing_hand"), ("Touch", "touch"), ("Text", "text"), ("Resize horizontal", "resize_horizontal"),
    ("Resize vertical", "resize_vertical"), ("Resize diagonal ↘", "resize_diagonal_nwse"), ("Resize diagonal ↗", "resize_diagonal_nesw"),
    ("Open hand", "open_hand"), ("Closed hand", "closed_hand")]
let cursorSizes: [(label: String, value: String)] = [("Small", "small"), ("Regular", "regular"), ("Large", "large"), ("Extra large", "extra_large")]

// MARK: camera layout

struct CameraLayoutSection: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .layout(let id) = model.selection, let l = model.layouts.first(where: { $0.id == id }) {
                SelectedItemGroup(model: model, title: "Layout section", span: TimeSpan(startNs: l.startNs, endNs: l.endNs)) {
                    LayoutSegmentControls(model: model, layout: l)
                }
            }
            CameraLayoutSettings(model: model)
            InspectorGroup("Layout over time") {
                InspectorAction("Add layout at playhead", symbol: "plus") { model.addLayoutAtPlayhead() }
                InspectorNote("Outside layout sections the default camera settings apply.")
            }
        }
    }
}

/// Settings of one layout section on the timeline.
private struct LayoutSegmentControls: View {
    @ObservedObject var model: EditorModel
    let layout: LayoutSegment
    var body: some View {
        let l = layout
        ChoiceRow("Layout", selection: Binding(get: { l.mode }, set: { model.setLayoutMode(id: l.id, $0) }),
                  options: layoutModes.map { ($0.label, $0.value) }, forceMenu: true)
        SwitchRow("Enabled", isOn: Binding(get: { l.enabled }, set: { model.setLayoutEnabled(id: l.id, $0) }))
            .help("A disabled range keeps its settings but the default layout applies there")
        if ["overlay", "cutout", "split"].contains(l.mode) { LayoutOwnSettings(model: model, layout: l) }
        InspectorAction("Remove layout", symbol: "trash") { model.deleteSelection() }
    }
}

/// 8-point position grid (corners and edge midpoints, no center); the chosen cell is the bright platter.
struct CameraPositionRow: View {
    @ObservedObject var model: EditorModel
    static let xs = [0.18, 0.5, 0.82], ys = [0.22, 0.5, 0.78]
    var body: some View {
        HStack(alignment: .top) {
            Text("Position").font(Yap.Font.body).foregroundStyle(Yap.label)
            Spacer(minLength: 8)
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: 3) { ForEach(0..<3, id: \.self) { c in cell(r, c) } }
                }
            }
        }
    }

    @ViewBuilder private func cell(_ r: Int, _ c: Int) -> some View {
        if r == 1 && c == 1 {
            Color.clear.frame(width: 26, height: 20)
        } else {
            let cur = model.numbers("camera.position")
            let on = cur.count == 2 && abs(cur[0] - Self.xs[c]) < 0.02 && abs(cur[1] - Self.ys[r]) < 0.02
            Button { model.set("camera.position", .array([.number(Self.xs[c]), .number(Self.ys[r])])) } label: {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(on ? 0.85 : 0.1))
                    .frame(width: 26, height: 20)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Camera position \(["top", "middle", "bottom"][r]) \(["left", "center", "right"][c])")
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        }
    }
}

/// Crop insets of the recording or the camera: four sliders and a reset. Also shown in the preview's crop popover.
struct CropSection: View {
    @ObservedObject var model: EditorModel
    var path = "canvas.crop"
    var title = "Crop recording"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty { Text(title).font(Yap.Font.caption).foregroundStyle(Yap.caption) }
            row("Left", \.left); row("Top", \.top); row("Right", \.right); row("Bottom", \.bottom)
            let c = model.cropInsets(path: path)
            InspectorAction("Reset crop") { model.setCrop(path: path, left: 0, top: 0, right: 0, bottom: 0) }
                .disabled(c.left + c.top + c.right + c.bottom == 0)
        }
    }
    private func row(_ title: String, _ side: WritableKeyPath<CropInsetValues, Double>) -> some View {
        CommitSlider(title: title, range: 0...0.9, get: { CropInsetValues(model.cropInsets(path: path))[keyPath: side] },
                     commit: { v in var c = CropInsetValues(model.cropInsets(path: path)); c[keyPath: side] = v
                               model.setCrop(path: path, left: c.left, top: c.top, right: c.right, bottom: c.bottom) },
                     text: { "\(Int($0 * 100)) %" })
    }
}

/// Mutable copy of the model's crop insets.
struct CropInsetValues {
    var left: Double, top: Double, right: Double, bottom: Double
    init(_ c: (left: Double, top: Double, right: Double, bottom: Double)) { left = c.left; top = c.top; right = c.right; bottom = c.bottom }
}

// MARK: audio

struct AudioSection: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .music(let id) = model.selection, let m = model.music.first(where: { $0.id == id }) {
                SelectedItemGroup(model: model, title: "♪ " + m.title, span: m.span) { MusicControls(model: model, item: m) }
            }
            MusicSection(model: model)          // the reference lists background audio first
            InspectorGroup("Microphone") { microphone }
            InspectorGroup("System audio") {
                ToggleRow(model: model, title: "Mute", path: "audio.system_muted")
                NumberRow(model: model, title: "Volume", path: "audio.system_gain_db", range: -48...12, unit: "dB", format: "%.0f")
            }
            if model.hasMouseData {            // click sounds follow recorded clicks
                InspectorGroup("Click sounds") {
                    ToggleRow(model: model, title: "Play a sound on clicks", path: "audio.click_sound.enabled")
                    PickerRow(model: model, title: "Sound", path: "audio.click_sound.variant", options: [("Soft", "soft"), ("Crisp", "crisp")])
                    NumberRow(model: model, title: "Volume", path: "audio.click_sound.gain_db", range: -48...12, unit: "dB", format: "%.0f")
                }
            }
            InspectorGroup("Volume changes over time") { AudioRangeRows(model: model) }
            InspectorGroup("Automatic edits") { SilenceRows(model: model) }
        }
    }

    @ViewBuilder private var microphone: some View {
        if model.hasMic {
            ToggleRow(model: model, title: "Mute", path: "audio.mic_muted")
            NumberRow(model: model, title: "Volume", path: "audio.mic_gain_db", range: -48...12, unit: "dB", format: "%.0f")
            ToggleRow(model: model, title: "Keep stereo microphone", path: "audio.stereo_mic")
            VoiceCleanupSection(model: model)
        } else {
            InspectorNote("This recording has no microphone track.")
        }
    }
}

/// "Find silent parts…" and what it found: cut them, speed them up, or dismiss.
private struct SilenceRows: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        switch model.silenceState {
        case .idle: InspectorAction("Find silent parts…", symbol: "waveform") { model.findSilences() }
        case .analyzing: InspectorBusy("Analyzing audio…")
        case .found(let spans):
            if spans.isEmpty {
                InspectorNote("No silent parts found.")
                InspectorAction("OK") { model.dismissSilences() }
            } else {
                let total = Double(spans.reduce(0) { $0 + $1.durationNs }) / 1e9
                InspectorInfo("\(spans.count) silent parts", String(format: "%.1f s", total))
                HStack(spacing: 6) {
                    InspectorAction("Cut them") { model.applySilences(speed: nil) }
                    InspectorAction("Speed up 4×") { model.applySilences(speed: 4) }
                }
                InspectorAction("Dismiss") { model.dismissSilences() }
            }
        case .failed(let msg): InspectorFailure(message: msg, button: "OK") { model.dismissSilences() }
        }
    }
}

/// Volume ramps of the mic or system audio on the timeline, each with its start and end level.
private struct AudioRangeRows: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        ForEach(model.audioRanges) { r in range(r) }
        HStack(spacing: 6) {
            InspectorAction("Lower system audio here") { model.addAudioRangeAtPlayhead(track: "system_audio") }
            if model.hasMic { InspectorAction("Lower mic here") { model.addAudioRangeAtPlayhead(track: "mic") } }
        }
    }

    private func range(_ r: AudioRangeRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(r.track == "mic" ? "Microphone" : "System audio").font(Yap.Font.label).foregroundStyle(Yap.label)
                Spacer(minLength: 4)
                Text("\(formatTimecode(r.span.startNs, showFraction: false)) – \(formatTimecode(r.span.endNs, showFraction: false))").technical()
                InspectorIconButton(symbol: "trash", label: "Remove volume change") { model.removeAudioRange(id: r.id) }
            }
            CommitSlider(title: "From", range: -96...24, get: { r.startGainDb }, commit: { model.updateAudioRange(id: r.id, startGainDb: $0) },
                         text: { "\(Int($0)) dB" }, step: 3)
            CommitSlider(title: "To", range: -96...24, get: { r.endGainDb }, commit: { model.updateAudioRange(id: r.id, endGainDb: $0) },
                         text: { "\(Int($0)) dB" }, step: 3)
        }
    }
}

struct VoiceCleanupSection: View {
    @ObservedObject var model: EditorModel
    private let p = "audio.speech_enhancement_settings."
    var body: some View {
        ToggleRow(model: model, title: "Clean up voice", path: "audio.speech_enhancement")
        if model.bool("audio.speech_enhancement") {
            InspectorMore("Voice") { voice }
        }
    }
    @ViewBuilder private var voice: some View {
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
        InspectorNote("Processed offline on this Mac; the recording file is never changed. Preview re-prepares audio after a change.")
    }
}

// MARK: keys

struct KeysSection: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        InspectorGroup("Key overlay", first: true) {
            ToggleRow(model: model, title: "Show typed keys", path: "cursor.key_overlay.enabled")
            if model.bool("cursor.key_overlay.enabled") { overlay }
            InspectorNote("Needs “Record keystrokes” turned on before recording.")
        }
    }

    @ViewBuilder private var overlay: some View {
        SwitchRow("Show single-key presses", isOn: Binding(get: { !model.bool("cursor.key_overlay.shortcuts_only", default: true) },
                                                           set: { model.set("cursor.key_overlay.shortcuts_only", bool: !$0) }))
        DurationRow(model: model, title: "Stays visible", path: "cursor.key_overlay.duration_ns", default: 1_000_000_000)
        let h = max(model.numbers("canvas.output_size").last ?? 1080, 1)
        NumberRow(model: model, title: "Size", path: "cursor.key_overlay.style.font_size", range: 0.075 * h...0.25 * h, unit: "%", format: "%.1f",
                  scale: 100 / h, defaultValue: 0.10 * h)
        InspectorMore("Position") {
            RectRow(model: model, title: "Position", path: "cursor.key_overlay.rect", fallback: [0.3, 0.82, 0.4, 0.12])
        }
        InspectorMore("Style") {
            ColorRow(model: model, title: "Text", path: "cursor.key_overlay.style.color")
            ColorRow(model: model, title: "Background", path: "cursor.key_overlay.style.background", opacity: true)
            NumberRow(model: model, title: "Corner radius", path: "cursor.key_overlay.style.radius", range: 0...48, unit: "px", format: "%.0f")
            NumberRow(model: model, title: "Opacity", path: "cursor.key_overlay.style.opacity", range: 0...1)
        }
        HiddenShortcutRows(model: model)
    }
}

/// Per-shortcut "hide" list: every key or chord captured on the edited timeline, with a switch that keeps it out of the overlay.
struct HiddenShortcutRows: View {
    @ObservedObject var model: EditorModel
    @State private var chords: [KeyChord] = []
    var body: some View {
        InspectorMore("Hide specific shortcuts", value: hiddenCount) {
            if chords.isEmpty { InspectorNote("No keys were captured on this timeline.") }
            ForEach(chords) { c in row(c) }
        }
        .onAppear { chords = model.project.keyChords() }
        .onChange(of: model.revision) { _, _ in chords = model.project.keyChords() }
    }
    private var hiddenCount: String { let n = chords.filter(\.hidden).count; return n == 0 ? "" : "\(n) hidden" }
    private func row(_ c: KeyChord) -> some View {
        HStack(spacing: 8) {
            Text(c.text).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Yap.label)
            if !c.isShortcut { Text("single key").font(Yap.Font.caption).foregroundStyle(Yap.caption) }
            Spacer(minLength: 8)
            PillSwitch(isOn: Binding(get: { c.hidden }, set: { model.setShortcutHidden(c.text, $0); chords = model.project.keyChords() }))
                .accessibilityLabel("Hide \(c.text)")
        }
        .frame(minHeight: Yap.Inspector.rowHeight)
    }
}

extension EditorModel {
    /// The overlay skips chords in `cursor.key_overlay.hidden_shortcuts` (exact canonical text, at most 256 entries); one undo step.
    public func setShortcutHidden(_ chord: String, _ hidden: Bool) {
        var list: [String] = []
        if case .array(let a)? = value("cursor.key_overlay.hidden_shortcuts") { list = a.compactMap { if case .string(let s) = $0 { s } else { nil } } }
        list.removeAll { $0 == chord }
        if hidden { list.append(chord) }
        set("cursor.key_overlay.hidden_shortcuts", .array(list.map { .string($0) }))
    }
}

// MARK: text, regions, intro/outro

struct ExtrasSection: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            selected
            InspectorGroup("Masks and highlights", first: true) { regions }
            InspectorGroup("Text and reactions") { text }
            InspectorGroup("Intro and outro") { IntroOutroRows(model: model) }
        }
    }

    @ViewBuilder private var selected: some View {
        if case .highlight(let id) = model.selection, let h = model.highlights.first(where: { $0.id == id }) {
            SelectedItemGroup(model: model, title: h.kind.label, span: h.span) { HighlightControls(model: model, region: h) }
        } else if case .text(let kind, let id) = model.selection, kind != .caption, let t = model.textItems(kind).first(where: { $0.id == id }) {
            SelectedItemGroup(model: model, title: kind.label, span: t.span) { TextControls(model: model, item: t) }
        }
    }

    @ViewBuilder private var regions: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], alignment: .leading, spacing: 6) {
            region("Highlight", "highlighter", .highlight)
            region("Spotlight", "scope", .spotlight)
            region("Blur mask", "aqi.medium", .blur)
            region("Cover mask", "rectangle.fill", .mask)
        }
        InspectorNote("Adds a 3 s region at the playhead. Drag its box in the preview; drag its bar on the timeline to retime it.")
    }

    private func region(_ title: String, _ symbol: String, _ kind: HighlightRegion.Kind) -> some View {
        Button { model.addHighlightAtPlayhead(kind: kind) } label: {
            Label(title, systemImage: symbol).lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(CapsuleButtonStyle(.secondary, height: 28))
    }

    @ViewBuilder private var text: some View {
        InspectorAction("Add text at playhead", symbol: "textformat") { model.addText(.annotation) }
        HStack(spacing: 4) {
            ForEach(reactionGlyphs, id: \.self) { g in
                Button(g) { model.addText(.reaction, text: g) }
                    .buttonStyle(CircleButtonStyle(size: 28)).accessibilityLabel("Add reaction \(g)")
            }
        }
        InspectorNote("Drag the text box in the preview to place it.")
    }
}

private struct IntroOutroRows: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        mode("Intro", path: "canvas.animation.entrance", intro: true)
        if model.string("canvas.animation.entrance", default: "none") != "none" {
            DurationRow(model: model, title: "Intro length", path: "canvas.animation.entrance_duration_ns")
        }
        mode("Outro", path: "canvas.animation.exit", intro: false)
        if model.string("canvas.animation.exit", default: "none") != "none" {
            DurationRow(model: model, title: "Outro length", path: "canvas.animation.exit_duration_ns")
        }
    }

    private func mode(_ title: String, path: String, intro: Bool) -> some View {
        ChoiceRow(title, selection: Binding(get: { model.string(path, default: "none") }, set: { model.set(path, string: $0) }),
                  options: Self.modes(intro: intro), forceMenu: true)
    }

    static func modes(intro: Bool) -> [(String, String)] {
        [("None", "none"), (intro ? "Fade in" : "Fade out", "fade"), (intro ? "Zoom in" : "Zoom out", "zoom"),
         ("Slide from left", "slide_left"), ("Slide from right", "slide_right"), ("Slide from top", "slide_up"), ("Slide from bottom", "slide_down")]
    }
}
