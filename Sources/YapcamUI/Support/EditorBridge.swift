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

    static func keyEditor() -> EditorModel? { keyDocument()?.model }

    /// True while a text field is being edited: ⌘Z must undo typing, not the timeline.
    static var isEditingText: Bool { NSApp.keyWindow?.firstResponder is NSText }
}
