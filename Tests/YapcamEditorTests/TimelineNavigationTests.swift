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
        try await Task.sleep(for: .milliseconds(100))
        let g = m.geometry
        #expect(g.pixelsPerSecond == 25)
        let scrolled = try #require(s.scrolledTo)
        #expect(abs((g.x(forNs: m.playheadNs) - scrolled) - 300) < 0.5)        // still at viewport x 300
    }
}
