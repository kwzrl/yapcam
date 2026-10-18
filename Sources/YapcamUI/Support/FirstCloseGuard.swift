import AppKit
import YapcamEditor

/// "Keep recording?" when a fresh recording's editor window closes within seconds (off by default).
@MainActor final class FirstCloseGuard {
    static let shared = FirstCloseGuard()
    static let window: TimeInterval = 10

    /// Pure rule: ask only for a package that had no project yet when its editor opened, closed within the window.
    static func shouldAsk(enabled: Bool, wasFresh: Bool, openFor: TimeInterval) -> Bool {
        enabled && wasFresh && openFor >= 0 && openFor <= window
    }

    private struct Opened { let at: Date; let fresh: Bool }
    private var opened: [String: Opened] = [:]
    private var observer: NSObjectProtocol?

    static var confirmKeep: @MainActor (URL) -> Bool = { pkg in
        let a = NSAlert()
        a.messageText = "Keep this recording?"
        a.informativeText = "“\(pkg.deletingPathExtension().lastPathComponent)” was closed right after it was recorded."
        a.addButton(withTitle: "Keep"); a.addButton(withTitle: "Move to Trash")
        return a.runModal() == .alertFirstButtonReturn
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: EditorWindows.openCountDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    /// Called when an editor is about to open `package`.
    func willOpen(_ package: URL) {
        let key = package.standardizedFileURL.path
        guard opened[key] == nil else { return }
        let fresh = !FileManager.default.fileExists(atPath: package.appending(path: "project.json").path)
        opened[key] = Opened(at: Date(), fresh: fresh)
    }

    func check(now: Date = Date()) {
        for (key, info) in opened where !EditorWindows.isOpen(package: URL(fileURLWithPath: key)) {
            opened[key] = nil
            let pkg = URL(fileURLWithPath: key, isDirectory: true)
            guard Self.shouldAsk(enabled: AppSettings.shared.askKeepOnFirstClose, wasFresh: info.fresh, openFor: now.timeIntervalSince(info.at)),
                  FileManager.default.fileExists(atPath: pkg.path) else { continue }
            if !Self.confirmKeep(pkg) { try? ProjectActions.trash(pkg) }
        }
    }
}
