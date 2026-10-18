import AppKit
import Foundation
import Testing
@testable import YapcamUI

@MainActor @Suite struct Round8PlaceTests {
    @Test func placeSwitchTable() {
        typealias A = PlaceSwitch.Action
        #expect(PlaceSwitch.decide(toolbarVisible: false, editorFront: true, editorsExist: true) == A.showToolbar)
        #expect(PlaceSwitch.decide(toolbarVisible: true, editorFront: true, editorsExist: true) == A.showToolbar)
        #expect(PlaceSwitch.decide(toolbarVisible: true, editorFront: false, editorsExist: true) == A.showEditor)
        #expect(PlaceSwitch.decide(toolbarVisible: false, editorFront: false, editorsExist: true) == A.showEditor)
        #expect(PlaceSwitch.decide(toolbarVisible: true, editorFront: false, editorsExist: false) == A.showHome)
        #expect(PlaceSwitch.decide(toolbarVisible: false, editorFront: false, editorsExist: false) == A.showToolbar)
    }

    @Test func dockReopen() {
        #expect(ReopenDecision.decide(isRecording: true, editorSideExists: true) == .finishRecording)
        #expect(ReopenDecision.decide(isRecording: false, editorSideExists: true) == .showEditorSide)
        #expect(ReopenDecision.decide(isRecording: false, editorSideExists: false) == .showToolbar)
    }

    @Test func launchPlaces() {
        #expect(LaunchPlace.toolbar.plan(editorsOpen: false) == .init(toolbar: true, home: false))
        #expect(LaunchPlace.projects.plan(editorsOpen: false) == .init(toolbar: false, home: true))
        #expect(LaunchPlace.both.plan(editorsOpen: false) == .init(toolbar: true, home: true))
        #expect(LaunchPlace.projects.plan(editorsOpen: true) == .init(toolbar: false, home: false))   // a project from Finder is already open
        let s = AppSettings(store: UserDefaults(suiteName: "r8-launch-\(UUID())")!)
        #expect(s.launchPlace == .toolbar)
        s.launchPlace = .projects; s.resetToDefaults()
        #expect(s.launchPlace == .toolbar)
    }

    @Test func editorsReturnRules() {
        #expect(EditorReturn.afterPhaseChange(from: .recording, to: .idle))
        #expect(EditorReturn.afterPhaseChange(from: .countdown(2), to: .idle))        // cancelled countdown
        #expect(!EditorReturn.afterPhaseChange(from: .idle, to: .countdown(3)))
        #expect(!EditorReturn.afterPhaseChange(from: .recording, to: .paused))
        #expect(EditorReturn.afterToolbarHid(phase: .idle, pickerActive: false))
        #expect(!EditorReturn.afterToolbarHid(phase: .idle, pickerActive: true))
        #expect(!EditorReturn.afterToolbarHid(phase: .starting, pickerActive: false))
    }

    @Test func switchShortcutIsRebindableMenuShortcutWithoutClashes() {
        #expect(!HotkeyAction.switchPlace.isGlobal)
        let combo = HotkeyAction.switchPlace.defaultCombo
        #expect(combo?.menuKey?.key == "y")                // the letter Y on any layout
        let s = AppSettings(store: UserDefaults(suiteName: "r8-keys-\(UUID())")!)
        #expect(HotkeyManager.conflicts(in: s).isEmpty)
    }

    @Test func menusOfferToolbarProjectsAndSwitch() {
        _ = NSApplication.shared
        let main = MainMenu.build(target: AppDelegate())
        let window = main.items.first { $0.title == "Window" }?.submenu?.items.map(\.title) ?? []
        #expect(["Toolbar", "Projects", "Switch Toolbar / Editor"].allSatisfy(window.contains))
        let file = main.items.first { $0.title == "File" }?.submenu?.items.map(\.title) ?? []
        #expect(file.contains("New Recording") && !file.contains("Recordings…"))
        let dock = DockMenu.items(phase: .idle, showInDock: true).map(\.title)
        #expect(dock.contains("Projects"))
    }

    @Test func hotkeyFallbackKeepsNewRecordingOnCommandN() {
        _ = NSApplication.shared
        let file = MainMenu.build(target: AppDelegate()).items.first { $0.title == "File" }?.submenu
        let item = file?.items.first { $0.title == "New Recording" }
        #expect(item?.keyEquivalent == "n")
    }
}

@MainActor @Suite struct Round8HomeTests {
    private func library() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "r8-lib-\(UUID())", directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, age) in [("Alpha", 300.0), ("Zulu", 100.0)] {
            let p = dir.appending(path: "\(name).yapcam", directoryHint: .isDirectory)
            try fm.createDirectory(at: p, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: p.appending(path: "project.json"))
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: p.path)
        }
        try fm.createDirectory(at: dir.appending(path: "Broken.yapcam", directoryHint: .isDirectory), withIntermediateDirectories: true)   // nothing inside
        try Data("x".utf8).write(to: dir.appending(path: "Note.txt"))
        return dir
    }

    @Test func homeListsTheLibraryAndShowsABrokenPackageAsUnavailable() throws {
        let dir = try library(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = ProjectsModel()
        m.reload(in: dir, removed: [])
        #expect(m.projects.count == 3)                                      // the .txt is not a project
        #expect(m.projects.first { $0.name == "Broken" }?.available == false)
        #expect(m.projects.filter(\.available).map(\.name).sorted() == ["Alpha", "Zulu"])
        #expect(m.projects.map(\.modified) == m.projects.map(\.modified).sorted(by: >))      // newest first
        let zulu = try #require(m.projects.first { $0.name == "Zulu" })
        m.reload(in: dir, removed: [zulu.url.path])
        #expect(m.projects.count == 2)
    }

    @Test func gridSortsAndSearches() throws {
        let dir = try library(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = ProjectsModel(); m.reload(in: dir, removed: [])
        #expect(ProjectsModel.arrange(m.projects, query: "", sort: .name).map(\.name) == ["Alpha", "Broken", "Zulu"])
        #expect(ProjectsModel.arrange(m.projects.filter(\.available), query: "", sort: .date).map(\.name) == ["Zulu", "Alpha"])
        #expect(ProjectsModel.arrange(m.projects, query: " zu ", sort: .date).isEmpty == false)
        #expect(ProjectsModel.arrange(m.projects, query: "nope", sort: .date).isEmpty)
    }

    @Test func durationText() {
        #expect(ProjectsModel.durationText(65) == "1:05")
        #expect(ProjectsModel.durationText(3723) == "1:02:03")
        #expect(ProjectsModel.durationText(nil) == nil)
        #expect(ProjectsModel.durationText(.nan) == nil)
    }
}

@MainActor @Suite(.serialized) struct Round8RecordingReturnTests {
    @Test func editorSideWindowsComeBackAfterARecording() async throws {
        _ = NSApplication.shared
        PlaceCoordinator.shared.start()
        RecordingController.shared.debugSetPhase(.idle)
        HomeWindow.shared.show()
        let home = try #require(HomeWindow.shared.window)
        #expect(home.isVisible)
        PlaceCoordinator.shared.newRecording()                       // the editor's record button
        #expect(!home.isVisible)
        #expect(PlaceCoordinator.shared.awaitingRecording)
        RecordingController.shared.debugSetPhase(.recording)         // recording runs
        #expect(!home.isVisible)
        RecordingController.shared.debugSetPhase(.idle)              // finished or cancelled
        try await Task.sleep(for: .milliseconds(900))
        #expect(home.isVisible)
        #expect(!PlaceCoordinator.shared.awaitingRecording)
        home.orderOut(nil)
        ToolbarPanelController.shared.hide()
    }

    @Test func closingThePickerWithoutRecordingBringsThemBack() async throws {
        _ = NSApplication.shared
        PlaceCoordinator.shared.start()
        RecordingController.shared.debugSetPhase(.idle)
        HomeWindow.shared.show()
        let home = try #require(HomeWindow.shared.window)
        PlaceCoordinator.shared.newRecording()
        #expect(!home.isVisible)
        ToolbarPanelController.shared.hide()                         // Esc / close on the bar
        try await Task.sleep(for: .milliseconds(900))
        #expect(home.isVisible)
        home.orderOut(nil)
    }
}
