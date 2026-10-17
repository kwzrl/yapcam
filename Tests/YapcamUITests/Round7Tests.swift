import AppKit
import Foundation
import Testing
import YapcamCore
import YapcamEditor
@testable import YapcamUI

@MainActor @Suite struct Round7RecordingShellTests {
    // B-01 Dock menu
    @Test func dockMenuListsTheRightItemsPerPhase() {
        func titles(_ p: RecordingPhase, dock: Bool = true) -> [String] { DockMenu.items(phase: p, showInDock: dock).filter { $0.kind != .separator }.map(\.title) }
        #expect(titles(.recording) == ["Finish Recording", "Pause Recording", "Restart Recording…", "Cancel Recording…", "Settings…"])
        #expect(titles(.paused) == ["Finish Recording", "Resume Recording", "Restart Recording…", "Cancel Recording…", "Settings…"])
        #expect(titles(.idle) == ["New Recording", "Open Last Recording", "Settings…", "Keep in Dock"])
        #expect(titles(.countdown(3)) == ["Cancel Countdown"])
        #expect(DockMenu.items(phase: .starting, showInDock: true).first?.enabled == false)
        #expect(DockMenu.items(phase: .idle, showInDock: true).last?.checked == true)
        #expect(DockMenu.items(phase: .idle, showInDock: false).last?.checked == false)
    }
    @Test func dockMenuIsBuiltForTheCurrentPhaseWithLiveTargets() {
        _ = NSApplication.shared
        let d = AppDelegate()
        let m = d.applicationDockMenu(NSApp)
        #expect(m?.items.map(\.title).contains("New Recording") == true)
        #expect(m?.items.allSatisfy { $0.isSeparatorItem || ($0.target === d && $0.action != nil) } == true)
    }

    // B-03 Start / finish
    @Test func startStopOpensThePickerFirst() {
        typealias R = StartStopRule
        #expect(R.action(phase: .idle, pickerVisible: false, overlayActive: false) == .showPicker)
        #expect(R.action(phase: .idle, pickerVisible: true, overlayActive: false) == .begin)
        #expect(R.action(phase: .idle, pickerVisible: true, overlayActive: true) == .begin)
        #expect(R.action(phase: .idle, pickerVisible: false, overlayActive: true) == .begin)
        #expect(R.action(phase: .countdown(2), pickerVisible: true, overlayActive: false) == .cancelCountdown)
        #expect(R.action(phase: .recording, pickerVisible: false, overlayActive: false) == .stop)
        #expect(R.action(phase: .paused, pickerVisible: false, overlayActive: false) == .stop)
        #expect(R.action(phase: .starting, pickerVisible: false, overlayActive: false) == .none)
        #expect(R.action(phase: .finishing, pickerVisible: true, overlayActive: false) == .none)
    }

    // B-02 camera preview during a take
    @Test func cameraPreviewStaysDuringATakeUnlessHidden() {
        func show(_ p: RecordingPhase, bar: Bool = false, hidden: Bool = false) -> Bool {
            CameraPreviewPanel.shouldShow(barVisible: bar, phase: p, cameraID: "cam", cameraAvailable: true, permissionGranted: true, hidden: hidden)
        }
        for p: RecordingPhase in [.countdown(3), .starting, .recording, .paused] { #expect(show(p)) ; #expect(!show(p, hidden: true)) }
        #expect(!show(.idle) && show(.idle, bar: true) && !show(.finishing, bar: true))
        #expect(CameraPreviewPanel.opacity(for: .paused) < 1 && CameraPreviewPanel.opacity(for: .recording) == 1)
    }
    @Test func savedPreviewPositionIsUsedOnlyWhenStillOnAScreen() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        #expect(CameraPreviewPanel.savedOrigin([100, 200], screens: screens) == CGPoint(x: 100, y: 200))
        #expect(CameraPreviewPanel.savedOrigin([5000, 200], screens: screens) == nil)
        #expect(CameraPreviewPanel.savedOrigin(nil, screens: screens) == nil)
        #expect(CameraPreviewPanel.savedOrigin([1], screens: screens) == nil)
    }

    // B-04 speaker notes + prompter
    @Test func prompterScrollsWhenPlayingRegardlessOfTheRecordingPhase() {
        let m = PrompterModel(); m.speed = 8
        m.tick(dt: 1, maxOffset: 1000)
        #expect(m.offset == 0)                      // not playing: no movement
        m.playing = true
        m.tick(dt: 0.5, maxOffset: 1000)
        #expect(m.offset == PrompterRanges.pointsPerSecond(8) * 0.5)
        #expect(RecordingController.shared.phase == .idle)      // no take is running
    }
    @Test func prompterStopsAtTheEndAndRestartsFromTheTop() {
        let m = PrompterModel(); m.speed = 25; m.playing = true
        m.tick(dt: 10, maxOffset: 200)
        #expect(m.offset == 200 && !m.playing)
        m.togglePlay(maxOffset: 200)
        #expect(m.offset == 0 && m.playing)
        let empty = PrompterModel(); empty.playing = true
        empty.tick(dt: 1, maxOffset: 0)
        #expect(!empty.playing)                      // nothing to scroll
    }
    @Test func prompterSizeResetAndRanges() {
        let m = PrompterModel(); m.fontSize = 30
        #expect(!m.sizeIsDefault)
        m.resetSize()
        #expect(m.fontSize == 20 && m.sizeIsDefault)
        #expect(PrompterRanges.speed == 1...25 && PrompterRanges.speedDefault == 8)
        #expect(PrompterRanges.clampedSpeed(0) == 1 && PrompterRanges.clampedSpeed(99) == 25)
    }
    @Test func notesAreOneWindowAndThePlayShortcutOpensIt() {
        _ = NSApplication.shared
        let before = NotesWindow.shared.isVisible
        NotesWindow.shared.hide()
        NotesWindow.shared.togglePlay()
        #expect(NotesWindow.shared.isVisible && PrompterModel.shared.playing)
        PrompterModel.shared.playing = false; NotesWindow.shared.hide()
        if before { NotesWindow.shared.show() }
    }

    // B-05 / B-07 / B-08
    @Test func speakerNotesShortcutIsGlobal() {
        #expect(HotkeyAction.allCases.filter(\.isGlobal).contains(.toggleNotes))
    }
    @Test func activationPolicyKeepsTheDockIconWhileAnEditorIsOpen() {
        typealias A = AppSettings
        #expect(A.activationPolicy(showInDock: false, hideWhileRecording: false, recording: false, editorOpen: false) == .accessory)
        #expect(A.activationPolicy(showInDock: false, hideWhileRecording: false, recording: false, editorOpen: true) == .regular)
        #expect(A.activationPolicy(showInDock: false, hideWhileRecording: true, recording: true, editorOpen: true) == .regular)
        #expect(A.activationPolicy(showInDock: true, hideWhileRecording: true, recording: true, editorOpen: false) == .accessory)
        #expect(A.activationPolicy(showInDock: true, hideWhileRecording: true, recording: false, editorOpen: false) == .regular)
    }
    @Test func reuseLastProjectSettingsDefaultsToOn() {
        #expect(AppSettings(store: UserDefaults(suiteName: "r7reuse-\(UUID())")!).reuseLastProjectSettings)
    }
    @Test func initialLookPrecedence() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "r7-look-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func make(_ name: String, padding: Double?) throws -> (URL, Project) {
            let u = dir.appending(path: name, directoryHint: .isDirectory)
            let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/synthetic/basic.yapcam")
            try FileManager.default.copyItem(at: fixture, to: u)
            let p = try Project.create(package: u)
            if let padding { try p.apply(.set(path: "canvas.padding", value: .number(padding))); try p.save() }
            return (u, p)
        }
        func padding(_ p: Project) -> Double {
            let j = (try? JSONSerialization.jsonObject(with: p.snapshot().toJSON())) as? [String: Any]
            return ((j?["canvas"] as? [String: Any])?["padding"] as? NSNumber)?.doubleValue ?? -1
        }
        let (lastURL, _) = try make("Last.yapcam", padding: 0.31)
        // a preset marked as default (padding 0.62)
        let presetDir = dir.appending(path: "presets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: presetDir, withIntermediateDirectories: true)
        let store = YapcamEditor.PresetStore(directory: presetDir, defaults: UserDefaults(suiteName: "r7presets-\(UUID())")!)
        let (_, src) = try make("Src.yapcam", padding: 0.62)
        try src.exportPreset(to: store.url("Mine"))

        // 1. default preset + option on: the preset wins
        let (a, pa) = try make("A.yapcam", padding: nil)
        store.defaultName = "Mine"
        ProjectActions.applyInitialLook(to: pa, package: a, reuseLast: true, in: dir, presets: store)
        #expect(abs(padding(pa) - 0.62) < 0.001)
        // 2. no default preset + option on: the last project's look
        store.defaultName = nil
        let (b, pb) = try make("B.yapcam", padding: nil)
        let only = dir.appending(path: "only-last", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: only, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: lastURL, to: only.appending(path: "Last.yapcam"))
        ProjectActions.applyInitialLook(to: pb, package: b, reuseLast: true, in: only, presets: store)
        #expect(abs(padding(pb) - 0.31) < 0.001)                   // taken from the earlier project, not the preset
        // 3. option off, no default preset: standard look
        let (c, pc) = try make("C.yapcam", padding: nil)
        let standard = padding(pc)
        ProjectActions.applyInitialLook(to: pc, package: c, reuseLast: false, in: dir, presets: store)
        #expect(padding(pc) == standard)
    }
}
