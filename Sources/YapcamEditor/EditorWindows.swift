import SwiftUI
import AppKit
import YapcamCore

/// Editor appearance: dark by default, like the reference editor; ui offers it in Settings (Editing).
public enum EditorAppearance: String, CaseIterable, Sendable {
    case dark, light, system
    public var label: String { switch self { case .dark: "Dark"; case .light: "Light"; case .system: "Match system" } }
    public var nsAppearance: NSAppearance? {
        switch self { case .dark: NSAppearance(named: .darkAqua); case .light: NSAppearance(named: .aqua); case .system: nil }
    }
}

@MainActor public enum EditorWindows {
    /// Applied to editor windows when they open and live to the open ones when changed (`applyAppearance()`).
    nonisolated(unsafe) public static var appearance: EditorAppearance = .dark { didSet { MainActor.assumeIsolated { applyAppearance() } } }
    /// Re-applies `appearance` to every open editor window.
    public static func applyAppearance() { controllers.values.forEach { $0.window?.appearance = appearance.nsAppearance } }

    private static var controllers: [String: EditorWindowController] = [:]
    /// Set by the app (it links YapcamCapture): runs on-device transcription for a package and returns the
    /// RecordingTranscript JSON (also written to recording/transcript.json). Nil → captions can only use an existing transcript.
    nonisolated(unsafe) public static var transcriber: (@Sendable (URL) async throws -> Data)?
    /// Same, with the editor's keyterms and language (capture: `contextualStrings`, locale). Preferred over `transcriber` when set.
    nonisolated(unsafe) public static var transcriberWithOptions: (@Sendable (URL, TranscriptionOptions) async throws -> Data)?
    /// Languages the on-device recognizer supports (from `SFSpeechRecognizer.supportedLocales()`); nil → only "Auto" is offered.
    nonisolated(unsafe) public static var languageProvider: (@Sendable () -> [TranscriptionLanguage])?

    /// Settings > "Autosave while editing" (ui). When false the editor saves only on ⌘S and when the window closes.
    nonisolated(unsafe) public static var autosaveEnabled = true
    /// Settings > Experimental > variable frame rate for MP4/MOV (ui). Read when an export starts.
    nonisolated(unsafe) public static var variableFrameRate: () -> Bool = { false }

    /// Opens (or focuses) the editor for a `.yapcam` package. Asks before restoring an
    /// unsaved autosave journal and offers relinking when media is missing.
    public static func open(package: URL) {
        let key = package.standardizedFileURL.path
        if let existing = controllers[key] { existing.window?.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        var restore = true
        if EditorDocument.hasUnsavedJournal(package) {
            let alert = NSAlert()
            alert.messageText = "Restore unsaved changes?"
            alert.informativeText = "“\(package.deletingPathExtension().lastPathComponent)” has edits that were not saved before Yapcam closed."
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: restore = true
            case .alertSecondButtonReturn: restore = false
            default: return
            }
        }
        do {
            let doc = try EditorDocument(package: package, restoreUnsavedChanges: restore)
            show(doc, key: key)
        } catch CoreError.missingMedia(let paths) {
            Relink.present(package: package, missing: paths) { open(package: package) }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't open the project"
            alert.runModal()
        }
    }

    /// Closes (and saves) the editor showing `package`, if one is open. Returns whether one was.
    @discardableResult
    public static func close(package: URL) -> Bool {
        guard let c = controllers[package.standardizedFileURL.path] else { return false }
        c.window?.close(); return true
    }
    /// Asks the editor showing `package` to confirm moving the recording to the Trash (File menu item of the app).
    @discardableResult
    public static func requestTrash(package: URL) -> Bool {
        guard let c = controllers[package.standardizedFileURL.path] else { return false }
        c.editorDocument.model.trashRequested = true; return true
    }
    /// Same for the editor window that is currently key. Returns false when none is.
    @discardableResult
    public static func requestTrashOfKeyEditor() -> Bool {
        guard let c = controllers.values.first(where: { $0.window?.isKeyWindow == true }) else { return false }
        c.editorDocument.model.trashRequested = true; return true
    }
    /// The model of the editor window that is key now (nil when none): the app's Edit menu and shortcuts talk to it.
    public static var keyModel: EditorModel? { controllers.values.first { $0.window?.isKeyWindow == true }?.editorDocument.model }
    /// Opens the crop popover of the key editor (File > Crop recorded area…). False when no editor is key.
    @discardableResult public static func requestCropOfKeyEditor() -> Bool {
        guard let m = keyModel else { return false }
        m.cropRequested = true; return true
    }
    public static func isOpen(package: URL) -> Bool { controllers[package.standardizedFileURL.path] != nil }

    /// Flushes pending edits in every open editor (call from applicationWillTerminate).
    public static func saveAll() { controllers.values.forEach { $0.editorDocument.model.saveNow() } }

    private static func show(_ doc: EditorDocument, key: String) {
        let controller = EditorWindowController(document: doc) { controllers[key] = nil }
        controllers[key] = controller
        controller.showWindow(nil)
        NSApp.activate()
    }
}

@MainActor final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let editorDocument: EditorDocument
    private let onClose: () -> Void

    init(document: EditorDocument, onClose: @escaping () -> Void) {
        self.editorDocument = document; self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = document.title
        window.appearance = EditorWindows.appearance.nsAppearance
        window.contentView = NSHostingView(rootView: EditorView(document: document))
        window.setFrameAutosaveName("YapcamEditor")
        window.center()
        super.init(window: window)
        window.delegate = self
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak document] _ in
            MainActor.assumeIsolated { document?.model.saveNow() }
        }
    }
    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        editorDocument.model.close()      // saves, cancels background work, makes the stale model inert
        editorDocument.player.pause()
        onClose()
    }
}

/// Missing-media relink: pick a replacement for each missing file; core's transactional
/// `Project.relink` installs them (rolling back on failure) and keeps all edits.
@MainActor enum Relink {
    static func present(package: URL, missing: [String], retry: () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Some media files are missing"
        alert.informativeText = "Locate each file to continue:\n\n" + missing.joined(separator: "\n")
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var replacements: [String: URL] = [:]
        for rel in missing {
            let panel = NSOpenPanel()
            panel.message = "Locate “\(rel)”"
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK, let src = panel.url else { return }
            replacements[rel] = src
        }
        do { _ = try Project.relink(package: package, replacements: replacements); retry() }
        catch {
            let a = NSAlert(error: error); a.messageText = "Couldn't relink"; a.runModal()
        }
    }
}
