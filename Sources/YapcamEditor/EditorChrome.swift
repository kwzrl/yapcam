import SwiftUI
import AppKit
import YapcamCore

// Presets storage and actions of the editor.

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

// The title row (EditorTitleRow) and the stage controls (StageControls) live in Shell/; the transport row in TransportBar.swift.
