import SwiftUI
import UniformTypeIdentifiers
import YapcamCore
import YapcamDesign

// Controls of selected items (regions, text, music) and the background-audio library.

// MARK: regions

struct HighlightControls: View {
    @ObservedObject var model: EditorModel
    let region: HighlightRegion
    var body: some View {
        let id = region.id
        ChoiceRow("Style", selection: Binding(get: { region.kind }, set: { model.setHighlightKind(id: id, $0) }),
                  options: HighlightRegion.Kind.allCases.map { ($0.label, $0) }, forceMenu: true)
        ChoiceRow("Follows", selection: Binding(get: { region.space }, set: { v in model.updateHighlight(id: id) { $0.space = v } }),
                  options: [("Screen", "source"), ("Canvas", "canvas")])
        InspectorNote(region.space == "source" ? "Moves with zoom and crop." : "Stays fixed on the canvas.")
        SwitchRow("Enabled", isOn: Binding(get: { region.enabled }, set: { model.setHighlightEnabled(id: id, $0) }))
        motion
        if region.kind == .blur { BlurStrengthRow(model: model, region: region) }
        if region.kind != .blur { regionColor("Fill", get: { region.fill }, set: { c in model.updateHighlight(id: id) { $0.fill = c } }) }
        if region.kind != .mask && region.kind != .blur {
            regionColor("Outline", get: { region.stroke }, set: { c in model.updateHighlight(id: id) { $0.stroke = c } })
        }
        if region.kind != .blur { slider("Outline width", 0...16, 1, "pt", { region.strokeWidth }) { v in { $0.strokeWidth = v } } }
        slider("Corner radius", 0...64, 2, "pt", { region.radius }) { v in { $0.radius = v } }
        if region.kind != .mask && region.kind != .blur {
            CommitSlider(title: "Dim outside", range: 0.1...0.9, get: { region.dimOpacity },
                         commit: { v in model.updateHighlight(id: id) { $0.dimOpacity = min(max(v, 0.1), 0.9) } },
                         text: { "\(Int(($0 * 100).rounded())) %" }, step: 0.1)
            InspectorAction("Apply to all highlights") { model.applyHighlightStyleToAll(from: id) }.disabled(model.highlights.count < 2)
        }
        InspectorAction("Remove region", symbol: "trash") { model.deleteSelection() }
    }

    /// Moving mask: keyframes of the box; the box is interpolated between them.
    @ViewBuilder private var motion: some View {
        HStack(spacing: 6) {
            InspectorAction("Add keyframe at playhead", symbol: "diamond") { model.addRegionKeyframeAtPlayhead(id: region.id) }
            if !region.keyframes.isEmpty { InspectorAction("Remove motion") { model.removeRegionKeyframes(id: region.id) } }
        }
        if !region.keyframes.isEmpty {
            InspectorNote("\(region.keyframes.count) keyframe\(region.keyframes.count == 1 ? "" : "s"). Drag the box at another time to move that keyframe.")
        }
    }

    private func slider(_ title: String, _ range: ClosedRange<Double>, _ step: Double, _ unit: String, _ get: @escaping () -> Double,
                        _ change: @escaping (Double) -> (inout HighlightRegion) -> Void) -> some View {
        CommitSlider(title: title, range: range, get: get, commit: { v in model.updateHighlight(id: region.id, change(v)) },
                     text: { "\(Int($0)) \(unit)" }, step: step)
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
    var body: some View {
        CommitSlider(title: "Blur strength", range: HighlightRegion.blurRadiusRange, get: { region.blurRadius },
                     commit: { v in model.updateHighlight(id: region.id) { $0.blurRadius = v } }, text: { "\(Int($0)) px" }, step: 1)
    }
}

// MARK: text

struct TextControls: View {
    @ObservedObject var model: EditorModel
    let item: TextItem
    @State private var draft = ""
    var body: some View {
        let kind = item.kind, id = item.id
        RecessedTextArea(kind == .reaction ? "Emoji" : "Text", text: $draft, onSubmit: commitText)
            .onChange(of: item.id) { _, _ in draft = item.text }
            .onAppear { draft = item.text }
            .accessibilityLabel("Text content")
        InspectorAction("Apply text", symbol: "checkmark") { commitText() }.disabled(draft == item.text)
        ChoiceRow("Follows", selection: Binding(get: { item.space }, set: { v in model.updateText(kind, id: id) { $0.space = v } }),
                  options: [("Canvas", "canvas"), ("Screen", "source")])
        CommitSlider(title: "Size", range: 8...400, get: { item.fontSize },
                     commit: { v in model.updateText(kind, id: id) { $0.fontSize = min(max(v, 8), 400) } }, text: { "\(Int($0)) px" }, step: 4)
        TextColor(title: "Text color", get: { item.color }, set: { c in model.updateText(kind, id: id) { $0.color = c } })
        TextColor(title: "Background", get: { item.background }, set: { c in model.updateText(kind, id: id) { $0.background = c } })
        CommitSlider(title: "Corner radius", range: 0...64, get: { item.radius },
                     commit: { v in model.updateText(kind, id: id) { $0.radius = max(0, v) } }, text: { "\(Int($0)) px" }, step: 2)
        CommitSlider(title: "Opacity", range: 0...1, get: { item.opacity },
                     commit: { v in model.updateText(kind, id: id) { $0.opacity = min(max(v, 0), 1) } },
                     text: { "\(Int(($0 * 100).rounded())) %" }, step: 0.1)
        InspectorAction("Delete", symbol: "trash") { model.deleteSelection() }
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

// MARK: background audio

/// Background audio: the app's own authored tracks by category (with preview), the user's audio folder, drag-and-drop of a file,
/// one volume (5 % by default), mute, and removal.
struct MusicSection: View {
    @ObservedObject var model: EditorModel
    @State private var category = ""
    @State private var dropTargeted = false
    var body: some View {
        let categories = model.musicCategories
        let active = category.isEmpty ? (categories.first?.id ?? "") : category
        InspectorGroup("Background audio", first: true) {
            ChoiceRow("Library", selection: Binding(get: { active }, set: { category = $0 }),
                      options: categories.map { ($0.title, $0.id) } + [("My audio", "user")], forceMenu: true)
            if active == "user" { UserMusicRows(model: model) } else { ForEach(model.musicTracks(in: active)) { t in track(t) } }
            if !model.music.isEmpty { placed }
            InspectorNote("The tracks are original scores made by the app; music starts at the playhead and runs to the end. Drop an audio file here to use your own.")
        }
        .dropDestination(for: URL.self) { urls, _ in model.dropMusic(urls: urls) } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Yap.Radius.control).strokeBorder(Yap.label, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .allowsHitTesting(false)
            }
        }
    }

    private func track(_ t: LibraryTrack) -> some View {
        let playing = model.previewingMusicID == t.id
        return HStack(spacing: 8) {
            InspectorIconButton(symbol: playing ? "stop.fill" : "play.fill", label: playing ? "Stop preview of \(t.name)" : "Preview \(t.name)",
                                active: playing) { model.toggleMusicPreview(trackID: t.id) }
                .help(playing ? "Stop the preview" : "Preview the track")
            Text(t.name).font(Yap.Font.body).foregroundStyle(Yap.label).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(t.beatsPerMinute) BPM").technical()
            InspectorIconButton(symbol: "plus", label: "Add \(t.name)") { model.addLibraryMusic(trackID: t.id) }
                .help("Add at the playhead")
        }
        .frame(minHeight: Yap.Inspector.rowHeight)
    }

    @ViewBuilder private var placed: some View {
        MusicVolumeSlider(model: model)
        SwitchRow("Mute background audio", isOn: Binding(get: { model.isMusicMuted }, set: { model.setMusicMuted($0) }))
        ForEach(model.music) { m in
            InspectorListRow(time: formatTimecode(m.startNs, showFraction: false), text: "♪ " + m.title,
                             selected: model.selection == .music(m.id)) { model.selection = .music(m.id) }
        }
        InspectorAction("Remove background audio", symbol: "trash") { model.removeAllMusic() }
    }
}

/// The user's own audio folder: its files with Add, the folder itself, and a file picker.
private struct UserMusicRows: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        let files = model.userMusicFiles()
        if files.isEmpty { InspectorNote("Put audio files in your audio folder, or drop one here.") }
        ForEach(files, id: \.self) { url in
            HStack(spacing: 8) {
                Image(systemName: "music.note").font(.system(size: 11)).foregroundStyle(Yap.caption)
                Text(url.deletingPathExtension().lastPathComponent).font(Yap.Font.body).foregroundStyle(Yap.label).lineLimit(1)
                Spacer(minLength: 4)
                InspectorIconButton(symbol: "plus", label: "Add \(url.deletingPathExtension().lastPathComponent)") { model.importMusicFile(url) }
            }
            .frame(minHeight: Yap.Inspector.rowHeight)
        }
        HStack(spacing: 6) {
            InspectorAction("Open folder", symbol: "folder") { model.revealUserMusicFolder() }
                .help("Open audio library folder")
            InspectorAction("Add file…") { chooseFile() }
        }
    }
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.importMusicFile(url) }
    }
}

/// Linear 0–1 volume of the background audio (default 0.05), one undo step on release; the value shows as a percentage.
struct MusicVolumeSlider: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        CommitSlider(title: "Volume", range: 0...1, get: { model.musicVolume }, commit: { model.setMusicVolume($0) },
                     text: { "\(Int(($0 * 100).rounded())) %" }, step: 0.01, defaultValue: EditorModel.defaultMusicVolume)
    }
}

struct MusicControls: View {
    @ObservedObject var model: EditorModel
    let item: MusicItem
    var body: some View {
        let id = item.id
        SwitchRow("Loop", isOn: Binding(get: { item.loop }, set: { model.setMusicLoop(id: id, $0) }))
        CommitSlider(title: "Fade in", range: 0...10, get: { Double(item.fadeInNs) / 1e9 },
                     commit: { model.setMusicFades(id: id, inNs: Int64($0 * 1e9), outNs: item.fadeOutNs) }, text: { String(format: "%.1f s", $0) }, step: 0.5)
        CommitSlider(title: "Fade out", range: 0...10, get: { Double(item.fadeOutNs) / 1e9 },
                     commit: { model.setMusicFades(id: id, inNs: item.fadeInNs, outNs: Int64($0 * 1e9)) }, text: { String(format: "%.1f s", $0) }, step: 0.5)
        SwitchRow("Lower during speech", isOn: Binding(get: { item.duckEnabled }, set: { model.setMusicDucking(id: id, enabled: $0, gainDb: item.duckGainDb) }))
        if item.duckEnabled {
            CommitSlider(title: "Lower by", range: 0...48, get: { -item.duckGainDb },
                         commit: { model.setMusicDucking(id: id, enabled: true, gainDb: -$0) }, text: { "\(Int($0)) dB" }, step: 3)
            InspectorNote("Uses caption timing as speech. Generate captions first.")
        }
        InspectorAction("Remove music", symbol: "trash") { model.deleteSelection() }
    }
}
