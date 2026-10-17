import CoreGraphics
import Foundation
import Testing
@testable import YapcamEditor

/// Round 7: lane visibility (CAM-22), click-to-add lanes (CAM-11, S-EDT-37), key 4 / Mask button (S-EDT-36), ⌥ cut tool (S-EDT-19),
/// disabled zoom and cursor badges (BS-7, BS-8).
@MainActor @Suite struct TimelineLaneTests {
    static let sec: Int64 = 1_000_000_000
    func model(camera: Bool = true) -> EditorModel {
        let p = FakeProject(durationNs: 20 * Self.sec); p.hasCamera = camera
        let iso = EditorStorage.makeIsolated()
        let m = EditorModel(project: p, player: FakePlayer()); m.defaults = iso.defaults
        return m
    }

    @Test func cameraLaneIsAlwaysThereWithACameraAndHidingKeepsTheData() {
        let m = model()
        #expect(m.visibleLanes == [.camera])                                              // empty, but present
        m.addLayout(fromNs: Self.sec)
        m.setLane(.camera, visible: false)
        #expect(!m.visibleLanes.contains(.camera) && m.layouts.count == 1)                // hidden lane keeps its data
        m.toggleLane(.camera); #expect(m.visibleLanes.contains(.camera))
        #expect(model(camera: false).visibleLanes.isEmpty)
        #expect(m.visibleLaneCount == 2)                                                  // zoom track + layouts
    }

    @Test func keysShowLanesAndKeyFourIsMasksWithoutAZoomSelected() {
        let m = model()
        #expect(!m.visibleLanes.contains(.highlight))
        #expect(m.handleShortcut("4")); #expect(m.visibleLanes.contains(.highlight) && m.highlights.isEmpty)   // lane appears empty
        #expect(m.handleShortcut("4")); #expect(!m.visibleLanes.contains(.highlight))
        #expect(!m.handleShortcut("9") && !m.handleShortcut("1"))
        m.addZoom(fromNs: Self.sec, toNs: 3 * Self.sec)                                   // a selected zoom keeps the digit for its level
        #expect(m.handleShortcut("4")); #expect(!m.visibleLanes.contains(.highlight))
    }

    @Test func visibilityIsRememberedPerUser() {
        let m = model(); m.setLane(.music, visible: true); m.setLane(.camera, visible: false)
        let again = EditorModel(project: FakeProject(durationNs: Self.sec), player: FakePlayer()); again.defaults = m.defaults
        again.loadLaneVisibility()
        #expect(again.laneVisibility.shown == ["music"] && again.laneVisibility.hidden == ["camera"])
    }

    @Test func maskButtonShowsTheLaneAndAddsAMaskAtThePlayhead() {
        let m = model(); m.seek(toNs: 5 * Self.sec)
        m.showMasksAndAddAtPlayhead()
        #expect(m.visibleLanes.contains(.highlight) && m.highlights.count == 1)
        #expect(m.highlights[0].startNs == 5 * Self.sec && m.highlights[0].endNs == 8 * Self.sec && m.selection == .highlight(m.highlights[0].id))
    }

    @Test func emptyLanesCreateOnClickAndDrag() {
        let l = TimelineLayout(lanes: [.camera, .highlight]), g = TimelineGeometry(pixelsPerSecond: 100)
        func input(_ x: Double, _ y: CGFloat, cut: Bool = false) -> TimelineClick.Input {
            .init(point: CGPoint(x: x, y: y), layout: l, geometry: g, cutTool: cut, multiSelect: false, durationNs: 20 * Self.sec, zooms: [],
                  rangeItems: [.init(key: "h", span: TimeSpan(startNs: 8 * Self.sec, endNs: 10 * Self.sec), top: l.highlightTop, tag: .highlight("h"))],
                  rangePreview: [:], typing: [], clips: [])
        }
        #expect(TimelineClick.decide(input(500, l.cameraTop + 5)) == .laneCreate(lane: .camera, atNs: 5 * Self.sec))
        #expect(TimelineClick.decide(input(500, l.highlightTop + 5)) == .laneCreate(lane: .highlight, atNs: 5 * Self.sec))
        #expect(TimelineClick.decide(input(900, l.highlightTop + 5)) == .rangeDrag(key: "h", part: .body(grabOffsetNs: Self.sec), select: .highlight("h")))
        #expect(TimelineClick.decide(input(500, l.cameraTop + 5, cut: true)) == .nothing)
        #expect(TimelineClick.decide(input(2500, l.cameraTop + 5)) == .scrub(selectClip: nil))      // beyond the recording
    }

    @Test func layoutCreationIsClampedToTheFreeGapNotRejected() {
        let m = model()
        m.addLayout(fromNs: 2 * Self.sec)                                                  // click: 3 s fullscreen layout
        #expect(m.layouts.count == 1 && m.layouts[0].startNs == 2 * Self.sec && m.layouts[0].endNs == 5 * Self.sec && m.layouts[0].mode == "camera")
        m.addLayout(fromNs: 6 * Self.sec, toNs: 12 * Self.sec)                             // drag
        m.addLayout(fromNs: 4 * Self.sec, toNs: nil)                                       // starts inside the first one: refused
        #expect(m.layouts.count == 2 && m.lastError != nil)
        m.lastError = nil
        m.addLayout(fromNs: 5 * Self.sec, toNs: 10 * Self.sec)                             // would overrun the layout at 6 s: ends at 6 s
        #expect(m.layouts.count == 3 && m.layouts.contains { $0.startNs == 5 * Self.sec && $0.endNs == 6 * Self.sec })
        #expect(EditorModel.freeSpan(from: 9 * Self.sec, to: 3 * Self.sec, defaultLength: 3 * Self.sec, durationNs: 20 * Self.sec,
                                     others: [(4 * Self.sec, 5 * Self.sec)], minNs: 100_000_000)! == (5 * Self.sec, 9 * Self.sec))     // leftwards drag stops at the neighbour
    }

    @Test func optionHeldAloneTurnsTheCutToolOnAndReleaseRestoresIt() {
        let m = model()
        m.optionHeld(true); #expect(m.cutToolActive)
        m.optionHeld(true); m.optionHeld(false); #expect(!m.cutToolActive)
        m.cutToolActive = true; m.optionHeld(true); m.optionHeld(false); #expect(m.cutToolActive)       // was on before: stays on
        #expect(EditorModel.isOptionAlone([.option]) && !EditorModel.isOptionAlone([.option, .command]) && !EditorModel.isOptionAlone([]))
    }

    @Test func disabledZoomsAndHiddenCursorsAreSaidInTheirChips() {
        var z = TimelineZoom(id: "z", startNs: 0, endNs: Self.sec, scale: 2, focusX: 0.5, focusY: 0.5)
        #expect(TimelineChipText.zoomTitle(z) == "2x · Manual")
        z.enabled = false
        #expect(TimelineChipText.zoomTitle(z) == "2x · Manual · Off" && TimelineChipText.zoomAccessibility(z, start: "0:00", end: "0:01").contains("disabled"))
        let m = model(); m.setClipCursor(hide: true)
        let c = m.clips[0]
        #expect(TimelineChipText.clipAccessibility(c, number: 1, start: "0:00", end: "0:20").contains("cursor hidden"))
        m.setClipCursor(smoothingOff: true)
        #expect(TimelineChipText.clipAccessibility(m.clips[0], number: 1, start: "a", end: "b").contains("smooth cursor movement off"))
    }
}
