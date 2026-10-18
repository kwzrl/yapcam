import AppKit
import Combine
import YapcamEditor

/// Moves between the two places (recording toolbar, editor side) and keeps the editors out of the way of a recording
/// that was started from them.
@MainActor final class PlaceCoordinator {
    static let shared = PlaceCoordinator()

    /// Editor-side windows hidden for a recording, front to back.
    private(set) var hidden: [NSWindow] = []
    private(set) var awaitingRecording = false
    private var bag = Set<AnyCancellable>()
    private var lastPhase = RecordingPhase.idle
    private var lastEditorCount = 0

    func start() {
        guard bag.isEmpty else { return }
        lastEditorCount = EditorWindows.openCount
        RecordingController.shared.$phase.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] phase in
            guard let self else { return }
            let old = lastPhase; lastPhase = phase
            if awaitingRecording, EditorReturn.afterPhaseChange(from: old, to: phase) { restore(after: 0.5) }
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: EditorWindows.openCountDidChange).receive(on: DispatchQueue.main).sink { [weak self] note in
            guard let self else { return }
            let count = note.userInfo?["count"] as? Int ?? EditorWindows.openCount
            defer { lastEditorCount = count }
            if awaitingRecording, count > lastEditorCount { restore(after: 0.05) }     // the new project opened: bring the others back
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: ToolbarPanelController.didHide).receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.toolbarHid()
        }.store(in: &bag)
    }

    // MARK: Windows

    /// Visible (or minimized) editors and the projects home, front to back.
    func editorSideWindows() -> [NSWindow] {
        NSApp.orderedWindows.filter { ($0.isVisible || $0.isMiniaturized) && isEditorSide($0) }
    }

    func isEditorSide(_ w: NSWindow) -> Bool { w === HomeWindow.shared.window || EditorBridge.isEditorWindow(w) }

    var editorSideExists: Bool { !editorSideWindows().isEmpty }

    var editorFront: Bool {
        guard NSApp.isActive, let key = NSApp.keyWindow else { return false }
        return isEditorSide(key)
    }

    // MARK: Actions

    /// ⌘⇧Y and the Window menu item.
    func switchPlace() {
        switch PlaceSwitch.decide(toolbarVisible: ToolbarPanelController.shared.isVisible, editorFront: editorFront, editorsExist: editorSideExists) {
        case .showToolbar: showToolbar()
        case .showEditor: showEditorSide()
        case .showHome: showProjects()
        }
    }

    func showToolbar() {
        ToolbarEditorCoordinator.shared.userToggled()
        ToolbarPanelController.shared.show()
    }

    /// The last focused editor (or the home) to the front; the toolbar steps aside.
    func showEditorSide() {
        guard let top = editorSideWindows().first else { showProjects(); return }
        if top.isMiniaturized { top.deminiaturize(nil) }
        ToolbarEditorCoordinator.shared.hideForEditor()
        NSApp.activate()
        top.makeKeyAndOrderFront(nil)
    }

    func showProjects() {
        ToolbarEditorCoordinator.shared.hideForEditor()
        HomeWindow.shared.show()
    }

    /// "New Recording": the editor-side windows go out of the way and the toolbar picker shows.
    func newRecording() {
        let windows = editorSideWindows().filter { $0.isVisible }
        if !windows.isEmpty {
            hidden = windows
            awaitingRecording = true
            windows.forEach { $0.orderOut(nil) }
        }
        showToolbar()
    }

    /// Brings the hidden windows back; a project that opened meanwhile stays in front.
    func restore(after delay: TimeInterval = 0) {
        if delay <= 0 { restoreNow(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in MainActor.assumeIsolated { self?.restoreNow() } }
    }

    func restoreNow() {
        guard awaitingRecording else { return }
        let back = hidden
        hidden = []; awaitingRecording = false
        let fresh = editorSideWindows().first { w in !back.contains { $0 === w } }
        for w in back.reversed() { w.orderFront(nil) }
        if let fresh { fresh.makeKeyAndOrderFront(nil) } else { back.first?.makeKeyAndOrderFront(nil) }
        if !back.isEmpty { NSApp.activate() }
    }

    private func toolbarHid() {
        guard awaitingRecording else { return }
        // Pressing Start hides the picker a moment before the phase changes, so look again shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.awaitingRecording, !ToolbarPanelController.shared.isVisible else { return }
                let picking = SourceOverlay.shared.isActive || AreaSelector.shared.isActive || PickerState.shared.openMode != nil
                if EditorReturn.afterToolbarHid(phase: RecordingController.shared.phase, pickerActive: picking) { self.restoreNow() }
            }
        }
    }
}
