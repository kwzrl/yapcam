import AppKit
import YapcamCapture
import SwiftUI
import YapcamEditor
import YapcamRender
import Foundation
import Testing
@testable import YapcamUI

/// Round 5 (Screen Studio parity): behaviour that can be checked without a display or a live app.
@MainActor @Suite struct Round5DefaultsTests {
    static func settings() -> AppSettings { AppSettings(store: UserDefaults(suiteName: "mov.yapcam.Yapcam.r5-\(UUID().uuidString)")!) }

    @Test func freshInstallFollowsTheReferenceDefaults() {
        let s = Self.settings()
        #expect(!s.systemAudio)                      // system audio: off
        #expect(s.recordKeystrokes)                  // keystrokes: on
        #expect(s.playSounds)                        // begin / end sound: on
        #expect(s.showQuickExportWidget)             // after recording: quick export widget on
        #expect(s.showRecordingWidget && s.createAutoZooms && s.highlightRecordedArea)
        #expect(!s.hideDesktopIcons && s.countdown == 0 && s.autosaveEnabled && !s.reuseLastProjectSettings)
    }

    @Test func savedChoicesSurviveTheNewDefaults() {
        let suite = UserDefaults(suiteName: "mov.yapcam.Yapcam.r5-\(UUID().uuidString)")!
        suite.set(true, forKey: "systemAudio"); suite.set(false, forKey: "playSounds"); suite.set(false, forKey: "recordKeystrokes")
        suite.set(false, forKey: "showQuickExportWidget")
        let s = AppSettings(store: suite)
        #expect(s.systemAudio && !s.playSounds && !s.recordKeystrokes && !s.showQuickExportWidget)
    }
}

@Suite struct Round5AreaTests {
    let bounds = CGSize(width: 1000, height: 600)
    let r = CGRect(x: 100, y: 100, width: 300, height: 200)

    @Test func arrowsMoveByOneAndShiftByTen() {
        #expect(AreaGeometry.nudged(r, .right, shift: false, command: false, in: bounds).origin.x == 101)
        #expect(AreaGeometry.nudged(r, .up, shift: true, command: false, in: bounds).origin.y == 90)
    }

    @Test func commandArrowsResize() {
        let a = AreaGeometry.nudged(r, .right, shift: false, command: true, in: bounds)
        #expect(a.width == 301 && a.origin == r.origin)
        let b = AreaGeometry.nudged(r, .down, shift: true, command: true, in: bounds)
        #expect(b.height == 210)
        let c = AreaGeometry.nudged(r, .left, shift: true, command: true, in: bounds)
        #expect(c.width == 290)
    }

    @Test func nudgeStaysOnTheDisplayAndAboveTheDragMinimum() {
        let edge = CGRect(x: 700, y: 0, width: 300, height: 200)
        #expect(AreaGeometry.nudged(edge, .right, shift: true, command: false, in: bounds).maxX == 1000)
        #expect(AreaGeometry.nudged(edge, .up, shift: true, command: false, in: bounds).minY == 0)
        let tiny = CGRect(x: 10, y: 10, width: 16, height: 16)
        #expect(AreaGeometry.nudged(tiny, .left, shift: true, command: true, in: bounds).width == AreaGeometry.minSide)
        let big = CGRect(x: 0, y: 0, width: 1000, height: 600)
        #expect(AreaGeometry.nudged(big, .right, shift: true, command: true, in: bounds).width == 1000)
    }

    @Test func minimumSizeTextAndGate() {
        #expect(AreaGeometry.minimalSizeMessage == "Minimal size is 150×150px.")
        #expect(AreaGeometry.canRecord(CGRect(x: 0, y: 0, width: 150, height: 150)))
        #expect(!AreaGeometry.canRecord(CGRect(x: 0, y: 0, width: 149, height: 400)))
    }

    @Test func savedDimensionsAreNewestFirstUniqueAndCapped() {
        var l: [String] = []
        l = AreaGeometry.saving(CGSize(width: 1280, height: 720), into: l)
        l = AreaGeometry.saving(CGSize(width: 800, height: 600), into: l)
        l = AreaGeometry.saving(CGSize(width: 1280, height: 720), into: l)
        #expect(l == ["1280x720", "800x600"])
        for i in 0..<20 { l = AreaGeometry.saving(CGSize(width: 200 + i, height: 300), into: l) }
        #expect(l.count == 12 && l.first == "219x300")
    }

    @MainActor @Test func savedAreaSizesPersist() {
        let suite = UserDefaults(suiteName: "mov.yapcam.Yapcam.r5-\(UUID().uuidString)")!
        let s = AppSettings(store: suite)
        s.savedAreaSizes = ["1280x720"]
        #expect(AppSettings(store: suite).savedAreaSizes == ["1280x720"])
    }
}

@Suite struct Round5WindowTests {
    @Test func menuGroupsFollowCapturesPresetsInReferenceOrder() {
        let g = WindowAX.groups(fitting: CGSize(width: 3000, height: 1800))
        #expect(g.map(\.name) == ["16:9", "4:3", "9:16", "16:10", "Square"])
        #expect(g[0].sizes.first == CGSize(width: 1280, height: 720) && g[0].sizes.last == CGSize(width: 2560, height: 1440))
    }

    @Test func onlySizesThatFitTheDisplayAreOffered() {
        let small = WindowAX.groups(fitting: CGSize(width: 1440, height: 900))
        #expect(small.flatMap(\.sizes).allSatisfy { $0.width <= 1440 && $0.height <= 900 })
        #expect(small.first { $0.name == "16:9" }?.sizes == [CGSize(width: 1280, height: 720)])
        #expect(WindowAX.groups(fitting: CGSize(width: 300, height: 300)).isEmpty)
    }

    @Test func typedErrorsBecomeReadableMessages() {
        #expect(WindowAX.resizeMessage(for: CaptureError.permissionDenied(.accessibility)).contains("Accessibility"))
        #expect(WindowAX.resizeMessage(for: CaptureError.sourceUnavailable).contains("gone"))
        let e = CaptureWindowControlError.sizeNotApplied(requested: CGSize(width: 800, height: 600), actual: CGSize(width: 900, height: 600))
        #expect(WindowAX.resizeMessage(for: e).contains("900"))
    }
}

@Suite struct Round5PrompterTests {
    @Test func rangesMatchTheReference() {
        #expect(PrompterRanges.speed == 0...25 && PrompterRanges.opacity == 0.4...1 && PrompterRanges.font == 12...32)
        #expect(PrompterRanges.font.contains(PrompterRanges.fontDefault))
    }
    @Test func oldSavedFontSizesAreClamped() {
        #expect(PrompterRanges.clampedFont(64) == 32 && PrompterRanges.clampedFont(8) == 12 && PrompterRanges.clampedFont(20) == 20)
    }
}

@MainActor @Suite struct Round5DockTests {
    @Test func dockIconHidesWhileRecordingOnlyWhenAsked() {
        typealias S = AppSettings
        #expect(S.activationPolicy(showInDock: true, hideWhileRecording: true, recording: true) == .accessory)
        #expect(S.activationPolicy(showInDock: true, hideWhileRecording: true, recording: false) == .regular)
        #expect(S.activationPolicy(showInDock: true, hideWhileRecording: false, recording: true) == .regular)
        #expect(S.activationPolicy(showInDock: false, hideWhileRecording: false, recording: false) == .accessory)
        #expect(S.activationPolicy(showInDock: false, hideWhileRecording: true, recording: true) == .accessory)
    }
    @Test func hideDockWhileRecordingDefaultsOnAndPersists() {
        let suite = UserDefaults(suiteName: "mov.yapcam.Yapcam.r5-\(UUID().uuidString)")!
        let s = AppSettings(store: suite)
        #expect(s.hideDockWhileRecording)
        s.hideDockWhileRecording = false
        #expect(!AppSettings(store: suite).hideDockWhileRecording)
    }
}

@Suite struct Round5BarTests {
    @Test func timerGrowsWithTheRecording() {
        #expect(RecordingTimeFormat.string(0) == "0:00")
        #expect(RecordingTimeFormat.string(65) == "1:05")
        #expect(RecordingTimeFormat.string(599) == "9:59")
        #expect(RecordingTimeFormat.string(600) == "10:00")
        #expect(RecordingTimeFormat.string(3599) == "59:59")
        #expect(RecordingTimeFormat.string(3600) == "1:00:00")
        #expect(RecordingTimeFormat.string(10 * 3600 + 5) == "10:00:05")
        #expect(RecordingTimeFormat.string(-3) == "0:00")
    }

    @Test func deviceAndSystemAudioLabels() {
        #expect(DeviceLabels.camera(name: nil) == "No camera" && DeviceLabels.camera(name: "FaceTime HD") == "FaceTime HD")
        #expect(DeviceLabels.microphone(name: nil) == "No microphone")
        #expect(DeviceLabels.menuName("Studio Mic", isDefault: true) == "Studio Mic (default)")
        #expect(DeviceLabels.menuName("Studio Mic", isDefault: false) == "Studio Mic")
        #expect(SystemAudioChoice.all.buttonLabel(appCount: 0) == "Record system audio")
        #expect(SystemAudioChoice.selected.buttonLabel(appCount: 3) == "Sound from 3 apps")
        #expect(SystemAudioChoice.selected.buttonLabel(appCount: 1) == "Sound from 1 app")
        #expect(SystemAudioChoice.off.buttonLabel(appCount: 0) == "No system audio")
        #expect(SystemAudioChoice.allCases == [.all, .selected, .off])
        #expect(SystemAudioChoice.off.title == "Don't record system audio")
    }

    @Test func digitKeysPickTheSourceUnlessTyping() {
        #expect(OverlayKeys.action(keyCode: 18, typing: false) == .mode(.display))
        #expect(OverlayKeys.action(keyCode: 19, typing: false) == .mode(.window))
        #expect(OverlayKeys.action(keyCode: 20, typing: false) == .mode(.area))
        #expect(OverlayKeys.action(keyCode: 18, typing: true) == .pass)
        #expect(OverlayKeys.action(keyCode: 18, typing: false, plain: false) == .pass)
        #expect(OverlayKeys.action(keyCode: 21, typing: false) == .pass)
    }

    @Test func horizontalBarStartsBottomCenterAndKeepsItsCenterWhenResized() {
        let s = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), visibleFrame: CGRect(x: 0, y: 70, width: 1600, height: 900))
        let size = CGSize(width: 560, height: 66)
        let o = ToolbarGeometry.origin(size: size, on: s, saved: nil)
        #expect(o.x == (1600 - 560) / 2 && o.y < 200)
        let f = CGRect(origin: o, size: size)
        let r = ToolbarGeometry.resized(f, to: CGSize(width: 300, height: 52))
        #expect(r.midX == f.midX && r.midY == f.midY)
        #expect(ToolbarGeometry.inLowerHalf(frame: f, of: s))
        #expect(!ToolbarGeometry.inLowerHalf(frame: f.offsetBy(dx: 0, dy: 800), of: s))
    }
}

@MainActor @Suite struct Round5BarRenderTests {
    private func render(_ phase: RecordingPhase?, name: String) throws -> CGSize {
        let layout = ToolbarLayoutModel()
        let view = ToolbarView(layout: layout)
            .environmentObject(RecordingController.shared)
            .environmentObject(AppSettings(store: UserDefaults(suiteName: "mov.yapcam.Yapcam.r5-\(UUID().uuidString)")!))
            .environmentObject(PermissionsModel.shared)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        if let dir = ProcessInfo.processInfo.environment["YAPCAM_SNAPSHOT_DIR"], let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: dir).appending(path: "\(name).png"))
        }
        return size
    }

    private func renderView<V: View>(_ v: V, name: String, width: CGFloat = 560, height: CGFloat = 430) {
        let settings = AppSettings(store: UserDefaults(suiteName: "mov.yapcam.Yapcam.r5-\(UUID().uuidString)")!)
        let host = NSHostingView(rootView: v.environmentObject(settings).frame(width: width, height: height))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        if let dir = ProcessInfo.processInfo.environment["YAPCAM_SNAPSHOT_DIR"], let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: dir).appending(path: "\(name).png"))
        }
    }

    @Test func settingsTabsRender() {
        renderView(GeneralSettings(), name: "set-general")
        renderView(RecordingSettings(), name: "set-recording")
        renderView(EditingSettings(), name: "set-editing")
        renderView(QuickExportSettings(), name: "set-quick")
        renderView(ShortcutSettings(), name: "set-shortcuts")
        renderView(AdvancedSettings(), name: "set-advanced")
    }

    @Test func cardsRender() {
        renderView(ZStack { Color.gray; SourceCard(symbol: "display", title: "Built-in Retina Display", subtitle: "3024×1964 • 120 FPS", start: {}) }, name: "card-display", width: 420, height: 220)
        renderView(ZStack { Color.gray; SourceCard(symbol: "macwindow", title: "Logic Pro", subtitle: "1277 × 861", start: {}, icon: NSImage(systemSymbolName: "music.note", accessibilityDescription: nil), sizeExtras: { AnyView(Button("Resize") {}.controlSize(.small)) }) }, name: "card-window", width: 420, height: 220)
    }

    @Test func idleBarIsAHorizontalStrip() throws {
        let size = try render(nil, name: "bar-idle")
        #expect(size.width > size.height * 4 && size.width < 900, "\(size)")
    }
}

@MainActor @Suite struct Round5SettingsTests {
    static func suite() -> UserDefaults { UserDefaults(suiteName: "mov.yapcam.Yapcam.r5-\(UUID().uuidString)")! }

    @Test func resetPutsEverythingBackButKeepsTheRecordingsFolder() {
        let suite = Self.suite()
        let s = AppSettings(store: suite)
        s.countdown = 5; s.createAutoZooms = false; s.afterRecording = .exportSave; s.systemAudio = true
        s.autosaveEnabled = false; s.savedAreaSizes = ["800x600"]; s.setCombo(KeyCombo(keyCode: 0, modifiers: 256), for: .marker)
        s.storageDirectory = URL(filePath: "/tmp/my-recordings", directoryHint: .isDirectory)
        s.hasCompletedOnboarding = true
        s.resetToDefaults()
        #expect(s.countdown == 0 && s.createAutoZooms && s.afterRecording == .createProject && !s.systemAudio && s.autosaveEnabled)
        #expect(s.savedAreaSizes.isEmpty && s.shortcuts.isEmpty)
        #expect(s.storageDirectory.path == "/tmp/my-recordings" && s.hasCompletedOnboarding)
        let again = AppSettings(store: suite)          // what was written to disk matches
        #expect(again.countdown == 0 && again.autosaveEnabled && again.storageDirectory.path == "/tmp/my-recordings")
    }

    @Test func quickExportSettingsPersistAndStayValid() {
        let suite = Self.suite()
        let s = AppSettings(store: suite)
        #expect(s.quickExport == ExportSettings() && s.quickExport.outputHeight == 720 && s.quickExport.fps == 60)
        s.quickExport.outputHeight = 720; s.quickExport.fps = 60; s.quickExport.compression = .web
        let back = AppSettings(store: suite).quickExport
        #expect(back.outputHeight == 720 && back.fps == 60 && back.compression == .web)
        var gif = AppSettings.defaultQuickExport; gif.format = .gif
        s.quickExport = gif.closestValidPreset(for: .file)
        let g = AppSettings(store: suite).quickExport
        #expect(g.format == .gif && !g.includeAudio && ExportSettings.heights(for: .gif).contains(g.outputHeight))
    }

    @Test func quickExportUsesTheStoredSettingsAndKeepsGifConstantRate() {
        var base = AppSettings.defaultQuickExport; base.outputHeight = 720
        let e = QuickExport.quickExportSettings(base: base, variableFrameRate: true)
        #expect(e.outputHeight == 720 && e.variableFrameRate)
        var gif = base; gif.format = .gif
        #expect(!QuickExport.quickExportSettings(base: gif, variableFrameRate: true).variableFrameRate)
    }

    @Test func editingShortcutsMatchTheEditor() {
        #expect(ShortcutSettings.editingKeys.map(\.1) == ["C", "X", "L", "J", "K"])
    }
}

@MainActor @Suite struct Round5ProjectTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "yapcam-r5-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func projectNamesAreCleaned() {
        #expect(ProjectActions.cleanProjectName("  My demo.yapcam ") == "My demo")
        #expect(ProjectActions.cleanProjectName("a/b:c*d?") == "abcd")
        #expect(ProjectActions.cleanProjectName("...") == nil)
        #expect(ProjectActions.cleanProjectName("   ") == nil)
        #expect(ProjectActions.cleanProjectName(".yapcam") == nil)
    }

    @Test func saveAsCopiesWithoutOverwriting() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = dir.appending(path: "Take.yapcam", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: pkg.appending(path: "project.json"))
        let a = try ProjectActions.saveCopy(of: pkg, named: "Demo", in: dir)
        let b = try ProjectActions.saveCopy(of: pkg, named: "Demo.yapcam", in: dir)
        #expect(a.lastPathComponent == "Demo.yapcam" && b.lastPathComponent == "Demo 2.yapcam")
        #expect(FileManager.default.fileExists(atPath: a.appending(path: "project.json").path))
        #expect(throws: (any Error).self) { try ProjectActions.saveCopy(of: pkg, named: "///", in: dir) }
    }

    @Test func zipForSharingMakesAZipOfThePackage() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = dir.appending(path: "Take.yapcam", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: pkg.appending(path: "project.json"))
        let zip = try ProjectActions.zipForSharing(pkg, into: dir)
        #expect(zip.lastPathComponent == "Take.yapcam.zip")
        #expect(((try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0)
    }

    @Test func macScanKeepsOnlyNewPackagesOutsideTheTrash() {
        let out = "/Users/a/Movies/Yapcam/One.yapcam\n/Users/a/Desktop/Two.yapcam\n/Users/a/.Trash/Old.yapcam\n/Users/a/notes.txt\n"
        let urls = RecentProjectsModel.parseScan(out, excluding: ["/Users/a/Movies/Yapcam/One.yapcam"])
        #expect(urls.map(\.path) == ["/Users/a/Desktop/Two.yapcam"])
    }
}

@Suite struct Round5DisplayTests {
    @Test func refreshRateFallsBackTo60() {
        #expect(DisplayInfo.rate(nil) == 60 && DisplayInfo.rate(0) == 60 && DisplayInfo.rate(119.88) == 120 && DisplayInfo.rate(59.94) == 60)
    }
    @Test func cardDetailReadsLikeTheReference() {
        let d = DisplayInfo(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        #expect(d.detail.hasPrefix("3024×1964 • ") && d.detail.hasSuffix(" FPS"))
    }
}

@MainActor @Suite struct Round5WidgetTests {
    @Test func summaryUsesRendersSummaryPlusAudio() {
        let d = AppSettings.defaultQuickExport
        #expect(QuickExport.summary(d) == d.summary(for: .file) + " • with audio")
        var e = d; e.includeAudio = false
        #expect(QuickExport.summary(e) == e.summary(for: .file) + " • no audio")
        var g = d; g.format = .gif; g.outputHeight = 480; g.fps = 15
        #expect(QuickExport.summary(g) == g.summary(for: .file))
    }
    @Test func hardwareEncodingToggleReachesQuickExport() {
        let s = AppSettings(store: UserDefaults(suiteName: "hw-\(UUID())")!)
        #expect(s.disableHardwareEncoding == false)
        #expect(QuickExport.quickExportSettings(variableFrameRate: false, hardwareEncoding: !s.disableHardwareEncoding).hardwareEncodingEnabled)
        s.disableHardwareEncoding = true
        #expect(!QuickExport.quickExportSettings(variableFrameRate: false, hardwareEncoding: !s.disableHardwareEncoding).hardwareEncodingEnabled)
        s.resetToDefaults()
        #expect(s.disableHardwareEncoding == false)
    }
    @Test func editorHookFollowsTheStoredToggle() {
        let suite = UserDefaults(suiteName: "hwe-\(UUID())")!
        let s = AppSettings(store: suite)
        #expect(AppSettings.hardwareEncodingEnabledInStore(suite))
        s.disableHardwareEncoding = true
        #expect(!AppSettings.hardwareEncodingEnabledInStore(suite))
        let saved = EditorWindows.hardwareEncodingEnabled
        defer { EditorWindows.hardwareEncodingEnabled = saved }
        EditorWindows.hardwareEncodingEnabled = { AppSettings.hardwareEncodingEnabledInStore(suite) }
        #expect(EditorWindows.hardwareEncodingEnabled() == false)
    }
    @Test func quickExportStoreIsSeparateFromTheEditorDialog() {
        let suite = UserDefaults(suiteName: "qx-\(UUID())")!
        let s = AppSettings(store: suite)
        var e = s.quickExport; e.fps = 30; s.quickExport = e
        #expect(AppSettings(store: suite).quickExport.fps == 30)
        #expect(suite.data(forKey: "quickExport.v1") != nil)
    }
    @Test func settingsCanOpenOnATab() {
        SettingsTabs.shared.selection = .quickExport
        #expect(SettingsTabs.shared.selection == .quickExport)
        SettingsTabs.shared.selection = .general
        #expect(SettingsTab.allCases.count == 7)
    }
}

@MainActor @Suite struct Round5CameraPreviewTests {
    @Test func previewShowsOnlyWhileTheIdleBarHasAUsableCamera() {
        func show(bar: Bool = true, phase: RecordingPhase = .idle, id: String? = "cam", available: Bool = true, granted: Bool = true, hidden: Bool = false) -> Bool {
            CameraPreviewPanel.shouldShow(barVisible: bar, phase: phase, cameraID: id, cameraAvailable: available, permissionGranted: granted, hidden: hidden)
        }
        #expect(show())
        #expect(!show(bar: false) && !show(phase: .recording) && !show(id: nil) && !show(available: false) && !show(granted: false) && !show(hidden: true))
    }
}

@Suite struct Round5WidgetPlacementTests {
    let visible = CGRect(x: 0, y: 0, width: 1600, height: 900)
    let bar = CGRect(x: 500, y: 40, width: 300, height: 50)
    @Test func staysWhenItDoesNotOverlap() {
        #expect(ToolbarGeometry.avoiding(bar, recorded: CGRect(x: 100, y: 300, width: 400, height: 300), in: visible) == bar)
    }
    @Test func movesBelowOrAboveAnOverlappingArea() {
        let area = CGRect(x: 400, y: 20, width: 600, height: 400)       // covers the bar, no room below
        let up = ToolbarGeometry.avoiding(bar, recorded: area, in: visible)
        #expect(up.minY >= area.maxY && !up.intersects(area))
        let high = CGRect(x: 400, y: 300, width: 600, height: 400)
        let bar2 = CGRect(x: 500, y: 500, width: 300, height: 50)
        let down = ToolbarGeometry.avoiding(bar2, recorded: high, in: visible)
        #expect(down.maxY <= high.minY && !down.intersects(high))
    }
    @Test func fullDisplayAreaLeavesItAlone() {
        #expect(ToolbarGeometry.avoiding(bar, recorded: visible, in: visible) == bar)
    }
}

@MainActor @Suite struct Round5PreviewTests {
    @Test func widgetFindsTheFirstSegmentMovie() throws {
        let pkg = FileManager.default.temporaryDirectory.appending(path: "yapcam-r5-\(UUID().uuidString).yapcam", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: pkg) }
        for seg in ["seg-002", "seg-001"] {
            let d = pkg.appending(path: "recording/\(seg)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: d.appending(path: "screen.mov"))
        }
        let m = QuickExportWidgetModel()
        m.package = pkg; m.loadThumbnail()
        #expect(m.movie?.deletingLastPathComponent().lastPathComponent == "seg-001")
        m.package = pkg.appending(path: "nothing"); m.loadThumbnail()
        #expect(m.movie == nil)
    }
}

@Suite struct Round5WindowFilterTests {
    private func row(_ id: UInt32, y: CGFloat = 0) -> WindowRow { WindowRow(id: id, pid: 1, layer: 0, app: "A", title: "", bounds: CGRect(x: 0, y: y, width: 400, height: 300)) }
    @Test func windowsCaptureDoesNotReportAreNotOffered() {
        let rows = [row(1), row(2)]
        #expect(WindowHit.pick(from: rows, at: CGPoint(x: 10, y: 10), excludingPID: 99, allowed: [2])?.id == 2)
        #expect(WindowHit.pick(from: rows, at: CGPoint(x: 10, y: 10), excludingPID: 99, allowed: nil)?.id == 1)
        #expect(WindowHit.pick(from: rows, at: CGPoint(x: 10, y: 10), excludingPID: 99, allowed: [])?.id == nil)
    }
}

@MainActor @Suite struct Round5EditorRequestTests {
    @Test func editorAppearanceDefaultsDarkPersistsAndReachesTheEditor() {
        let suite = UserDefaults(suiteName: "mov.yapcam.Yapcam.r5-\(UUID().uuidString)")!
        let old = EditorWindows.appearance
        defer { EditorWindows.appearance = old }
        let s = AppSettings(store: suite)
        #expect(s.editorAppearance == .dark)
        s.editorAppearance = .light
        #expect(EditorWindows.appearance == .light)
        #expect(AppSettings(store: suite).editorAppearance == .light)
    }

    @Test func fileMenuHasTheProjectItems() {
        _ = NSApplication.shared
        let menu = MainMenu.build(target: AppDelegate())
        let file = menu.items.first { $0.title == "File" }?.submenu?.items.map(\.title) ?? []
        for t in ["Rename Project…", "Move to Trash…", "Save As…", "Copy and Zip Project", "Show Project in Finder", "Recover Recording…"] { #expect(file.contains(t), "\(t)") }
    }

    @Test func projectItemsAreDisabledWithoutAnOpenEditor() {
        let d = AppDelegate()
        for sel in [#selector(AppDelegate.moveProjectToTrash), #selector(AppDelegate.renameProject), #selector(AppDelegate.saveProjectAs)] {
            #expect(!d.validateMenuItem(NSMenuItem(title: "x", action: sel, keyEquivalent: "")))
        }
    }
}

@MainActor @Suite struct Round5ExportUXTests {
    @Test func dockBadgeShowsPercent() {
        #expect(QuickExport.dockBadge(for: 0.426) == "42%" && QuickExport.dockBadge(for: 1.4) == "100%" && QuickExport.dockBadge(for: nil) == nil)
    }
    @Test func remainingTimeNeedsEnoughProgress() {
        #expect(QuickExport.remainingText(elapsed: 10, progress: 0.01) == nil)
        #expect(QuickExport.remainingText(elapsed: 10, progress: 0.5) == "about 10 s left")
        #expect(QuickExport.remainingText(elapsed: 120, progress: 0.25) == "about 6 min left")
        #expect(QuickExport.remainingText(elapsed: 5, progress: 1) == nil)
    }
    @Test func cancelFlagIsSticky() {
        let f = CancelFlag(); #expect(!f.isSet); f.set(); #expect(f.isSet)
    }
    @Test func afterExportActionDefaultsToNothingAndPersists() {
        let suite = UserDefaults(suiteName: "mov.yapcam.Yapcam.r5-\(UUID().uuidString)")!
        let s = AppSettings(store: suite)
        #expect(s.actionAfterQuickExport == .nothing)
        s.actionAfterQuickExport = .revealInFinder
        #expect(AppSettings(store: suite).actionAfterQuickExport == .revealInFinder)
    }
}

@Suite struct Round5TranscriptNoticeTests {
    @Test func partialTranscriptsGetANoticeCompleteOnesDoNot() {
        #expect(TranscriptionWiring.partialNotice(for: []) == nil)
        let json = #"{"code":"no_speech","message":"No speech in part of the audio","src_start_ns":0,"src_end_ns":1,"segment_index":0,"track":"mic"}"#
        let w = try! JSONDecoder().decode(TranscriptionWarning.self, from: Data(json.utf8))
        let one = TranscriptionWiring.partialNotice(for: [w])!
        #expect(one.contains("No speech in part of the audio") && !one.contains("more"))
        #expect(TranscriptionWiring.partialNotice(for: [w, w, w])!.contains("2 more"))
    }
}
