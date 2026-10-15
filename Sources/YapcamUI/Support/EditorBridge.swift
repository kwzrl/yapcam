import AppKit
import YapcamEditor

/// Finds the editor behind the key window so the AppKit main menu can drive it.
/// `EditorWindows` keeps its window controllers private; its controller exposes the
/// document as a stored property `editorDocument`, which we read by reflection until
/// editor offers a public accessor (see docs/status/ui.md Requests).
@MainActor enum EditorBridge {
    static func find<T>(_ type: T.Type, labeled label: String, in object: Any) -> T? {
        Mirror(reflecting: object).children.first { $0.label == label }?.value as? T
    }

    static func keyDocument() -> EditorDocument? {
        guard let controller = NSApp.keyWindow?.windowController else { return nil }
        return find(EditorDocument.self, labeled: "editorDocument", in: controller)
    }

    /// Any open editor window's document (used by the live end-to-end driver).
    static func anyDocument() -> EditorDocument? {
        for w in NSApp.windows {
            if let c = w.windowController, let d = find(EditorDocument.self, labeled: "editorDocument", in: c) { return d }
        }
        return nil
    }

    /// After a recording stops the editor must be in front and key, every time. Activating a background
    /// app is only honored reliably with the explicit "ignore other apps" form, so use it, then order the
    /// editor windows front and make the newest one key (the floating toolbar must not stay key).
    static func bringEditorsToFront() {
        raiseEditors()
        // Window creation and SwiftUI layout settle a moment later; claim focus again once they have.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MainActor.assumeIsolated { raiseEditors() } }
    }

    private static func raiseEditors() {
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        let editors = NSApp.windows.filter { w in
            w.isVisible && w.windowController.map { find(EditorDocument.self, labeled: "editorDocument", in: $0) != nil } == true
        }
        for w in editors { w.orderFrontRegardless() }
        editors.last?.makeKeyAndOrderFront(nil)
    }

    /// True when the app is active and an editor window is the key window.
    static var editorIsFrontAndKey: Bool {
        guard NSApp.isActive, let key = NSApp.keyWindow, let c = key.windowController else { return false }
        return find(EditorDocument.self, labeled: "editorDocument", in: c) != nil
    }

    static func keyEditor() -> EditorModel? { keyDocument()?.model }

    /// True while a text field is being edited: ⌘Z must undo typing, not the timeline.
    static var isEditingText: Bool { NSApp.keyWindow?.firstResponder is NSText }
}
