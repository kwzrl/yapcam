import Testing
@testable import YapcamUI

@Suite struct ToolbarEditorPolicyTests {
    @Test func editorHidesTheToolbarAndTheLastCloseBringsItBack() {
        var p = ToolbarEditorPolicy()
        #expect(p.editorOpened(toolbarVisible: true, recordingActive: false) == .hide)
        #expect(p.editorOpened(toolbarVisible: false, recordingActive: false) == .none)   // a second editor
        #expect(p.hiddenForEditor)
        #expect(p.lastEditorClosed(toolbarVisible: false) == .show)
        #expect(!p.hiddenForEditor)
    }

    @Test func theUsersChoiceWins() {
        var p = ToolbarEditorPolicy()
        #expect(p.editorOpened(toolbarVisible: false, recordingActive: false) == .none)   // hidden by the user before
        #expect(p.lastEditorClosed(toolbarVisible: false) == .none)
        _ = p.editorOpened(toolbarVisible: true, recordingActive: false)
        p.userToggled()                                                                    // shown again from the menu, then hidden
        #expect(p.lastEditorClosed(toolbarVisible: false) == .none)
    }

    @Test func recordingKeepsOrBringsBackItsControls() {
        var p = ToolbarEditorPolicy()
        #expect(p.editorOpened(toolbarVisible: true, recordingActive: true) == .none)
        _ = p.editorOpened(toolbarVisible: true, recordingActive: false)
        #expect(p.recordingStarted(toolbarVisible: false) == .show)
        #expect(p.lastEditorClosed(toolbarVisible: true) == .none)
    }
}
