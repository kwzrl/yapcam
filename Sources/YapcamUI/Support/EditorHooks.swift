import Foundation
import YapcamEditor

/// Connects app settings to the editor's app-wide switches (autosave, variable frame rate export).
@MainActor enum EditorHooks {
    static func install(_ settings: AppSettings) {
        apply(settings)
        // Read when an export starts, so the Experimental toggle takes effect without a restart.
        let store = settings.d
        EditorWindows.variableFrameRate = { AppSettings.variableFrameRateInStore(store) }
    }

    static func apply(_ settings: AppSettings) { EditorWindows.autosaveEnabled = settings.autosaveEnabled }
}
