import AppKit
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
