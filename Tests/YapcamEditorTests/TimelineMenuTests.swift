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
        #expect(titles(e) == ["Set Speed", "Set Volume", "Microphone Volume", "System Audio Volume", "Remove", "Split Here", "Reset Trim",
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
        #expect(titles(e) == ["Remove", "Duplicate", "Disable", "Set Zoom Level", "Disable All", "Enable All", "Restore Automatic Zooms", "Remove All Zooms"])
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
        #expect(titles(e) == ["Duplicate", "Disable", "Focus Timeline on Start", "Delete"])
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
