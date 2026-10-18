import CoreGraphics
import Foundation
import Testing
@testable import YapcamEditor

/// Round 7 (S-EDT-21/22, BS-6, CAM-54/55): what a secondary click hits, which entries it gives and what they do.
@MainActor @Suite struct TimelineMenuTests {
    static let sec: Int64 = 1_000_000_000
    func model(mic: Bool = true, mouse: Bool = true) -> (EditorModel, FakeProject) {
        let p = FakeProject(durationNs: 20 * Self.sec); p.hasMic = mic; p.hasMouseData = mouse
        return (EditorModel(project: p, player: FakePlayer()), p)
    }
    func titles(_ e: [TimelineMenu.Entry]) -> [String] { e.filter { !$0.isSeparator }.map(\.title) }
    func find(_ e: [TimelineMenu.Entry], _ title: String) -> TimelineMenu.Entry? { e.first { $0.title == title } }

    @Test func menuTargetFindsClipsZoomsLanesAndEmptySpace() {
        let l = TimelineLayout(lanes: [.camera, .music]), g = TimelineGeometry(pixelsPerSecond: 100)
        func input(_ x: Double, _ y: CGFloat) -> TimelineClick.Input {
            .init(point: CGPoint(x: x, y: y), layout: l, geometry: g, cutTool: false, multiSelect: false, durationNs: 20 * Self.sec,
                  zooms: [("z", 8 * Self.sec, 12 * Self.sec)],
                  rangeItems: [.init(key: "l", span: TimeSpan(startNs: 2 * Self.sec, endNs: 6 * Self.sec), top: l.cameraTop, tag: .layout("l")),
                               .init(key: "m", span: TimeSpan(startNs: 2 * Self.sec, endNs: 6 * Self.sec), top: l.musicTop, tag: .music("m"))],
                  rangePreview: [:], typing: [], clips: [("a", 0, 10 * Self.sec), ("b", 10 * Self.sec, 20 * Self.sec)])
        }
        #expect(TimelineClick.menuTarget(input(1500, l.clipTop + 5)) == .clip(id: "b", atNs: 15 * Self.sec))     // over clip 2: its id and the click time
        #expect(TimelineClick.menuTarget(input(1000, l.zoomTop + 5)) == .zoom(id: "z"))
        #expect(TimelineClick.menuTarget(input(300, l.zoomTop + 5)) == .empty(atNs: 3 * Self.sec))
        #expect(TimelineClick.menuTarget(input(400, l.cameraTop + 5)) == .layout(id: "l"))
        #expect(TimelineClick.menuTarget(input(400, l.musicTop + 5)) == .music(id: "m"))
        #expect(TimelineClick.menuTarget(input(900, l.musicTop + 5)) == .empty(atNs: 9 * Self.sec))
        #expect(TimelineClick.menuTarget(input(400, 5)) == nil)                                                    // ruler: no menu
        #expect(TimelineClick.menuTarget(input(Double.nan, 100)) == nil)
    }

    @Test func clipMenuHasTheSpecifiedEntriesAndChecks() throws {
        let (m, _) = model(); let id = m.clips[0].id
        let e = TimelineMenu.entries(for: .clip(id: id, atNs: 5 * Self.sec), in: m)
        #expect(titles(e) == ["Set Speed", "Set Volume", "Microphone Volume", "System Audio Volume", "Remove", "Merge with Next Clip", "Merge with Previous Clip", "Split Here", "Copy Settings", "Reset Trim",
                              "Reset All Trims and Cuts", "Hide Cursor", "Disable Smooth Cursor Movement"])
        let speeds = try #require(find(e, "Set Speed")).children
        #expect(speeds.first { $0.checked }?.title == "1× (normal)")
        let vol = try #require(find(e, "Set Volume")).children
        #expect(vol.first { $0.checked }?.title == "100 %" && vol.contains { $0.title == "Muted" })
        #expect(find(e, "Remove")?.enabled == false)                                  // the only clip can't be removed
        #expect(find(e, "Reset Trim")?.enabled == false && find(e, "Reset All Trims and Cuts")?.enabled == false)
        let (m2, _) = model(mic: false, mouse: false)
        let e2 = TimelineMenu.entries(for: .clip(id: m2.clips[0].id, atNs: 5 * Self.sec), in: m2)
        #expect(!titles(e2).contains("Microphone Volume") && !titles(e2).contains("Hide Cursor"))      // only with the input
    }

    @Test func splitHereCutsAtTheClickAndStaysOneUndoStep() throws {
        let (m, _) = model(); let id = m.clips[0].id
        m.seek(toNs: Self.sec)                                                       // playhead elsewhere: the click time wins
        m.apply(try #require(find(TimelineMenu.entries(for: .clip(id: id, atNs: 7 * Self.sec), in: m), "Split Here")?.action))
        #expect(m.clipStarts().map(\.startNs) == [0, 7 * Self.sec])
        m.undo(); #expect(m.clips.count == 1)
        #expect(find(TimelineMenu.entries(for: .clip(id: id, atNs: 20 * Self.sec - 1), in: m), "Split Here")?.enabled == false)   // too close to the end
        #expect(find(TimelineMenu.entries(for: .clip(id: id, atNs: 0), in: m), "Split Here")?.enabled == false)
    }

    @Test func volumeBothScalesMicAndSystemInOneStepAndShowsTheCheck() throws {
        let (m, _) = model(); let id = m.clips[0].id
        m.apply(.clipVolume(id: id, percent: 50, .both))
        #expect(m.clips[0].micGain == 0.5 && m.clips[0].systemGain == 0.5)
        let vol = try #require(find(TimelineMenu.entries(for: .clip(id: id, atNs: Self.sec), in: m), "Set Volume")).children
        #expect(vol.first { $0.checked }?.title == "50 %")
        m.undo(); #expect(m.clips[0].micGain == 1 && m.clips[0].systemGain == 1)                  // one undo restores both
        m.apply(.clipVolume(id: id, percent: 20, .system))
        let both = try #require(find(TimelineMenu.entries(for: .clip(id: id, atNs: Self.sec), in: m), "Set Volume")).children
        #expect(!both.contains { $0.checked })                                                    // mic and system differ: no check
        let (nm, _) = model(mic: false); nm.apply(.clipVolume(id: nm.clips[0].id, percent: 0, .both))
        #expect(nm.clips[0].micGain == 1 && nm.clips[0].systemGain == 0)                          // no microphone: only system audio
    }

    @Test func clipActionsSpeedRemoveAndCursorFlags() throws {
        let (m, _) = model(); m.apply(.clipSpeed(id: m.clips[0].id, 2)); #expect(m.clips[0].speed == 2)
        m.undo(); #expect(m.clips[0].speed == 1)
        m.apply(.clipHideCursor(id: m.clips[0].id, true)); m.apply(.clipSmoothingOff(id: m.clips[0].id, true))
        #expect(m.clips[0].hideCursor && m.clips[0].disableSmoothing)
        m.splitAtPlayhead(); m.seek(toNs: 5 * Self.sec); m.splitAtPlayhead()
        let before = m.clips.count; let first = m.clips[0].id
        m.apply(.removeClip(id: first)); #expect(m.clips.count == before - 1)
        m.apply(.speedToAll(4)); #expect(m.clips.allSatisfy { $0.speed == 4 })
    }

    @Test func zoomMenuActionsAreSingleUndoSteps() throws {
        let (m, _) = model()
        m.addZoom(fromNs: Self.sec, toNs: 3 * Self.sec); m.addZoom(fromNs: 5 * Self.sec, toNs: 7 * Self.sec); m.addZoom(fromNs: 9 * Self.sec, toNs: 11 * Self.sec)
        let id = m.zooms[0].id
        var e = TimelineMenu.entries(for: .zoom(id: id), in: m)
        #expect(titles(e) == ["Remove", "Duplicate", "Disable", "Copy Settings", "Set Zoom Level", "Disable All", "Enable All", "Restore Automatic Zooms", "Remove All Zooms"])
        #expect(find(e, "Enable All")?.enabled == false)                                            // nothing disabled yet
        m.apply(.allZoomsEnabled(false)); #expect(m.zooms.allSatisfy { !$0.enabled })
        m.undo(); #expect(m.zooms.allSatisfy { $0.enabled })
        m.apply(.zoomEnabled(id: id, false))
        e = TimelineMenu.entries(for: .zoom(id: id), in: m)
        #expect(find(e, "Disable")?.checked == true && find(e, "Disable")?.action == .zoomEnabled(id: id, true))   // second click re-enables
        m.apply(.zoomLevel(id: id, 3)); #expect(m.zooms.first { $0.id == id }?.scale == 3)
        let lv = try #require(find(TimelineMenu.entries(for: .zoom(id: id), in: m), "Set Zoom Level")).children
        #expect(lv.first { $0.checked }?.title == "3×" && lv.count == 11)
        m.apply(.duplicateZoom(id: id)); #expect(m.zooms.count == 4)
        m.apply(.removeAllZooms); #expect(m.zooms.isEmpty)
        m.undo(); #expect(m.zooms.count == 4)                                                       // one undo restores all
        m.apply(.removeZoom(id: id)); #expect(m.zooms.count == 3)
    }

    @Test func maskLayoutAndTextMenusDuplicateDisableAndDelete() throws {
        let (m, _) = model()
        m.seek(toNs: 2 * Self.sec); m.addHighlightAtPlayhead(kind: .blur)
        let hid = try #require(m.highlights.first?.id)
        let e = TimelineMenu.entries(for: .highlight(id: hid), in: m)
        #expect(titles(e) == ["Duplicate", "Disable", "Focus Timeline on Start", "Copy Settings", "Delete"])
        m.apply(.setEnabled(.highlight(hid), false)); #expect(m.highlights[0].enabled == false)
        #expect(find(TimelineMenu.entries(for: .highlight(id: hid), in: m), "Disable")?.checked == true)
        m.apply(.duplicate(.highlight(hid))); #expect(m.highlights.count == 2 && Set(m.highlights.map(\.id)).count == 2)
        m.seek(toNs: 0); m.apply(.focusStart(.highlight(hid))); #expect(m.playheadNs == 2 * Self.sec)
        m.apply(.delete(.highlight(hid))); #expect(m.highlights.count == 1)
        m.seek(toNs: Self.sec); m.addText(.annotation)
        let tid = try #require(m.textItems(.annotation).first?.id)
        #expect(titles(TimelineMenu.entries(for: .text(.annotation, id: tid), in: m)) == ["Duplicate", "Delete"])   // text has no enabled flag
        m.apply(.duplicate(.text(.annotation, tid))); #expect(m.textItems(.annotation).count == 2)
        #expect(titles(TimelineMenu.entries(for: .music(id: "x"), in: m)) == ["Delete"])
        #expect(titles(TimelineMenu.entries(for: .empty(atNs: 3 * Self.sec), in: m)) == ["Paste Settings", "Add Zoom Here"])
        m.apply(.addZoom(atNs: 3 * Self.sec)); #expect(m.zooms.count == 1)
    }

    @Test func nsMenuMirrorsEntriesAndRunsActions() throws {
        let (m, _) = model(); let id = m.clips[0].id
        var ran: [TimelineMenu.Action] = []
        let menu = TimelineMenu.nsMenu(TimelineMenu.entries(for: .clip(id: id, atNs: Self.sec), in: m)) { ran.append($0) }
        let speed = try #require(menu.items.first { $0.title == "Set Speed" })
        let two = try #require(speed.submenu?.items.first { $0.title == "2×" })
        _ = two.target?.perform(two.action)
        #expect(ran == [.clipSpeed(id: id, 2)])
        #expect(menu.items.first { $0.title == "Remove" }?.isEnabled == false)
    }
}

/// S-EDT-23: edge-drag trim of clips.
@MainActor @Suite struct ClipTrimTests {
    static let sec: Int64 = 1_000_000_000
    let plain: (mic: Double, system: Double, hideCursor: Bool, disableSmoothing: Bool) = (1, 1, false, false)
    func clip(speed: Double = 1) -> ClipTrim.Clip { .init(id: "a", startNs: 4 * Self.sec, srcStartNs: 4 * Self.sec, srcEndNs: 10 * Self.sec, speed: speed) }
    func plan(_ edge: ClipTrim.Edge, _ target: Int64, clip c: ClipTrim.Clip? = nil, before: Int64 = 0, after: Int64 = 0) -> ClipTrim.Plan {
        ClipTrim.plan(clip: c ?? clip(), edge: edge, targetNs: target, minLengthNs: 100_000_000, restorableBeforeNs: before, restorableAfterNs: after, settings: plain)
    }

    @Test func shrinkingDeletesTheDraggedPartAndStaysAboveTheMinimumLength() {
        #expect(plan(.start, 6 * Self.sec).commands == [.deleteRange(startNs: 4 * Self.sec, endNs: 6 * Self.sec)])
        #expect(plan(.end, 8 * Self.sec).commands == [.deleteRange(startNs: 8 * Self.sec, endNs: 10 * Self.sec)])
        let p = plan(.start, 50 * Self.sec)                                             // dragged far past the other end
        #expect(p.deltaNs == -(6 * Self.sec - 100_000_000) && p.commands.count == 1)    // leaves the 100 ms minimum
        #expect(plan(.end, 4 * Self.sec).edgeNs == 4 * Self.sec + 100_000_000)
    }

    @Test func growingRestoresOnlyWhatWasCutAwayNextToTheEdge() {
        let g = plan(.end, 11 * Self.sec, after: 5 * Self.sec)
        #expect(g.commands == [.restoreClipEdge(clipID: "a", start: false, sourceNs: 11 * Self.sec)])
        let s = plan(.start, 3 * Self.sec, before: 4 * Self.sec)
        #expect(s.commands == [.restoreClipEdge(clipID: "a", start: true, sourceNs: 3 * Self.sec)])
        #expect(plan(.end, 99 * Self.sec, after: 2 * Self.sec).deltaNs == 2 * Self.sec)  // clamped to the available source
        #expect(plan(.end, 11 * Self.sec).commands.isEmpty && plan(.start, 3 * Self.sec).commands.isEmpty)     // nothing cut away: nothing to grow
    }

    @Test func speedScalesTheSourceDelta() {
        let c = clip(speed: 2)                                                           // 6 s of source = 3 s on the timeline: ends at 7 s
        #expect(c.endNs == 7 * Self.sec)
        let g = plan(.end, 8 * Self.sec, clip: c, after: 10 * Self.sec)                 // +1 s on the timeline = +2 s of source
        #expect(g.commands == [.restoreClipEdge(clipID: "a", start: false, sourceNs: 12 * Self.sec)])
    }

    @Test func modelCommitsOneUndoStepAndBringsTheMaterialBack() throws {
        let p = FakeProject(durationNs: 20 * Self.sec), m = EditorModel(project: p, player: FakePlayer())
        let id = m.clips[0].id
        #expect(m.trimClipEdge(clipID: id, start: true, toNs: 5 * Self.sec))             // cut 5 s off the head
        #expect(m.durationNs == 15 * Self.sec && m.clips[0].srcStartNs == 5 * Self.sec)
        #expect(m.trimClipEdge(clipID: m.clips[0].id, start: false, toNs: 10 * Self.sec))   // and the tail beyond 10 s
        #expect(m.durationNs == 10 * Self.sec)
        let grow = m.clips[0].id
        #expect(m.trimClipEdge(clipID: grow, start: false, toNs: 13 * Self.sec))        // pull the tail back by 3 s
        #expect(m.durationNs == 13 * Self.sec)
        m.undo(); #expect(m.durationNs == 10 * Self.sec)                                 // one undo step
        #expect(!m.trimClipEdge(clipID: "missing", start: true, toNs: 0))
    }

    @Test func mergeMenuEntriesNeedAContiguousNeighbourAndMergeOneUndoStep() throws {
        let p = FakeProject(durationNs: 20 * Self.sec), m = EditorModel(project: p, player: FakePlayer())
        let first = m.clips[0].id
        let single = TimelineMenu.entries(for: .clip(id: first, atNs: Self.sec), in: m).filter { $0.title.hasPrefix("Merge") }
        #expect(single.count == 2 && single.allSatisfy { !$0.enabled })                  // a lone clip has no neighbour
        m.seek(toNs: 8 * Self.sec); m.splitAtPlayhead()
        let (a, b) = (m.clips[0].id, m.clips[1].id)
        let next = try #require(TimelineMenu.entries(for: .clip(id: a, atNs: 0), in: m).first { $0.title == "Merge with Next Clip" })
        #expect(next.action == .mergeClip(id: a, withNext: true) && next.enabled)
        #expect(TimelineMenu.entries(for: .clip(id: a, atNs: 0), in: m).first { $0.title == "Merge with Previous Clip" }?.enabled == false)
        #expect(TimelineMenu.entries(for: .clip(id: b, atNs: 0), in: m).first { $0.title == "Merge with Next Clip" }?.enabled == false)
        m.apply(.mergeClip(id: b, withNext: false))                                       // previous: keeps the right clip's settings
        #expect(m.clips.count == 1 && m.durationNs == 20 * Self.sec)
        m.undo(); #expect(m.clips.count == 2)
    }

    @Test func clickRouterGivesEdgeDragsAnEdgeAndScissorsKeepCutting() {
        let l = TimelineLayout(lanes: []), g = TimelineGeometry(pixelsPerSecond: 100)
        func input(_ x: Double, cut: Bool = false) -> TimelineClick.Input {
            .init(point: CGPoint(x: x, y: l.clipTop + 10), layout: l, geometry: g, cutTool: cut, multiSelect: false, durationNs: 20 * Self.sec,
                  zooms: [], rangeItems: [], rangePreview: [:], typing: [], clips: [("a", 0, 10 * Self.sec), ("b", 10 * Self.sec, 20 * Self.sec)])
        }
        #expect(TimelineClick.decide(input(1003)) == .clipEdge(id: "b", edge: .start))
        #expect(TimelineClick.decide(input(997)) == .clipEdge(id: "a", edge: .end))
        #expect(TimelineClick.decide(input(1997)) == .clipEdge(id: "b", edge: .end))
        #expect(TimelineClick.decide(input(500)) == .scrub(selectClip: "a"))
        #expect(TimelineClick.decide(input(1003, cut: true)) == .clipCut(atNs: 10_030_000_000))
    }
}
