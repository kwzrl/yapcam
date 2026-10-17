import AppKit
import Foundation
import Testing
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
}
