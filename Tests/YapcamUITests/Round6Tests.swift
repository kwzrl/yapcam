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

    // MARK: R6-QA-U1 area mouse-down and recorder keys

    @Test func areaMouseDownPrefersHandlesThenBodyThenCreate() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        #expect(AreaMouseDown.decide(at: CGPoint(x: 50, y: 50), rect: nil) == .create)
        #expect(AreaMouseDown.decide(at: CGPoint(x: 100, y: 100), rect: r) == .resize(.tl))
        #expect(AreaMouseDown.decide(at: CGPoint(x: 105, y: 104), rect: r) == .resize(.tl))     // inside the handle radius
        #expect(AreaMouseDown.decide(at: CGPoint(x: 300, y: 150), rect: r) == .resize(.r))
        #expect(AreaMouseDown.decide(at: CGPoint(x: 200, y: 200), rect: r) == .resize(.b))
        #expect(AreaMouseDown.decide(at: CGPoint(x: 200, y: 150), rect: r) == .move)
        #expect(AreaMouseDown.decide(at: CGPoint(x: 400, y: 400), rect: r) == .create)
        #expect(AreaMouseDown.decide(at: CGPoint(x: 100 - 12, y: 100), rect: r) == .create)    // just outside the radius
        // A tiny rect: the handle wins over the body everywhere near it.
        #expect(AreaMouseDown.decide(at: CGPoint(x: 5, y: 5), rect: CGRect(x: 0, y: 0, width: 10, height: 10)) == .resize(.tl))
    }

    @Test func recorderKeysCancelAcceptOrReject() {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey))
        #expect(RecorderKey.decide(keyCode: 53, combo: combo) == .cancel)          // Esc wins even with a combo
        #expect(RecorderKey.decide(keyCode: 53, combo: nil) == .cancel)
        #expect(RecorderKey.decide(keyCode: 35, combo: combo) == .accept(combo))
        #expect(RecorderKey.decide(keyCode: 35, combo: nil) == .reject)
        #expect(RecorderKey.decideEditing(keyCode: 53, chars: nil, modifiers: []) == .cancel)
        #expect(RecorderKey.decideEditing(keyCode: 5, chars: "g", modifiers: []) == .accept("g"))
        #expect(RecorderKey.decideEditing(keyCode: 5, chars: "g", modifiers: .command) == .reject)
        #expect(RecorderKey.decideEditing(keyCode: 5, chars: nil, modifiers: []) == .reject)
    }

    // MARK: R6-QA-U1 menu action targets

    private let row = WindowRow(id: 9, pid: 1, layer: 0, app: "App", title: "T", bounds: CGRect(x: 10, y: 10, width: 1280.4, height: 720))

    @Test func saveCurrentSizeKeepsNewestFirstAndAtMostEight() {
        let s = settings(); let m = SourceOverlayModel(kind: .window)
        m.saveSize(of: row, in: s)
        #expect(s.savedWindowSizes == ["1280x720"])
        for i in 0..<10 { var r = row; r.bounds.size.width = CGFloat(400 + i); m.saveSize(of: r, in: s) }
        m.saveSize(of: row, in: s)
        #expect(s.savedWindowSizes.count == 8 && s.savedWindowSizes.first == "1280x720")
    }
    @Test func customSizeRejectsBadTextWithAnExplanation() {
        let m = SourceOverlayModel(kind: .window)
        m.applyTypedSize("12", to: row)
        #expect(m.notice == "Enter two numbers between 150 and 8192, like 1280x720.")
        m.notice = nil
        m.applyTypedSize("99999x10", to: row)
        #expect(m.notice != nil)
    }
    @Test func ignoreThisWindowHidesItFromPointing() {
        let m = SourceOverlayModel(kind: .window)
        m.hover = row
        m.ignore(row)
        #expect(m.ignored == [9] && m.hover == nil)
    }
    @Test func adjustRecordingAreaHandsOverTheLocalRectOnTheWindowsScreen() throws {
        let screen = try #require(NSScreen.screens.first)
        let m = SourceOverlayModel(kind: .window)
        var got: (CGRect, UInt32)?
        m.onAdjustAsArea = { got = ($0, $1) }
        m.adjustAsArea(row, screenFrame: screen.frame, primaryMaxY: screen.frame.maxY)
        #expect(got?.1 == screen.displayID)
        #expect(got?.0.width == row.bounds.width)
    }
    @Test func showInFinderGoesThroughTheSharedReveal() {
        let saved = FinderReveal.perform; defer { FinderReveal.perform = saved }
        var shown: [URL] = []
        FinderReveal.perform = { shown += $0 }
        let u = URL(fileURLWithPath: "/tmp/fixture/Take.yapcam")
        FinderReveal.show(u)
        #expect(shown == [u])
    }
    @Test func exportDiagnosticsWritesTheReport() throws {
        let dest = FileManager.default.temporaryDirectory.appending(path: "diag-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: dest) }
        ProjectActions.writeDiagnostics(to: dest)
        let text = try String(contentsOf: dest, encoding: .utf8)
        #expect(text.hasPrefix("Yapcam diagnostics") && text.contains("Permissions") && text.contains("Displays"))
    }
}
