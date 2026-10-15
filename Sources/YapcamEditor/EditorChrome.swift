import SwiftUI
import AppKit

// Window chrome of the editor: top bar, controls above the preview, mini rail, transport row.

/// File-based look presets, shared with the app's Presets menu (same folder and file format).
@MainActor enum EditorPresets {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Yapcam/Presets", directoryHint: .isDirectory)
    }
    static func names() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "yapcampreset" }.map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    static func url(_ name: String) -> URL { directory.appending(path: "\(name).yapcampreset") }
    static func clean(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-") }

    /// Asks for a name (AppKit alert with a text field). nil = cancelled.
    static func promptName() -> String? {
        let alert = NSAlert()
        alert.messageText = "Save look as preset"
        alert.informativeText = "Name for this look (background, cursor, zoom defaults…)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); field.stringValue = "My Preset"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

extension EditorModel {
    public func savePreset(named raw: String) {
        let name = EditorPresets.clean(raw)
        guard !name.isEmpty else { lastError = "The preset needs a name."; return }
        do {
            try FileManager.default.createDirectory(at: EditorPresets.directory, withIntermediateDirectories: true)
            try project.exportPreset(to: EditorPresets.url(name))
        } catch { lastError = "Couldn't save the preset: \(error.localizedDescription)" }
    }
    public func applyPreset(at url: URL) {
        guard !isClosed else { return }
        do { try project.importPreset(from: url); selectedWallpaperID = nil; noteExternalEdit() }
        catch { lastError = "Couldn't apply the preset: \(error.localizedDescription)" }
    }
}

struct EditorTopBar: View {
    @ObservedObject var model: EditorModel
    let title: String
    let packageURL: URL?
    @Binding var showExport: Bool
    @State private var confirmTrash = false
    @State private var presetNames: [String] = []

    var body: some View {
        HStack(spacing: 10) {
            Button { if let packageURL { NSWorkspace.shared.activateFileViewerSelecting([packageURL]) } } label: { Image(systemName: "folder") }
                .help("Show in Finder").accessibilityLabel("Show in Finder").disabled(packageURL == nil)
            Button { confirmTrash = true } label: { Image(systemName: "trash") }
                .help("Move this recording to the Trash").accessibilityLabel("Move recording to Trash").disabled(packageURL == nil)
            Spacer()
            Text(title).font(.headline).lineLimit(1)
            if case .failed = model.saveState { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Couldn't save the project") }
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo)
                .help("Undo (⌘Z)").accessibilityLabel("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.canRedo)
                .help("Redo (⇧⌘Z)").accessibilityLabel("Redo")
            Button { model.paletteVisible = true } label: { Image(systemName: "command") }
                .help("Command palette (⌘K)").accessibilityLabel("Commands")
            Menu {
                Button("Save current look…") { if let n = EditorPresets.promptName() { model.savePreset(named: n) } }
                Divider()
                if presetNames.isEmpty { Text("No presets yet") }
                ForEach(presetNames, id: \.self) { n in Button("Apply “\(n)”") { model.applyPreset(at: EditorPresets.url(n)) } }
            } label: { Label("Presets", systemImage: "square.stack") }
                .menuStyle(.borderlessButton).fixedSize()
                .onAppear { presetNames = EditorPresets.names() }
                .help("Apply or save a look")
            Button { showExport = true } label: { Text("Export").fontWeight(.semibold).padding(.horizontal, 10) }
                .buttonStyle(.borderedProminent).controlSize(.regular)
                .help("Export the video").accessibilityLabel("Export")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("Move “\(title)” to the Trash?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                guard let url = packageURL else { return }
                // Close the window first (it saves), then trash, so nothing is written into a moved package.
                NSApp.keyWindow?.close()
                NSWorkspace.shared.recycle([url])
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The recording and its edits will be moved to the Trash.") }
    }
}

/// Above the preview: layout/aspect menu and the Crop button.
struct PreviewControlsBar: View {
    @ObservedObject var model: EditorModel
    @State private var showCrop = false
    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(AspectPreset.allCases, id: \.self) { a in
                    Button { model.setAspect(a) } label: {
                        if model.string("canvas.aspect") == a.rawValue { Label(a.label, systemImage: "checkmark") } else { Text(a.label) }
                    }
                }
            } label: { Label(aspectTitle, systemImage: "rectangle.dashed") }
                .menuStyle(.borderlessButton).fixedSize().help("Aspect ratio of the output")
            Button { showCrop = true } label: { Label("Crop", systemImage: "crop") }
                .popover(isPresented: $showCrop) { Form { CropSection(model: model) }.formStyle(.grouped).frame(width: 300, height: 300) }
                .help("Crop the recording")
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
    private var aspectTitle: String {
        let a = model.string("canvas.aspect", default: "16:9")
        return AspectPreset(rawValue: a)?.label ?? a
    }
}

/// Mini rail left of the preview: view zoom and fit.
struct PreviewLeftRail: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(spacing: 6) {
            railButton("plus.magnifyingglass", "Zoom preview in") { model.zoomPreview(by: 1.25) }
            railButton("minus.magnifyingglass", "Zoom preview out") { model.zoomPreview(by: 0.8) }
            railButton("arrow.up.left.and.down.right.magnifyingglass", "Fit preview") { model.resetPreviewZoom() }
            if model.previewZoom > 1 { Text("\(Int(model.previewZoom * 100))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.vertical, 8).frame(width: 40)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private func railButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(label).accessibilityLabel(label)
    }
}

/// Transport row: scissors, time, ⏮ ⏯ ⏭, edit actions, clip speed, timeline zoom.
struct TransportBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var playhead: PlayheadState
    init(model: EditorModel) { self.model = model; playhead = model.playhead }

    private var selectedClip: TimelineClip? {
        if case .clip(let id) = model.selection { return model.clips.first { $0.id == id } }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $model.cutToolActive) { Image(systemName: "scissors") }
                .toggleStyle(.button).help("Cut tool: click a clip to split it there (S splits at the playhead)")
                .accessibilityLabel("Cut tool")
            HStack(spacing: 8) {
                Text(formatTimecode(playhead.ns, showFraction: false)).monospacedDigit().frame(minWidth: 38, alignment: .trailing)
                Button { model.jumpToEditPoint(forward: false) } label: { Image(systemName: "backward.end.fill") }
                    .help("Previous edit point (⌥←)").accessibilityLabel("Previous edit point")
                Button { model.togglePlay() } label: { Image(systemName: playhead.isPlaying ? "pause.fill" : "play.fill").frame(width: 18) }
                    .help("Play / Pause (Space)").accessibilityLabel(playhead.isPlaying ? "Pause" : "Play")
                Button { model.jumpToEditPoint(forward: true) } label: { Image(systemName: "forward.end.fill") }
                    .help("Next edit point (⌥→)").accessibilityLabel("Next edit point")
                Text(formatTimecode(model.durationNs, showFraction: false)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 38, alignment: .leading)
            }
            Spacer()
            Button { model.splitAtPlayhead() } label: { Image(systemName: "rectangle.split.2x1") }
                .help("Split at playhead (S, ⌘B)").accessibilityLabel("Split at playhead")
            Button { model.addZoomAtPlayhead() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Add zoom at playhead (Z)").accessibilityLabel("Add zoom")
            Button { model.deleteSelection() } label: { Image(systemName: "trash") }
                .disabled(model.selection == .none).help("Delete selection (⌫)").accessibilityLabel("Delete selection")
            Toggle(isOn: $model.snappingEnabled) { Image(systemName: "magnet") }.toggleStyle(.button).help("Snapping").accessibilityLabel("Snapping")
            Divider().frame(height: 16)
            Menu {
                ForEach([0.25, 0.5, 1, 1.5, 2, 4, 8], id: \.self) { v in
                    Button(v == 1 ? "1x (normal)" : "\(v.formatted())x") { if let c = selectedClip { model.setSpeed(clipID: c.id, v) } }
                }
            } label: { Text(selectedClip.map { $0.speed == 1 ? "1x" : "\($0.speed.formatted())x" } ?? "1x").monospacedDigit() }
                .menuStyle(.borderlessButton).fixedSize().disabled(selectedClip == nil)
                .help(selectedClip == nil ? "Select a clip to change its speed" : "Clip speed").accessibilityLabel("Clip speed")
            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: Binding(get: { log2(model.geometry.pixelsPerSecond) },
                                      set: { model.geometry = TimelineGeometry(pixelsPerSecond: pow(2, $0)) }),
                       in: log2(TimelineGeometry.minPPS)...log2(TimelineGeometry.maxPPS))
                    .frame(width: 110).accessibilityLabel("Timeline zoom")
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
