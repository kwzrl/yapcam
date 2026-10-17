import AppKit
import Combine
import Carbon.HIToolbox
import Foundation
import Testing
@testable import YapcamUI

@MainActor @Suite struct Round6StartDecisionTests {
    private func settings() -> AppSettings { AppSettings(store: UserDefaults(suiteName: "r6-\(UUID())")!) }

    @Test func displayStartSetsBothSettings() {
        let s = settings()
        SourceChoice.display(7).apply(to: s)
        #expect(s.displayID == 7 && s.sourceMode == .display)
    }
    @Test func windowStartSetsBothSettings() {
        let s = settings()
        SourceChoice.window(42).apply(to: s)
        #expect(s.windowID == 42 && s.sourceMode == .window)
    }
    @Test func areaConfirmRefusesTinyAreasAndRoundsOthers() {
        #expect(SourceChoice.confirmedArea(display: 1, rect: nil) == nil)
        #expect(SourceChoice.confirmedArea(display: 1, rect: CGRect(x: 0, y: 0, width: 4, height: 400)) == nil)
        let c = SourceChoice.confirmedArea(display: 3, rect: CGRect(x: 10.4, y: 10.4, width: 640.2, height: 360.2))
        let s = settings()
        c?.apply(to: s)
        #expect(s.areaDisplayID == 3 && s.sourceMode == .area && s.areaRect?.width ?? 0 >= 640)
    }

    /// The 0.10.0 crash: Start changed two @Published settings back to back while an `objectWillChange.values` loop slept.
    /// The app now observes with a debounced sink; this runs the same observer shape through many rapid starts.
    @Test func backToBackSettingChangesWithAnObserverDoNotTrap() async throws {
        let s = settings()
        var fired = 0
        let bag = s.objectWillChange.debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { _ in MainActor.assumeIsolated { fired += 1 } }
        for i in 1...50 {
            SourceChoice.display(UInt32(i)).apply(to: s)
            SourceChoice.window(UInt32(i)).apply(to: s)
            SourceChoice.confirmedArea(display: UInt32(i), rect: CGRect(x: 0, y: 0, width: 300, height: 200))?.apply(to: s)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(fired >= 1 && fired < 10)          // coalesced, not one per change
        #expect(s.displayID == 50 && s.windowID == 50 && s.sourceMode == .area)
        bag.cancel()
    }

    @Test func nonFiniteDurationsDoNotTrap() {
        _ = Announcer.timeDescription(.nan)
        _ = Announcer.timeDescription(.infinity)
        _ = Announcer.timeDescription(-5)
        #expect(QuickExport.remainingText(elapsed: .infinity, progress: 0.5) == nil)
        #expect(QuickExport.remainingText(elapsed: 10, progress: .nan) == nil)
    }
    @Test func editorVariableFrameRateReadsTheStoreOffMain() async {
        let suite = UserDefaults(suiteName: "r6vfr-\(UUID())")!
        suite.set(true, forKey: "experimentalVariableFrameRate")
        let v = await Task.detached { AppSettings.variableFrameRateInStore(suite) }.value
        #expect(v)
    }
    @Test func speakerNotesDefaultShortcutIsCmdOptSlash() {
        let c = HotkeyAction.toggleNotes.defaultCombo
        #expect(c?.keyCode == UInt32(kVK_ANSI_Slash) && c?.modifiers == UInt32(cmdKey | optionKey))
    }
}
