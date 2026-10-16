import SwiftUI
import AppKit
import YapcamCore

@MainActor public enum EditorWindows {
    private static var controllers: [String: EditorWindowController] = [:]
    /// Set by the app (it links YapcamCapture): runs on-device transcription for a package and returns the
    /// RecordingTranscript JSON (also written to recording/transcript.json). Nil → captions can only use an existing transcript.
    nonisolated(unsafe) public static var transcriber: (@Sendable (URL) async throws -> Data)?
    /// Same, with the editor's keyterms and language (capture: `contextualStrings`, locale). Preferred over `transcriber` when set.
    nonisolated(unsafe) public static var transcriberWithOptions: (@Sendable (URL, TranscriptionOptions) async throws -> Data)?
    /// Languages the on-device recogniser supports (from `SFSpeechRecognizer.supportedLocales()`); nil → only "Auto" is offered.
    nonisolated(unsafe) public static var languageProvider: (@Sendable () -> [TranscriptionLanguage])?

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
