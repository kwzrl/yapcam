import AppKit
import UniformTypeIdentifiers
import YapcamCore
import YapcamEditor

/// File-based presets (PRJ-02): look settings of a project (canvas, cursor, zoom defaults…)
/// saved as JSON via core's `exportPreset` / `importPreset`. Shared by copying the files.
@MainActor enum PresetStore {
    /// One source of truth shared with the editor (`EditorPresets`): the same folder, and the same test/self-test isolation.
    static var directory: URL { EditorPresets.directory }

    static func names() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "yapcampreset" }.map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func url(for name: String) -> URL { directory.appending(path: "\(name).yapcampreset") }

    static func clean(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
    }

    /// Saves the project's current look under `name`. Returns false if the name is empty.
    @discardableResult
    static func save(_ project: Project, as name: String) throws -> URL {
        let n = clean(name)
        guard !n.isEmpty else { throw EngineError.failed("The preset needs a name.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = url(for: n)
        try project.exportPreset(to: dest)
        return dest
    }

    static func apply(_ file: URL, to project: Project) throws { try project.importPreset(from: file) }

    /// Applies a preset to an open editor document so preview, inspector and saved state all follow.
    /// Core mutates the `Project` directly, which the editor's cached wrapper doesn't see, so refresh
    /// it through the wrapper (empty batch), redraw, nudge observers and persist.
    static func apply(_ file: URL, to doc: EditorDocument) throws {
        try doc.project.importPreset(from: file)
        try? doc.model.project.apply(.batch([]))
        doc.player.invalidate()
        doc.model.geometry = doc.model.geometry
        try doc.project.save()
    }

    /// Copies a preset file into the library. Choosing a file that is already the library's
    /// copy is a no-op; replacing goes through a temp copy so a failed copy never loses the old preset.
    @discardableResult
    static func addToLibrary(_ source: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = url(for: clean(source.deletingPathExtension().lastPathComponent))
        if isSameFile(source, dest) { return dest }
        let temp = directory.appending(path: ".incoming-\(UUID().uuidString)")
        try fm.copyItem(at: source, to: temp)
        defer { try? fm.removeItem(at: temp) }
        if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: temp) }
        else { try fm.moveItem(at: temp, to: dest) }
        return dest
    }

    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let ids = [a, b].map { try? $0.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier }
        if let x = ids[0], let y = ids[1] { return x.isEqual(y) }
        return a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// The "Presets" menu; items are rebuilt each time it opens.
@MainActor final class PresetsMenuController: NSObject, NSMenuDelegate {
    static let shared = PresetsMenuController()
    let menu = NSMenu(title: "Presets")

    override init() { super.init(); menu.delegate = self; menu.autoenablesItems = true }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hasEditor = EditorBridge.keyDocument() != nil
        func add(_ title: String, _ sel: Selector, enabled: Bool = true, object: Any? = nil) {
            let i = NSMenuItem(title: title, action: enabled ? sel : nil, keyEquivalent: "")
            i.target = self; i.representedObject = object; menu.addItem(i)
        }
        add("Save Current Look as Preset…", #selector(saveCurrent), enabled: hasEditor)
        menu.addItem(.separator())
        let names = PresetStore.names()
        if names.isEmpty {
            let none = NSMenuItem(title: "No presets yet", action: nil, keyEquivalent: ""); none.isEnabled = false; menu.addItem(none)
        }
        for n in names { add("Apply “\(n)”", #selector(applyNamed(_:)), enabled: hasEditor, object: n) }
        menu.addItem(.separator())
        add("Apply Preset File…", #selector(applyFile), enabled: hasEditor)
        add("Export Preset File…", #selector(exportFile), enabled: hasEditor)
        add("Add Preset File to Library…", #selector(addToLibrary))
        add("Show Presets Folder", #selector(showFolder))
    }

    private func fail(_ title: String, _ e: Error) {
        RecordingController.shared.alert = AppAlert(title: title, error: e)
    }

    @objc private func saveCurrent() {
        guard let doc = EditorBridge.keyDocument(),
              let name = Prompt.text(title: "Save Preset", message: "Name for this look (canvas, cursor, zoom defaults…)", initial: "My Preset") else { return }
        let n = PresetStore.clean(name)
        if FileManager.default.fileExists(atPath: PresetStore.url(for: n).path) {
            let a = NSAlert(); a.messageText = "Replace preset “\(n)”?"; a.addButton(withTitle: "Replace"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        do { try PresetStore.save(doc.project, as: n) } catch { fail("Could not save preset", error) }
    }

    @objc private func applyNamed(_ item: NSMenuItem) {
        guard let doc = EditorBridge.keyDocument(), let n = item.representedObject as? String else { return }
        do { try PresetStore.apply(PresetStore.url(for: n), to: doc) } catch { fail("Could not apply preset", error) }
    }

    @objc private func applyFile() {
        guard let doc = EditorBridge.keyDocument(), let url = pickPreset() else { return }
        do { try PresetStore.apply(url, to: doc) } catch { fail("Could not apply preset", error) }
    }

    @objc private func exportFile() {
        guard let doc = EditorBridge.keyDocument() else { return }
        let p = NSSavePanel(); p.nameFieldStringValue = "Preset.yapcampreset"; p.allowedContentTypes = [PresetFileType.type]
        p.allowsOtherFileTypes = true
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try doc.project.exportPreset(to: url) } catch { fail("Could not export preset", error) }
    }

    @objc private func addToLibrary() {
        guard let url = pickPreset() else { return }
        do { try PresetStore.addToLibrary(url)
        } catch { fail("Could not add preset", error) }
    }

    @objc private func showFolder() {
        try? FileManager.default.createDirectory(at: PresetStore.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(PresetStore.directory)
    }

    private func pickPreset() -> URL? {
        let p = NSOpenPanel(); p.allowedContentTypes = PresetFileType.openTypes; p.allowsOtherFileTypes = true
        p.message = "Choose a Yapcam preset file"
        return p.runModal() == .OK ? p.url : nil
    }
}

/// The `.yapcampreset` file type (declared in Info.plist as mov.yapcam.preset, conforming to public.json).
enum PresetFileType {
    static let type: UTType = UTType("mov.yapcam.preset") ?? UTType(filenameExtension: "yapcampreset") ?? .json
    /// What the open panels accept: our type, plain JSON presets from older versions.
    static var openTypes: [UTType] { [type, .json] }
    static func isPreset(_ url: URL) -> Bool { url.pathExtension.lowercased() == "yapcampreset" }

    /// Opening a preset file (Finder, File ▸ Import Preset…): added to the library, and applied when an editor is in front.
    @MainActor @discardableResult
    static func importPreset(_ url: URL) -> String? {
        do {
            let dest = try PresetStore.addToLibrary(url)
            let name = dest.deletingPathExtension().lastPathComponent
            if let doc = EditorBridge.keyDocument() { try PresetStore.apply(dest, to: doc) }
            else { RecordingController.shared.alert = AppAlert(title: "Preset added", message: "“\(name)” is now in the Presets menu.") }
            return name
        } catch {
            RecordingController.shared.alert = AppAlert(title: "Could not add preset", error: error)
            return nil
        }
    }
}
