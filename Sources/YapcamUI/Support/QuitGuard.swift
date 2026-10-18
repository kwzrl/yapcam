import AppKit
import YapcamEditor

/// Quitting while an export runs would lose it: ask first.
@MainActor enum QuitGuard {
    /// Pure rule: is any export (the widget's or an editor's) still running?
    static func exportRunning(quick: QuickExport.State, editors: [Bool]) -> Bool {
        if case .working = quick { return true }
        return editors.contains(true)
    }

    static var isExporting: Bool {
        exportRunning(quick: QuickExport.shared.state, editors: EditorWindows.openDocuments.map { $0.export.isRunning })
    }

    /// true = quit anyway.
    static var confirmQuit: @MainActor () -> Bool = {
        let a = NSAlert()
        a.messageText = "An export is still running"
        a.informativeText = "If you quit now the export is cancelled. The recording itself is saved."
        a.addButton(withTitle: "Keep Exporting"); a.addButton(withTitle: "Quit Anyway")
        return a.runModal() == .alertSecondButtonReturn
    }

    /// nil when quitting can go on.
    static func shouldBlockQuit() -> Bool { isExporting && !confirmQuit() }
}
