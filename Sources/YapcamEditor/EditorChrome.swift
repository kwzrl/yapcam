import SwiftUI
import AppKit
import YapcamCore

// Window chrome of the editor: presets storage, transport row, speed and volume menus.

/// Per-task isolation for tests: each test runs with its own preset folder and defaults suite.
/// (Task-locals carry Sendable values, so the defaults are given by suite name.)
public enum PresetIsolation {
    @TaskLocal public static var directory: URL?
    @TaskLocal public static var defaultsSuiteName: String?
}

/// Where presets live, shared with the app's Presets menu. Resolution order: task-local override (tests), global override
/// (app self-tests), then `EditorStorage` (env `YAPCAM_PRESETS_DIR`, isolated test/self-test processes, else the real folder).
@MainActor public enum EditorPresets {
    public nonisolated(unsafe) static var globalDirectory: URL?
    public nonisolated(unsafe) static var globalDefaults: UserDefaults?

    public nonisolated static var isRunningUnderTests: Bool { EditorStorage.isIsolatedProcess }

    public static var directory: URL { PresetIsolation.directory ?? globalDirectory ?? EditorStorage.resolvedPresetsDirectory() }
    static var defaults: UserDefaults {
        if let n = PresetIsolation.defaultsSuiteName, let d = UserDefaults(suiteName: n) { return d }
        return globalDefaults ?? EditorStorage.sharedDefaults
    }
    /// The store for the current isolation context (new models and documents pick this up).
    public static var currentStore: PresetStore { PresetStore(directory: directory, defaults: defaults) }
    /// Applies the preset marked "use as default for new projects" (if any) to a freshly created project. Whoever creates a
    /// project (after-recording processing, quick export, import, the editor itself) calls this once, BEFORE adding automatic
    /// zooms or saving, so every new project starts from the same look. Returns whether a preset was applied.
    @discardableResult
    public static func applyDefaultPreset(to project: Project, from store: PresetStore? = nil) -> Bool {
        let store = store ?? currentStore
        guard let name = store.defaultName, FileManager.default.fileExists(atPath: store.url(name).path) else { return false }
        return (try? project.importPreset(from: store.url(name))) != nil
    }
    static func names() -> [String] { currentStore.names() }
    static func url(_ name: String) -> URL { currentStore.url(name) }
    static func clean(_ name: String) -> String { currentStore.clean(name) }
    static var defaultName: String? {
        get { currentStore.defaultName }
        set { currentStore.defaultName = newValue }
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
        let name = presetStore.clean(raw)
        guard !name.isEmpty else { lastError = "The preset needs a name."; return }
        do {
            try FileManager.default.createDirectory(at: presetStore.directory, withIntermediateDirectories: true)
            try project.exportPreset(to: presetStore.url(name))
        } catch { lastError = "Couldn't save the preset: \(error.localizedDescription)" }
    }
    /// True when the saved preset has exactly the settings of the project right now ("Matches project" badge).
    public func presetMatchesProject(named name: String) -> Bool {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("match-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? project.exportPreset(to: tmp)) != nil,
              let a = try? JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as? NSDictionary,
              let b = try? JSONSerialization.jsonObject(with: Data(contentsOf: presetStore.url(name))) as? NSDictionary else { return false }
        return a.isEqual(b)
    }
    /// "Update to match the current project": overwrites the preset file atomically.
    public func updatePreset(named name: String) {
        let tmp = presetStore.directory.appendingPathComponent(".update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try project.exportPreset(to: tmp); _ = try FileManager.default.replaceItemAt(presetStore.url(name), withItemAt: tmp) }
        catch { lastError = "Couldn't update the preset: \(error.localizedDescription)" }
    }
    public func renamePreset(from old: String, to raw: String) {
        let new = presetStore.clean(raw)
        guard !new.isEmpty, new != old else { return }
        guard !FileManager.default.fileExists(atPath: presetStore.url(new).path) else { lastError = "A preset named “\(new)” already exists."; return }
        do {
            try FileManager.default.moveItem(at: presetStore.url(old), to: presetStore.url(new))
            if presetStore.defaultName == old { presetStore.defaultName = new }
        } catch { lastError = "Couldn't rename the preset: \(error.localizedDescription)" }
    }
    public func removePreset(named name: String) {
        do { try FileManager.default.trashItem(at: presetStore.url(name), resultingItemURL: nil); if presetStore.defaultName == name { presetStore.defaultName = nil } }
        catch { lastError = "Couldn't remove the preset: \(error.localizedDescription)" }
    }
    /// Names of the presets applied most recently (newest first, at most 5; remembered).
    public func recentPresets() -> [String] { defaults.stringArray(forKey: "editor.recentPresets") ?? [] }
    public func applyPreset(at url: URL) {
        guard !isClosed else { return }
        let name = url.deletingPathExtension().lastPathComponent
        defaults.set(Array(([name] + recentPresets().filter { $0 != name }).prefix(5)), forKey: "editor.recentPresets")
        do { try project.importPreset(from: url); selectedWallpaperID = nil; noteExternalEdit() }
        catch { lastError = "Couldn't apply the preset: \(error.localizedDescription)" }
    }
}

// The title row (EditorTitleRow) and the stage controls (StageControls) live in Shell/.

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
            Spacer()
            HStack(spacing: 12) {
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
        .padding(.horizontal, EditorMetrics.l).padding(.vertical, EditorMetrics.xs + 2)
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
