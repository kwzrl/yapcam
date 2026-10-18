import AppKit
import Foundation
import Testing
import YapcamCapture
import YapcamCore
@testable import YapcamUI

@MainActor @Suite struct Round7bTests {
    private func package(mic: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "r7b-\(UUID()).yapcam", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir.appending(path: "recording"), withIntermediateDirectories: true)
        try Data(#"{"tracks":{"mic":\#(mic)}}"#.utf8).write(to: dir.appending(path: "recording/session.json"))
        return dir
    }

    @Test func sessionJSONMicFlagsAreRead() throws {
        let on = try package(mic: #"{"speech_enhancement":true,"stereo_mic":true,"channels":2}"#)
        let off = try package(mic: #"{"channels":1}"#)
        defer { try? FileManager.default.removeItem(at: on); try? FileManager.default.removeItem(at: off) }
        #expect(ProjectActions.micFlags(in: on) == (true, true))
        #expect(ProjectActions.micFlags(in: off) == (false, false))
        #expect(ProjectActions.micFlags(in: URL(fileURLWithPath: "/tmp/fixture/none.yapcam")) == (false, false))
    }

    @Test func recordTimeMicChoicesReachCaptureOnlyWithAMic() {
        func opts(mic: String?) -> UIRecordingOptions {
            UIRecordingOptions(target: .display(1), systemAudio: false, microphoneID: mic, cameraID: nil,
                               cleanVoiceOnRecord: true, recordStereoMicrophone: true, recordKeystrokes: false, maxFPS: 30,
                               outputDirectory: URL(fileURLWithPath: "/tmp"))
        }
        let with = LiveEngine.captureOptions(for: opts(mic: "m"))
        #expect(with.cleanVoiceOnRecord && with.recordStereoMicrophone)
        let without = LiveEngine.captureOptions(for: opts(mic: nil))
        #expect(!without.cleanVoiceOnRecord && !without.recordStereoMicrophone)
    }

    @Test func stereoMicSettingDefaultsOffAndResets() {
        let s = AppSettings(store: UserDefaults(suiteName: "r7b-\(UUID())")!)
        #expect(!s.recordStereoMicrophone)
        s.recordStereoMicrophone = true; s.resetToDefaults()
        #expect(!s.recordStereoMicrophone)
    }

    @Test func autoLanguageIsPassedToCaptureLiterally() {
        #expect(TranscriptionWiring.localeIdentifier(for: "auto", system: "en_US") == "auto")
        #expect(TranscriptionWiring.localeIdentifier(for: "", system: "en_US") == "auto")
        #expect(TranscriptionWiring.localeIdentifier(for: "de-DE", system: "en_US") == "de-DE")
    }

    @Test func previewUsesItsOwnSessionOnlyUntilCaptureOwnsTheCamera() {
        for p in [RecordingPhase.idle, .countdown(3), .finishing] { #expect(CameraPreviewPanel.source(for: p) == .standalone) }
        for p in [RecordingPhase.starting, .recording, .paused] { #expect(CameraPreviewPanel.source(for: p) == .recording) }
    }

    @Test func lostCameraShowsAPlaceholderWithTheReason() {
        #expect(CameraPreviewPanel.disconnectedText("") == "Camera disconnected")
        #expect(CameraPreviewPanel.disconnectedText("Unplugged") == "Camera disconnected\nUnplugged")
        let panel = CameraPreviewPanel()
        #expect(panel.placeholderText == nil)
        panel.receive(.unavailable("Unplugged"))
        #expect(panel.placeholderText == "Camera disconnected\nUnplugged")
    }

    @Test func projectNamesAreMadeSafeForTheFileSystem() {
        #expect(ProjectActions.cleanName("a/b:c") == "a-b-c")
        #expect(ProjectActions.cleanName("  ..hidden ") == "hidden")
        #expect(ProjectActions.cleanName("tab\tname\u{7}") == "tabname")
        #expect(ProjectActions.cleanName(String(repeating: "x", count: 300)).count == 120)
        #expect(ProjectActions.cleanName("...") == "")
        #expect(ProjectActions.cleanName("Demo day") == "Demo day")
    }

    @Test func resetWindowPositionsClearsEveryRememberedSpot() {
        let store = UserDefaults(suiteName: "r7b-win-\(UUID())")!
        store.set([1.0, 2.0], forKey: "cameraPreviewOrigin")
        store.set("x", forKey: ToolbarPanelController.positionKeyPrefix + "1")
        store.set("x", forKey: "NSWindow Frame YapcamHome")
        store.set(true, forKey: "playSounds")
        #expect(WindowPositions.resetAll(in: store) == 3)
        #expect(store.object(forKey: "cameraPreviewOrigin") == nil)
        #expect(store.object(forKey: "playSounds") != nil)         // other settings stay
    }

    @Test func areaGuidesReadoutAndDimming() {
        let g = AreaGeometry.guides(in: CGRect(x: 100, y: 50, width: 400, height: 200))
        #expect(g.xs == [200, 300, 400] && g.ys == [100, 150, 200])
        #expect(AreaGeometry.readout(CGRect(x: 0, y: 0, width: 640, height: 360), max: CGSize(width: 1512, height: 982)) == "640 × 360 · max 1512 × 982")
        #expect(AreaGeometry.dimAlpha(dimOutside: true) == 0.45)
        #expect(AreaGeometry.dimAlpha(dimOutside: false) < 0.05)      // still catches the mouse
        let s = AppSettings(store: UserDefaults(suiteName: "r7b-dim-\(UUID())")!)
        #expect(s.dimAreaOutside)
        s.dimAreaOutside = false; s.resetToDefaults()
        #expect(s.dimAreaOutside)
    }

    @Test func menuBarMenuStartsADisplayWindowOrAreaRecording() {
        _ = NSApplication.shared
        let d = AppDelegate()
        let titles = MainMenu.statusMenu(target: d).items.map(\.title)
        #expect(["Record Display…", "Record Window…", "Record Area…"].allSatisfy(titles.contains))
        let item = NSMenuItem(title: "x", action: #selector(AppDelegate.pickArea), keyEquivalent: "")
        #expect(d.validateMenuItem(item) == (RecordingController.shared.phase == .idle))
    }

    @Test func widgetRenamesTheProjectAndRefusesTakenNames() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "r7b-w-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "Take.yapcam", directoryHint: .isDirectory), b = dir.appending(path: "Other.yapcam", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let m = QuickExportWidgetModel()
        m.package = a
        m.rename(to: "  "); #expect(m.title == "Take" && m.renameError == nil)
        m.rename(to: "Other"); #expect(m.title == "Take" && m.renameError != nil)
        m.rename(to: "Demo: day/1"); #expect(m.title == "Demo- day-1" && m.renameError == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Demo- day-1.yapcam").path))
    }

    @Test func busyCaptionsSayWhatIsHappening() {
        #expect(RecordingController.busyCaption(.finishing) == "Saving recording…")
        #expect(RecordingController.busyCaption(.starting) == "Starting…")
        #expect(RecordingController.busyHelp(.finishing).contains("Long recordings"))
    }

    @Test func importShowsALoaderUntilItIsDone() {
        _ = NSApplication.shared
        let text = BusyHUD.importText(URL(fileURLWithPath: "/tmp/fixture/clip.mov"))
        #expect(text == "Importing “clip.mov”…")
        BusyHUD.shared.show(text); #expect(BusyHUD.shared.isShowing)
        BusyHUD.shared.hide(); #expect(!BusyHUD.shared.isShowing)
    }

    @Test func onlyAWindowTakeRaisesAWindow() {
        #expect(RecordingController.windowToRaise(.window(42), enabled: true) == 42)
        #expect(RecordingController.windowToRaise(.window(42), enabled: false) == nil)
        #expect(RecordingController.windowToRaise(.display(1), enabled: true) == nil)
        let s = AppSettings(store: UserDefaults(suiteName: "r7b-raise-\(UUID())")!)
        #expect(s.raiseWindowOnStart)
    }

    @Test func tooltipsNameTheRealShortcut() {
        #expect(PrompterModel.playHelp(playing: false, shortcut: "⌥⌘.") == "Scroll the notes (⌥⌘.)")
        #expect(PrompterModel.playHelp(playing: true, shortcut: nil) == "Pause the prompter")
        #expect(QuickExportWidgetView.help("Copy", nil) == "Copy")
        #expect(AppSettings.shared.combo(for: .quickExportCopy) == nil || QuickExportWidgetView.help("Copy", AppSettings.shared.combo(for: .quickExportCopy)).hasPrefix("Copy ("))
    }
}
