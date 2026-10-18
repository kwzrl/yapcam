import Foundation

/// Closing the quick export widget: after a Copy or Save the project is kept or trashed on the user's say-so.
enum QuickExportCloseRule {
    enum Decision: Equatable { case justClose, askKeepOrTrash }
    static func decide(state: QuickExport.State, alwaysKeep: Bool, hasPackage: Bool, openInEditor: Bool) -> Decision {
        guard hasPackage, !alwaysKeep, !openInEditor else { return .justClose }
        if case .done = state { return .askKeepOrTrash }       // never while an export is running; nothing to ask when nothing was exported
        return .justClose
    }
}
