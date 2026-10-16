import Foundation
import YapcamEditor

/// The folder look presets live in (GAP-UI-10). Nil = the standard folder.
@MainActor enum PresetsFolder {
    static func effective(_ chosen: URL?) -> URL { chosen ?? EditorStorage.realPresetsDirectory }

    /// Points the editor's preset store at the chosen folder (new editor windows and menus pick it up).
    static func apply(_ chosen: URL?) { EditorPresets.globalDirectory = chosen }
}
