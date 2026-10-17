import Foundation
import Testing
@testable import YapcamEditor

/// MKT-129 / MKT-201: pinch, ⌘-scroll and wheel navigation.
@MainActor @Suite struct TimelineNavigationTests {
    @Test func intentSeparatesZoomClassicWheelAndNativeTrackpad() {
        typealias N = TimelineNavigation
        if case .zoom(let f) = N.intent(deltaX: 0, deltaY: 5, precise: true, command: true) { #expect(f > 1) } else { Issue.record("⌘-scroll up must zoom in") }
        if case .zoom(let f) = N.intent(deltaX: 0, deltaY: -5, precise: false, command: true) { #expect(f < 1) } else { Issue.record("⌘-wheel down must zoom out") }
        #expect(N.intent(deltaX: 0, deltaY: -3, precise: false, command: false) == .scrollX(delta: 42))      // classic wheel: vertical → horizontal
        #expect(N.intent(deltaX: 0, deltaY: 3, precise: false, command: false) == .scrollX(delta: -42))
        #expect(N.intent(deltaX: 0, deltaY: -3, precise: true, command: false) == .passthrough)               // trackpad keeps native scrolling
        #expect(N.intent(deltaX: 4, deltaY: -3, precise: false, command: false) == .passthrough)              // a real horizontal axis is left alone
        #expect(N.intent(deltaX: 0, deltaY: 0, precise: false, command: true) == .passthrough)
        #expect(N.intent(deltaX: Double.nan, deltaY: 1, precise: false, command: true) == .passthrough)
        #expect(N.pinchFactor(magnification: 0.1) == 1.1 && N.pinchFactor(magnification: -5) == 0.5 && N.pinchFactor(magnification: Double.nan) == 1)
    }

    @Test func anchorTimeStaysUnderTheSameViewportX() {
        // 100 px/s → 200 px/s with the pointer at content x 700 while scrolled 300: 7 s must stay at viewport x 400.
        let x = TimelineNavigation.anchoredOffset(scrollX: 300, anchorX: 700, ratio: 2, newContentWidth: 5000, viewportWidth: 800)
        #expect(x == 1000 && (7.0 * 200 - x) == 400)
        #expect(TimelineNavigation.anchoredOffset(scrollX: 0, anchorX: 10, ratio: 0.5, newContentWidth: 300, viewportWidth: 800) == 0)   // fits: no scroll
        #expect(TimelineNavigation.anchoredOffset(scrollX: 0, anchorX: 700, ratio: 10, newContentWidth: 2000, viewportWidth: 800) == 1200) // clamped to the end
        #expect(TimelineNavigation.anchoredOffset(scrollX: 5, anchorX: Double.nan, ratio: 2, newContentWidth: 100, viewportWidth: 10) == 5)
    }

    final class FakeScroller: TimelineScroller {
        var offsetX = 0.0, viewportWidth = 800.0, scrolledTo: Double?
        func scroll(toX x: Double) { scrolledTo = x }
    }

    @Test func modelZoomKeepsThePlayheadWhereItIsOnScreen() async throws {
        let m = EditorModel(project: FakeProject(durationNs: 60_000_000_000), player: FakePlayer())
        m.timelineViewportWidth = 800
        m.geometry = TimelineGeometry(pixelsPerSecond: 20)
        let s = FakeScroller(); s.offsetX = 100; m.timelineScroller = s
        m.seek(toNs: 20_000_000_000)                                           // playhead at content x 400, viewport x 300
        m.zoomTimeline(by: 1.25)
        for _ in 0..<200 where s.scrolledTo == nil { try await Task.sleep(for: .milliseconds(25)) }     // two main-queue hops; slow when the machine is busy
        let g = m.geometry
        #expect(g.pixelsPerSecond == 25)
        let scrolled = try #require(s.scrolledTo)
        #expect(abs((g.x(forNs: m.playheadNs) - scrolled) - 300) < 0.5)        // still at viewport x 300
    }
}

/// S-EDT-24: scissors bubbles on the ruler.
@MainActor @Suite struct CutMarkerTests {
    static let sec: Int64 = 1_000_000_000
    @Test func labelsAndGrouping() {
        #expect(CutMarker.label(450_000_000) == "450 ms" && CutMarker.label(2 * Self.sec) == "2s" && CutMarker.label(1_500_000_000) == "1.5s")
        #expect(CutMarker.label(65 * Self.sec) == "1m 05s" && CutMarker.label(1) == "1 ms")
        let ms = CutMarker.markers(from: [(2 * Self.sec, 3 * Self.sec, 2 * Self.sec), (4 * Self.sec, 6 * Self.sec, 2 * Self.sec), (8 * Self.sec, 9 * Self.sec, 5 * Self.sec)])
        #expect(ms.map(\.atNs) == [2 * Self.sec, 5 * Self.sec] && ms[0].removedNs == 3 * Self.sec && ms[0].gaps.count == 2)
    }

    @Test func splitDeleteGivesAMarkerAndClickingItBringsTheMiddleBack() throws {
        let m = EditorModel(project: FakeProject(durationNs: 16 * Self.sec), player: FakePlayer())
        #expect(m.cutMarkers.isEmpty)
        m.perform(.deleteRange(startNs: 2 * Self.sec, endNs: 9 * Self.sec))                       // clips [0–2 s] and [9–16 s]
        let marker = try #require(m.cutMarkers.first)
        #expect(m.cutMarkers.count == 1 && marker.atNs == 2 * Self.sec && marker.removedNs == 7 * Self.sec)
        #expect(m.durationNs == 9 * Self.sec)
        m.restoreCut(atNs: marker.atNs)
        #expect(m.durationNs == 16 * Self.sec && m.cutMarkers.isEmpty)
        m.undo(); #expect(m.durationNs == 9 * Self.sec && m.cutMarkers.count == 1)                   // one undo step
        m.perform(.deleteRange(startNs: 0, endNs: Self.sec))                                         // a head trim shows at 0
        #expect(m.cutMarkers.first?.atNs == 0)
    }

    @Test func rulerClickOnABubbleRestoresAndElsewhereScrubs() {
        let l = TimelineLayout(lanes: []), g = TimelineGeometry(pixelsPerSecond: 100)
        func input(_ x: Double, _ y: CGFloat) -> TimelineClick.Input {
            .init(point: CGPoint(x: x, y: y), layout: l, geometry: g, cutTool: false, multiSelect: false, durationNs: 9 * Self.sec, zooms: [],
                  rangeItems: [], rangePreview: [:], typing: [], clips: [], cutMarkers: [(2 * Self.sec, "7s")])
        }
        #expect(TimelineClick.decide(input(200, CutMarker.top + 4)) == .restoreCut(atNs: 2 * Self.sec))
        #expect(TimelineClick.decide(input(206, CutMarker.top + 4)) == .restoreCut(atNs: 2 * Self.sec))
        #expect(TimelineClick.decide(input(400, CutMarker.top + 4)) == .scrub(selectClip: nil))
        #expect(TimelineClick.decide(input(200, 2)) == .scrub(selectClip: nil))                      // above the bubble: ruler scrub
    }
}
