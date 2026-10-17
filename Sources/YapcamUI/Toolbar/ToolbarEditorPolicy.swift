import AppKit
import Combine
import YapcamEditor

/// The floating recording toolbar steps aside while an editor is open (it covered the editor) and comes back when
/// the last editor closes, unless the user hid or showed it themselves meanwhile. Pure, for tests.
struct ToolbarEditorPolicy: Equatable {
    enum Action: Equatable { case none, hide, show }
    /// True while the toolbar is hidden because of an editor, so closing the last one brings it back.
    private(set) var hiddenForEditor = false

    /// An editor window opened (`count` editors open now, one more than before).
    mutating func editorOpened(toolbarVisible: Bool, recordingActive: Bool) -> Action {
        guard toolbarVisible, !recordingActive else { return .none }
        hiddenForEditor = true
        return .hide
    }

    /// The last editor window closed.
    mutating func lastEditorClosed(toolbarVisible: Bool) -> Action { restore(toolbarVisible: toolbarVisible) }

    /// A recording is starting (countdown or shortcut): its controls live on the toolbar, so it must be there.
    mutating func recordingStarted(toolbarVisible: Bool) -> Action { restore(toolbarVisible: toolbarVisible) }

    /// The user showed or hid the toolbar from the menu: their choice wins, nothing comes back on its own.
    mutating func userToggled() { hiddenForEditor = false }

    private mutating func restore(toolbarVisible: Bool) -> Action {
        defer { hiddenForEditor = false }
        return hiddenForEditor && !toolbarVisible ? .show : .none
    }
}

/// Applies `ToolbarEditorPolicy` to the real toolbar: listens to editor windows opening/closing and recording starts.
@MainActor final class ToolbarEditorCoordinator {
    static let shared = ToolbarEditorCoordinator()
    private var policy = ToolbarEditorPolicy()
    private var bag = Set<AnyCancellable>()
    private var lastCount = 0

    func start() {
        guard bag.isEmpty else { return }
        lastCount = EditorWindows.openCount
        NotificationCenter.default.publisher(for: EditorWindows.openCountDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.editorsChanged(to: note.userInfo?["count"] as? Int ?? EditorWindows.openCount) }
            .store(in: &bag)
        RecordingController.shared.$phase.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] phase in if phase != .idle && phase != .finishing { self?.apply { $0.recordingStarted(toolbarVisible: $1) } } }
            .store(in: &bag)
    }

    /// Menu "Show/Hide Toolbar".
    func userToggled() { policy.userToggled() }

    private func editorsChanged(to count: Int) {
        defer { lastCount = count }
        if count > lastCount {
            let recording = RecordingController.shared.phase != .idle
            apply { $0.editorOpened(toolbarVisible: $1, recordingActive: recording) }
        } else if count == 0, lastCount > 0 {
            apply { $0.lastEditorClosed(toolbarVisible: $1) }
        }
    }

    private func apply(_ decide: (inout ToolbarEditorPolicy, Bool) -> ToolbarEditorPolicy.Action) {
        let toolbar = ToolbarPanelController.shared
        switch decide(&policy, toolbar.isVisible) {
        case .hide: toolbar.hide()
        case .show: toolbar.show()
        case .none: break
        }
    }
}
