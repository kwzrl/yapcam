import AppKit
import UniformTypeIdentifiers
import YapcamCore
import YapcamEditor

/// File-based presets (PRJ-02): look settings of a project (canvas, cursor, zoom defaults…)
/// saved as JSON via core's `exportPreset` / `importPreset`. Shared by copying the files.
@MainActor enum PresetStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Yapcam/Presets", directoryHint: .isDirectory)
    }

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
        RecordingController.shared.alert = AppAlert(title: title, message: e.localizedDescription)
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
        do { try PresetStore.apply(PresetStore.url(for: n), to: doc.project) } catch { fail("Could not apply preset", error) }
    }

    @objc private func applyFile() {
        guard let doc = EditorBridge.keyDocument(), let url = pickPreset() else { return }
        do { try PresetStore.apply(url, to: doc.project) } catch { fail("Could not apply preset", error) }
    }

    @objc private func exportFile() {
        guard let doc = EditorBridge.keyDocument() else { return }
        let p = NSSavePanel(); p.nameFieldStringValue = "Preset.yapcampreset"; p.allowedContentTypes = [.json]
        p.allowsOtherFileTypes = true
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try doc.project.exportPreset(to: url) } catch { fail("Could not export preset", error) }
    }

    @objc private func addToLibrary() {
        guard let url = pickPreset() else { return }
        do {
            try FileManager.default.createDirectory(at: PresetStore.directory, withIntermediateDirectories: true)
            let dest = PresetStore.url(for: PresetStore.clean(url.deletingPathExtension().lastPathComponent))
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch { fail("Could not add preset", error) }
    }

    @objc private func showFolder() {
        try? FileManager.default.createDirectory(at: PresetStore.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(PresetStore.directory)
    }

    private func pickPreset() -> URL? {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]; p.allowsOtherFileTypes = true
        p.message = "Choose a Yapcam preset file"
        return p.runModal() == .OK ? p.url : nil
    }
}
