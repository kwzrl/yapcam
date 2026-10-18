import Foundation

/// Toolbar ↔ editor switching (Round 8). The app (ui) assigns the hooks; the editor only calls them.
extension EditorWindows {
    /// Title-row record button, ⌘K "New Recording": the app hides the editor windows and shows the toolbar picker.
    nonisolated(unsafe) public static var onRecordRequested: (@MainActor () -> Void)?
    /// "Projects" entries (title-row menu, ⌘K): the app shows the projects home.
    nonisolated(unsafe) public static var onShowProjects: (@MainActor () -> Void)?
}

extension EditorModel {
    /// Whether the app can start a recording from the editor (the record button is hidden otherwise).
    public var canRecordFromEditor: Bool { EditorWindows.onRecordRequested != nil }
    public var canShowProjects: Bool { EditorWindows.onShowProjects != nil }

    public func requestNewRecording() { EditorWindows.onRecordRequested?() }
    public func showProjects() { EditorWindows.onShowProjects?() }

    var placeCommands: [PaletteCommand] {
        [PaletteCommand(title: "New Recording", shortcut: "⌘N", enabled: canRecordFromEditor) { [self] in requestNewRecording() },
         PaletteCommand(title: "Show Projects", shortcut: "", enabled: canShowProjects) { [self] in showProjects() }]
    }
}
