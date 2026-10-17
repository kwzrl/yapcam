import AppKit
import SwiftUI
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
    @Test func presetGroupsKeepTheReferenceOrder() {
        #expect(WindowAX.sizeGroups.map(\.name) == ["16:9", "4:3", "9:16", "16:10", "Square"])
        #expect(WindowAX.sizeGroups[0].sizes.first == CGSize(width: 1280, height: 720))
        #expect(WindowAX.sizeGroups[0].sizes.last == CGSize(width: 2560, height: 1440))
    }

    @Test func onlySizesThatFitTheDisplayAreOffered() {
        let small = WindowAX.groups(fitting: CGSize(width: 1440, height: 900))
        #expect(small.flatMap(\.sizes).allSatisfy { $0.width <= 1440 && $0.height <= 900 })
        #expect(small.first { $0.name == "16:9" }?.sizes == [CGSize(width: 1280, height: 720)])
        #expect(!small.contains { $0.name == "9:16" && $0.sizes.contains(CGSize(width: 1440, height: 2560)) })
        #expect(WindowAX.groups(fitting: CGSize(width: 300, height: 300)).isEmpty)
    }

    @Test func everyPresetIsAValidWindowSize() {
        for g in WindowAX.sizeGroups { for s in g.sizes { #expect(WindowAX.parseSize(WindowAX.label(s)) == s) } }
    }

    @Test func ratioGroupsReallyHaveTheirRatio() {
        let want: [String: CGFloat] = ["16:9": 16.0 / 9, "4:3": 4.0 / 3, "9:16": 9.0 / 16, "16:10": 1.6, "Square": 1]
        for g in WindowAX.sizeGroups { for s in g.sizes { #expect(abs(s.width / s.height - want[g.name]!) < 0.01, "\(g.name) \(s)") } }
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
        #expect(s.quickExport.format == .mp4 && s.quickExport.outputHeight == 1080 && s.quickExport.fps == 30)
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
    @Test func summaryDescribesTheStoredSettings() {
        #expect(QuickExport.summary(AppSettings.defaultQuickExport) == "1080p MP4 · 30 fps · Social · with audio")
        var e = AppSettings.defaultQuickExport; e.outputHeight = 2160; e.fps = 60; e.compression = .studio; e.includeAudio = false
        #expect(QuickExport.summary(e) == "4K MP4 · 60 fps · Studio · no audio")
        var g = AppSettings.defaultQuickExport; g.format = .gif; g.outputHeight = 480; g.fps = 15
        #expect(QuickExport.summary(g) == "480p GIF · 15 fps")
    }
    @Test func settingsCanOpenOnATab() {
        SettingsTabs.shared.selection = .quickExport
        #expect(SettingsTabs.shared.selection == .quickExport)
        SettingsTabs.shared.selection = .general
        #expect(SettingsTab.allCases.count == 7)
    }
}
