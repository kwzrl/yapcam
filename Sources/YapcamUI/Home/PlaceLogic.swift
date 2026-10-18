import Foundation

/// Yapcam has two equal places: the recording toolbar and the editor side (editors and the projects home).
/// These are the decisions, as pure functions, so the windows around them stay thin.

/// What the switch shortcut (⌘⇧Y) does.
enum PlaceSwitch {
    enum Action: Equatable { case showToolbar, showEditor, showHome }

    /// Editor in front → toolbar. Otherwise an editor-side window exists → bring it to the front.
    /// Toolbar up and nothing to edit → the projects home. Nothing up at all → the toolbar.
    static func decide(toolbarVisible: Bool, editorFront: Bool, editorsExist: Bool) -> Action {
        if editorFront { return .showToolbar }
        if editorsExist { return .showEditor }
        return toolbarVisible ? .showHome : .showToolbar
    }
}

/// Clicking the Dock icon.
enum ReopenDecision {
    enum Action: Equatable { case finishRecording, showEditorSide, showToolbar }

    /// A recording in progress asks to finish; an editor or home window comes to the front; otherwise the toolbar.
    static func decide(isRecording: Bool, editorSideExists: Bool) -> Action {
        if isRecording { return .finishRecording }
        return editorSideExists ? .showEditorSide : .showToolbar
    }
}

/// Settings ▸ General ▸ "On launch show".
enum LaunchPlace: String, CaseIterable, Identifiable {
    case toolbar, projects, both
    var id: String { rawValue }
    var label: String { switch self { case .toolbar: "Toolbar"; case .projects: "Projects"; case .both: "Toolbar and Projects" } }

    struct Plan: Equatable { var toolbar: Bool; var home: Bool }

    /// A project handed over by Finder opens its own editor, so the home stays away then.
    func plan(editorsOpen: Bool) -> Plan {
        let wantsHome = self != .toolbar && !editorsOpen
        let wantsToolbar = self != .projects
        return Plan(toolbar: wantsToolbar, home: wantsHome)
    }
}

/// When the editors that were hidden for a recording come back.
enum EditorReturn {
    /// A recording (or its countdown) ended in any way: finished, cancelled, failed.
    static func afterPhaseChange(from old: RecordingPhase, to new: RecordingPhase) -> Bool { new == .idle && old != .idle }

    /// The toolbar was closed while nothing is recording and no source is being picked: the user backed out.
    static func afterToolbarHid(phase: RecordingPhase, pickerActive: Bool) -> Bool { phase == .idle && !pickerActive }
}
