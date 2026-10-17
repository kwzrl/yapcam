import AppKit
import SwiftUI
import Testing
@testable import YapcamEditor

/// The docked bottom panel (ae-timeline): pixel-exact playhead, transcript paragraphs and word selection, hosting.
@MainActor @Suite struct TimelinePanelTests {
    @Test func playheadIsOnePhysicalPixelOnTheGrid() {
        #expect(PixelGrid.pixel(scale: 2) == 0.5)
        #expect(PixelGrid.pixel(scale: 1) == 1)
        #expect(PixelGrid.pixel(scale: 0) == 1 && PixelGrid.pixel(scale: .nan) == 1)
        // Retina: the line covers the device pixel that contains x, its left edge on a half-point.
        #expect(PixelGrid.lineEdge(100.0, scale: 2) == 100.0)
        #expect(PixelGrid.lineEdge(100.2, scale: 2) == 100.0)
        #expect(PixelGrid.lineEdge(100.49, scale: 2) == 100.0)
        #expect(PixelGrid.lineEdge(100.5, scale: 2) == 100.5)
        #expect(PixelGrid.lineEdge(100.99, scale: 2) == 100.5)
        // 1x: whole points.
        #expect(PixelGrid.lineEdge(37.7, scale: 1) == 37)
        // Floating error just below a pixel boundary still lands on that pixel (0.1 + 0.2 = 0.30000000000000004, 0.3 * 10 …).
        #expect(PixelGrid.lineEdge(0.15 * 10, scale: 2) == 1.5)
        #expect(PixelGrid.lineEdge(-0.2, scale: 2) == -0.5)
        #expect(PixelGrid.lineEdge(.infinity, scale: 2) == 0)
        // Any time on any zoom: edge is a multiple of the pixel and within one pixel left of x.
        for pps in [7.3, 60, 333.3, 2000] {
            let g = TimelineGeometry(pixelsPerSecond: pps)
            for ns in stride(from: Int64(0), through: 9_000_000_000, by: 123_456_789) {
                let x = g.x(forNs: ns), e = PixelGrid.lineEdge(x, scale: 2)
                #expect(e <= x + 1e-9 && x - e < 0.5 + 1e-9)
                #expect((e * 2).rounded() == e * 2)
            }
        }
    }

    private func words(_ spec: [(String, Double, Double)]) -> [TextItem] {
        spec.enumerated().map { i, w in
            TextItem.make(.caption, id: "w\(i)", start: Int64(w.1 * 1e9), end: Int64(w.2 * 1e9), text: w.0)
        }
    }

    @Test func transcriptParagraphsBreakAtLongPausesAndLongSentences() {
        let w = words([("Hello", 0, 0.4), ("there.", 0.5, 0.9), ("Next", 2.5, 2.8), ("one", 2.9, 3.1)])
        let p = TranscriptParagraphs.group(w)
        #expect(p.map { $0.map(\.text) } == [["Hello", "there."], ["Next", "one"]])
        // Sentence ends only break once a paragraph is long enough; the hard cap always does.
        let many = words((0..<30).map { i -> (String, Double, Double) in
            let t = Double(i) * 0.3
            return (i == 26 ? "end." : "w", t, t + 0.2)
        })
        #expect(TranscriptParagraphs.group(many).map(\.count) == [27, 3])
        let flood = words((0..<100).map { i -> (String, Double, Double) in
            let t = Double(i) * 0.3
            return ("w", t, t + 0.2)
        })
        #expect(TranscriptParagraphs.group(flood).map(\.count) == [80, 20])
        #expect(TranscriptParagraphs.group([]).isEmpty)
    }

    @Test func transcriptSelectionWorksLikeText() {
        let order = ["a", "b", "c", "d", "e"]
        var s = TranscriptSelection()
        s.click("b", in: order, extend: false, toggle: false)
        #expect(s.ids == ["b"])
        s.click("d", in: order, extend: true, toggle: false)
        #expect(s.ids == ["b", "c", "d"])
        s.click("a", in: order, extend: true, toggle: false)            // extends from the same anchor, the other way
        #expect(s.ids == ["a", "b"])
        s.click("e", in: order, extend: false, toggle: true)
        #expect(s.ids == ["a", "b", "e"])
        s.click("b", in: order, extend: false, toggle: true)
        #expect(s.ids == ["a", "e"])
        s.click("c", in: order, extend: false, toggle: false)
        #expect(s.ids == ["c"])
        var fresh = TranscriptSelection()
        fresh.click("c", in: order, extend: true, toggle: false)        // ⇧ without an anchor selects just that word
        #expect(fresh.ids == ["c"])
    }

    @Test func wordFlowWrapsLikeText() {
        let r = WordFlow.arrange(width: 100, sizes: Array(repeating: CGSize(width: 40, height: 18), count: 5), lineSpacing: 3)
        #expect(r.points == [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 0, y: 21), CGPoint(x: 40, y: 21), CGPoint(x: 0, y: 42)])
        #expect(r.height == 60)
        // A word wider than the line stays on its own line instead of looping.
        let wide = WordFlow.arrange(width: 30, sizes: [CGSize(width: 50, height: 10), CGSize(width: 50, height: 10)], lineSpacing: 0)
        #expect(wide.points.map(\.y) == [0, 10])
    }

    @Test func trackNamesFollowTheVisibleLanes() {
        #expect(TimelineLane.allCases.map(\.title) == ["Typing", "Camera", "Cursor", "Regions", "Text", "Captions", "Music"])
        #expect(TimelineView.namesWidth == 72)
    }

    @Test func panelHeightIsTheSameInBothModes() {
        let m = EditorModel(project: FakeProject(durationNs: 10_000_000_000), player: FakePlayer())
        let h = BottomPanelView.preferredHeight(model: m, windowHeight: 900)
        m.bottomPanel = .transcript
        #expect(BottomPanelView.preferredHeight(model: m, windowHeight: 900) == h)
        #expect(h >= TransportBar.height + 150 && h <= TransportBar.height + 1 + 900 * 0.30)
    }

    @Test func bottomPanelHostsTimelineAndTranscriptAndCutsSelectedWords() async throws {
        let m = EditorModel(project: FakeProject(durationNs: 10_000_000_000), player: FakePlayer())
        let host = NSHostingView(rootView: BottomPanelView(model: m).frame(width: 1100, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderBack(nil); defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(m.timelineFitted)
        m.bottomPanel = .transcript
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        _ = m.addText(.caption)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        #expect(m.transcriptWords.count == 1)
        m.bottomPanel = .timeline
        host.layoutSubtreeIfNeeded()
    }
}
