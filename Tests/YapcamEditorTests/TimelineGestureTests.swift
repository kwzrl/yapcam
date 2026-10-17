import CoreGraphics
import Foundation
import Testing
@testable import YapcamEditor

/// Round 6: every lane × tool combination of a pointer-down on the timeline, decided by the pure `TimelineClick.decide`.
@MainActor @Suite struct TimelineGestureTests {
    static let layout = TimelineLayout(lanes: [.camera, .cursor, .highlight, .text, .music])
    static let g = TimelineGeometry(pixelsPerSecond: 100)            // 1 s = 100 px, no scroll
    static let sec: Int64 = 1_000_000_000

    func input(x: Double, y: CGFloat, cut: Bool = false, multi: Bool = false) -> TimelineClick.Input {
        let l = Self.layout
        func item(_ key: String, _ top: CGFloat, _ tag: EditorSelection) -> LaneHitTest.Item {
            .init(key: key, span: TimeSpan(startNs: 2 * Self.sec, endNs: 6 * Self.sec), top: top, tag: tag)
        }
        return .init(point: CGPoint(x: x, y: y), layout: l, geometry: Self.g, cutTool: cut, multiSelect: multi, durationNs: 20 * Self.sec,
                     zooms: [("z1", 8 * Self.sec, 12 * Self.sec)],
                     rangeItems: [item("l1", l.cameraTop, .layout("l1")), item("c1", l.cursorTop, .cursorHide(0)),
                                  item("h1", l.highlightTop, .highlight("h1")), item("t1", l.textTop, .text(.annotation, "t1")),
                                  item("m1", l.musicTop, .music("m1"))],
                     rangePreview: [:], typing: [(14 * Self.sec, 16 * Self.sec)],
                     clips: [("c", 0, 10 * Self.sec), ("d", 10 * Self.sec, 20 * Self.sec)])
    }
    var l: TimelineLayout { Self.layout }
    func mid(_ top: CGFloat) -> CGFloat { top + TimelineLayout.laneHeight / 2 }

    @Test func scissorsSplitSplittableItemsAndOnlySelectTheOthers() {
        let x = 400.0                                                    // 4 s: inside every range item
        for (top, sel) in [(l.cameraTop, EditorSelection.layout("l1")), (l.highlightTop, .highlight("h1"))] {
            #expect(TimelineClick.decide(input(x: x, y: mid(top), cut: true)) == .rangeCut(select: sel, atNs: 4 * Self.sec))
        }
        for (top, sel) in [(l.cursorTop, EditorSelection.cursorHide(0)), (l.textTop, .text(.annotation, "t1")), (l.musicTop, .music("m1"))] {
            #expect(TimelineClick.decide(input(x: x, y: mid(top), cut: true)) == .rangeSelectOnly(sel))   // never a drag while scissors are on
        }
    }

    @Test func scissorsOnAZoomSplitThatZoomEvenWhenNothingIsSelected() {
        #expect(TimelineClick.decide(input(x: 1000, y: l.zoomTop + 10, cut: true)) == .zoomCut(id: "z1", atNs: 10 * Self.sec))
        #expect(TimelineClick.decide(input(x: 300, y: l.zoomTop + 10, cut: true)) == .nothing)             // empty zoom lane: no accidental new zoom
    }

    @Test func scissorsOnAClipCutAtTheClickAndOnEmptySpaceDoNothing() {
        #expect(TimelineClick.decide(input(x: 1500, y: l.clipTop + 10, cut: true)) == .clipCut(atNs: 15 * Self.sec))
        #expect(TimelineClick.decide(input(x: 3000, y: l.clipTop + 10, cut: true)) == .scrub(selectClip: nil))   // past the end
        #expect(TimelineClick.decide(input(x: 900, y: mid(l.musicTop), cut: true)) == .nothing)                   // empty overlay lane
    }

    @Test func withoutTheToolItemsDragAndZoomsMultiSelect() {
        #expect(TimelineClick.decide(input(x: 400, y: mid(l.highlightTop))) == .rangeDrag(key: "h1", part: .body(grabOffsetNs: 2 * Self.sec), select: .highlight("h1")))
        #expect(TimelineClick.decide(input(x: 201, y: mid(l.musicTop))) == .rangeDrag(key: "m1", part: .start, select: .music("m1")))
        #expect(TimelineClick.decide(input(x: 599, y: mid(l.textTop))) == .rangeDrag(key: "t1", part: .end, select: .text(.annotation, "t1")))
        #expect(TimelineClick.decide(input(x: 1000, y: l.zoomTop + 10)) == .zoomDrag(id: "z1", part: .move(grabOffsetNs: 2 * Self.sec)))
        #expect(TimelineClick.decide(input(x: 801, y: l.zoomTop + 10)) == .zoomDrag(id: "z1", part: .start))
        #expect(TimelineClick.decide(input(x: 1199, y: l.zoomTop + 10)) == .zoomDrag(id: "z1", part: .end))
        #expect(TimelineClick.decide(input(x: 1000, y: l.zoomTop + 10, multi: true)) == .zoomToggleSelect(id: "z1"))   // ⇧ / ⌘
        #expect(TimelineClick.decide(input(x: 300, y: l.zoomTop + 10)) == .zoomCreate(atNs: 3 * Self.sec))
        #expect(TimelineClick.decide(input(x: 2500, y: l.zoomTop + 10)) == .scrub(selectClip: nil))               // beyond the recording
    }

    @Test func clipsRulerTypingAndEmptyLanes() {
        #expect(TimelineClick.decide(input(x: 500, y: 5)) == .scrub(selectClip: nil))                              // ruler
        #expect(TimelineClick.decide(input(x: 500, y: l.clipTop + 10)) == .scrub(selectClip: "c"))
        #expect(TimelineClick.decide(input(x: 1500, y: l.clipTop + 10)) == .scrub(selectClip: "d"))
        #expect(TimelineClick.decide(input(x: 900, y: mid(l.musicTop))) == .scrub(selectClip: nil))
        let typingLayout = TimelineLayout(lanes: [.typing])
        var i = input(x: 1500, y: typingLayout.typingTop + 5); i.layout = typingLayout
        #expect(TimelineClick.decide(i) == .typingPopover(startNs: 14 * Self.sec))
        #expect(TimelineClick.decide(input(x: Double.nan, y: 100)) == .nothing)                                          // broken pointer event
    }

    @Test func nonFinitePointerPositionsNeverTrap() {
        let g = Self.g
        #expect(g.ns(forX: Double.nan) == 0 && g.ns(forX: Double.infinity) == 0)
        #expect(g.ns(forX: 1e300) == 9_000_000_000_000_000_000 && g.ns(forX: -1e300) == -9_000_000_000_000_000_000)
    }
}

@MainActor @Suite struct InputGatedControlTests {
    @Test func mouseAndMicCommandsAreDisabledWithoutTheirInput() {
        let p = FakeProject(durationNs: 20_000_000_000); p.hasMouseData = false; p.hasMic = false
        let m = EditorModel(project: p, player: FakePlayer())
        let enabled = Dictionary(uniqueKeysWithValues: m.paletteCommands.map { ($0.title, $0.enabled) })
        #expect(enabled["Regenerate automatic zooms"] == false && enabled["Hide cursor from playhead"] == false && enabled["Generate captions from speech"] == false)
        p.hasMouseData = true; p.hasMic = true
        let on = Dictionary(uniqueKeysWithValues: EditorModel(project: p, player: FakePlayer()).paletteCommands.map { ($0.title, $0.enabled) })
        #expect(on["Regenerate automatic zooms"] == true && on["Hide cursor from playhead"] == true && on["Generate captions from speech"] == true)
    }

    @Test func gradientPresetOutOfRangeIsIgnored() {
        let m = EditorModel(project: FakeProject(durationNs: 1_000_000_000), player: FakePlayer())
        m.applyGradientPreset(-1); m.applyGradientPreset(10_000)         // used to trap on the array index
    }

    @Test func mainHopRunsInlineOnMainAndHopsFromOtherThreads() async {
        final class Box: @unchecked Sendable { var n = 0 }
        let ran = Box()
        onMain { ran.n += 1 }; #expect(ran.n == 1)
        await withCheckedContinuation { c in
            DispatchQueue.global().async { onMain { ran.n += 1; c.resume() } }      // MainActor.assumeIsolated here would trap
        }
        #expect(ran.n == 2)
    }
}

@Suite struct PointerMathTests {
    let size = CGSize(width: 200, height: 100)
    @Test func previewAndPadMappingClampsDragsOutsideTheView() {
        #expect(PointerMath.unit(CGPoint(x: 100, y: 25), in: size) == CGPoint(x: 0.5, y: 0.25))
        #expect(PointerMath.unit(CGPoint(x: -50, y: 400), in: size) == CGPoint(x: 0, y: 1))          // dragged out of the view
        #expect(PointerMath.pad(CGPoint(x: 0, y: 0), in: size) == CGPoint(x: -1, y: -1))
        #expect(PointerMath.pad(CGPoint(x: 100, y: 50), in: size) == CGPoint(x: 0, y: 0))
        #expect(PointerMath.pad(CGPoint(x: 900, y: -900), in: size) == CGPoint(x: 1, y: -1))
    }
    @Test func zeroSizeAndNonFiniteInputProduceNoValue() {
        for s in [CGSize.zero, CGSize(width: 0, height: 100), CGSize(width: 100, height: -1), CGSize(width: Double.nan, height: 5)] {
            #expect(PointerMath.unit(CGPoint(x: 5, y: 5), in: s) == nil && PointerMath.pad(CGPoint(x: 5, y: 5), in: s) == nil)
            #expect(PointerMath.delta(from: .zero, to: CGPoint(x: 5, y: 5), in: s) == .zero)
        }
        #expect(PointerMath.unit(CGPoint(x: Double.nan, y: 1), in: size) == nil && PointerMath.pad(CGPoint(x: 1, y: Double.infinity), in: size) == nil)
        #expect(PointerMath.delta(from: .zero, to: CGPoint(x: 50, y: -25), in: size) == CGSize(width: 0.25, height: -0.25))
    }
    @Test func rectHitPrefersTheNearestCornerThenBodyThenNothing() {
        let f = CGRect(x: 20, y: 20, width: 100, height: 60)
        #expect(PointerMath.rectHit(at: CGPoint(x: 22, y: 24), frame: f) == .corner(0))
        #expect(PointerMath.rectHit(at: CGPoint(x: 118, y: 78), frame: f) == .corner(3))
        #expect(PointerMath.rectHit(at: CGPoint(x: 10, y: 82), frame: f) == .corner(2))               // just outside, within the grab radius
        #expect(PointerMath.rectHit(at: CGPoint(x: 70, y: 50), frame: f) == .move)
        #expect(PointerMath.rectHit(at: CGPoint(x: 200, y: 200), frame: f) == nil)
        let tiny = CGRect(x: 50, y: 50, width: 10, height: 10)                                          // corners overlap: nearest wins
        #expect(PointerMath.rectHit(at: CGPoint(x: 59, y: 59), frame: tiny) == .corner(3))
        #expect(PointerMath.rectHit(at: CGPoint(x: Double.nan, y: 0), frame: f) == nil)
        #expect(PointerMath.rectHit(at: CGPoint(x: 1, y: 1), frame: CGRect(x: 1, y: 1, width: 0, height: 0)) == .corner(0))   // zero-size box is still grabbable
    }
}
