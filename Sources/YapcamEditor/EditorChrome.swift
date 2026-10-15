import SwiftUI
import AppKit

// Window chrome of the editor: top bar, controls above the preview, mini rail, transport row.

/// File-based look presets, shared with the app's Presets menu (same folder and file format).
/// Per-task isolation for tests: each test runs with its own preset folder and defaults suite.
/// (Task-locals carry Sendable values, so the defaults are given by suite name.)
public enum PresetIsolation {
    @TaskLocal public static var directory: URL?
    @TaskLocal public static var defaultsSuiteName: String?
}

@MainActor public enum EditorPresets {
    // Where presets and the default-preset choice live. Tests and self-tests must never touch the real
    // locations (~/Library/Application Support/Yapcam/Presets, the app's UserDefaults): per-test isolation
    // is a task-local override, per-process isolation is the global override or the test default below.
    public nonisolated(unsafe) static var globalDirectory: URL?
    public nonisolated(unsafe) static var globalDefaults: UserDefaults?

    /// True inside `swift test` (XCTest or Swift Testing host processes).
    public nonisolated static let isRunningUnderTests: Bool = {
        let p = ProcessInfo.processInfo
        return NSClassFromString("XCTestCase") != nil || p.processName.contains("xctest") || p.processName.contains("swiftpm-testing")
            || (CommandLine.arguments.first ?? "").contains(".xctest")
    }()

    public static var directory: URL {
        if let d = PresetIsolation.directory ?? globalDirectory { return d }
        if let env = ProcessInfo.processInfo.environment["YAPCAM_PRESETS_DIR"], !env.isEmpty { return URL(filePath: env, directoryHint: .isDirectory) }
        if isRunningUnderTests {
            return FileManager.default.temporaryDirectory.appending(path: "yapcam-test-presets-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Yapcam/Presets", directoryHint: .isDirectory)
    }

    static var defaults: UserDefaults {
        if let n = PresetIsolation.defaultsSuiteName, let d = UserDefaults(suiteName: n) { return d }
        if let d = globalDefaults { return d }
        if isRunningUnderTests { return testDefaults }
        return .standard
    }
    private static let testDefaults = UserDefaults(suiteName: "mov.yapcam.Yapcam.tests-\(ProcessInfo.processInfo.processIdentifier)") ?? .standard
    static func names() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "yapcampreset" }.map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    static func url(_ name: String) -> URL { directory.appending(path: "\(name).yapcampreset") }
    static func clean(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-") }

    static let defaultKey = "yapcam.defaultPreset"
    /// The preset applied to every new project (nil = none).
    static var defaultName: String? {
        get { defaults.string(forKey: defaultKey) }
        set { defaults.set(newValue, forKey: defaultKey) }
    }

    /// Asks for a name (AppKit alert with a text field). nil = cancelled.
    static func promptName(title: String = "Save look as preset", initial: String = "My Preset", confirm: String = "Save") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Name for this look (background, cursor, zoom defaults…)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: confirm); alert.addButton(withTitle: "Cancel")
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
    /// True when the saved preset has exactly the settings of the project right now ("Matches project" badge).
    public func presetMatchesProject(named name: String) -> Bool {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("match-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? project.exportPreset(to: tmp)) != nil,
              let a = try? JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as? NSDictionary,
              let b = try? JSONSerialization.jsonObject(with: Data(contentsOf: EditorPresets.url(name))) as? NSDictionary else { return false }
        return a.isEqual(b)
    }
    /// "Update to match the current project": overwrites the preset file atomically.
    public func updatePreset(named name: String) {
        let tmp = EditorPresets.directory.appendingPathComponent(".update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try project.exportPreset(to: tmp); _ = try FileManager.default.replaceItemAt(EditorPresets.url(name), withItemAt: tmp) }
        catch { lastError = "Couldn't update the preset: \(error.localizedDescription)" }
    }
    public func renamePreset(from old: String, to raw: String) {
        let new = EditorPresets.clean(raw)
        guard !new.isEmpty, new != old else { return }
        guard !FileManager.default.fileExists(atPath: EditorPresets.url(new).path) else { lastError = "A preset named “\(new)” already exists."; return }
        do {
            try FileManager.default.moveItem(at: EditorPresets.url(old), to: EditorPresets.url(new))
            if EditorPresets.defaultName == old { EditorPresets.defaultName = new }
        } catch { lastError = "Couldn't rename the preset: \(error.localizedDescription)" }
    }
    public func removePreset(named name: String) {
        do { try FileManager.default.trashItem(at: EditorPresets.url(name), resultingItemURL: nil); if EditorPresets.defaultName == name { EditorPresets.defaultName = nil } }
        catch { lastError = "Couldn't remove the preset: \(error.localizedDescription)" }
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
                Button("Create preset from this look…") { if let n = EditorPresets.promptName() { model.savePreset(named: n); presetNames = EditorPresets.names() } }
                Divider()
                if presetNames.isEmpty { Text("No presets yet") }
                ForEach(presetNames, id: \.self) { n in
                    let badges = [model.presetMatchesProject(named: n) ? "Matches project" : nil, EditorPresets.defaultName == n ? "Default" : nil].compactMap { $0 }
                    Menu(badges.isEmpty ? n : "\(n)  ·  \(badges.joined(separator: ", "))") {
                        Button("Apply") { model.applyPreset(at: EditorPresets.url(n)) }
                        Button("Rename…") { if let new = EditorPresets.promptName(title: "Rename preset", initial: n, confirm: "Rename") { model.renamePreset(from: n, to: new); presetNames = EditorPresets.names() } }
                        Button("Update to match current project") { model.updatePreset(named: n) }
                        Button(EditorPresets.defaultName == n ? "Don't use as default" : "Use as default for new projects") {
                            EditorPresets.defaultName = EditorPresets.defaultName == n ? nil : n
                        }
                        Divider()
                        Button("Remove", role: .destructive) { model.removePreset(named: n); presetNames = EditorPresets.names() }
                    }
                }
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
                    .help(a.hint)
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
        let a = model.string("canvas.aspect", default: "source")
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
            Button { model.volumeMenuSystem = false; model.volumeMenuVisible = true } label: { Image(systemName: "speaker.wave.2") }
                .popover(isPresented: $model.volumeMenuVisible) { VolumeMenu(model: model) }
                .help("Volume (V; ⌃V for system audio)").accessibilityLabel("Volume")
            Button { model.speedMenuVisible = true } label: {
                Text(model.speedTargetClip.map { speedText($0.speed) } ?? "1x").monospacedDigit()
            }
            .popover(isPresented: $model.speedMenuVisible) { SpeedMenu(model: model) }
            .help("Clip speed (S)").accessibilityLabel("Clip speed")
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

func speedText(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))x" : String(format: "%gx", v) }

/// S: the reference's fixed speed list for the clip under the playhead (or the selected clip), plus "apply to all".
struct SpeedMenu: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let current = model.speedTargetClip?.speed
        VStack(alignment: .leading, spacing: 2) {
            Text("Clip speed").font(.headline).padding(.bottom, 4)
            ForEach(clipSpeedOptions, id: \.self) { v in
                Button { model.setSpeedOfTarget(v); dismiss() } label: {
                    HStack { Text(speedText(v)); Spacer(); if current == v { Image(systemName: "checkmark") } }.contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.vertical, 2)
            }
            Divider().padding(.vertical, 4)
            Button("Apply speed to all clips") { if let c = current { model.applySpeedToAll(c) }; dismiss() }.disabled(current == nil)
        }
        .padding(14).frame(width: 190)
    }
}

/// V / ⌃V: microphone or system-audio volume in 10 % steps (0 mutes).
struct VolumeMenu: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let system = model.volumeMenuSystem
        let current = model.volumePercent(system: system)
        VStack(alignment: .leading, spacing: 2) {
            Picker("", selection: $model.volumeMenuSystem) { Text("Microphone").tag(false); Text("System audio").tag(true) }
                .pickerStyle(.segmented).labelsHidden().padding(.bottom, 4)
            ForEach(Array(stride(from: 100, through: 0, by: -10)), id: \.self) { p in
                Button { model.setVolume(percent: p, system: system); dismiss() } label: {
                    HStack { Text(p == 0 ? "Muted" : "\(p)%"); Spacer(); if abs(current - p) < 5 { Image(systemName: "checkmark") } }.contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.vertical, 2)
            }
        }
        .padding(14).frame(width: 210)
    }
}
