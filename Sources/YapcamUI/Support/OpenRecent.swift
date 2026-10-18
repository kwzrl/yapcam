import AppKit
import YapcamEditor

/// File ▸ Open Recent: projects opened in an editor, recorded or imported are reported to NSDocumentController
/// (which also fills the Dock icon's menu). Newest first, at most 10.
@MainActor enum RecentDocuments {
    static let maxItems = 10
    /// Replaceable so tests never touch the real recents list.
    static var note: (URL) -> Void = { NSDocumentController.shared.noteNewRecentDocumentURL($0) }
    static var list: () -> [URL] = { NSDocumentController.shared.recentDocumentURLs }
    static var clear: () -> Void = { NSDocumentController.shared.clearRecentDocuments(nil) }
    static var exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }

    /// Self-test processes (isolated) never touch the user's real recents.
    static func noteOpened(_ package: URL, isolated: Bool = EditorStorage.isIsolatedProcess) {
        guard !isolated else { return }
        note(package)
    }

    /// The menu rows for a list of recents: only packages that still exist, capped.
    static func visible(_ urls: [URL], exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [URL] {
        Array(urls.filter(exists).prefix(maxItems))
    }

    /// Choosing a row: opens it, or explains that it moved and drops it from the list.
    static func choose(_ url: URL, open: (URL) -> Void = { ProjectActions.open($0) }) -> Bool {
        guard exists(url) else {
            RecordingController.shared.alert = AppAlert(title: "Can't open “\(url.deletingPathExtension().lastPathComponent)”",
                                                        message: "The recording was moved or deleted.")
            let rest = list().filter { $0 != url }
            clear(); for u in rest.reversed() { note(u) }
            return false
        }
        open(url)
        return true
    }
}

/// Rebuilds the Open Recent submenu each time it opens.
@MainActor final class OpenRecentMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = OpenRecentMenuDelegate()
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = RecentDocuments.visible(RecentDocuments.list())
        for u in urls {
            let i = NSMenuItem(title: u.deletingPathExtension().lastPathComponent, action: #selector(open(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = u
            menu.addItem(i)
        }
        if urls.isEmpty { let none = NSMenuItem(title: "No Recent Recordings", action: nil, keyEquivalent: ""); none.isEnabled = false; menu.addItem(none) }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearMenu), keyEquivalent: "")
        clear.target = self; clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }
    @objc private func open(_ sender: NSMenuItem) { if let u = sender.representedObject as? URL { _ = RecentDocuments.choose(u) } }
    @objc private func clearMenu() { RecentDocuments.clear() }
}
