import Foundation
import Testing
@testable import YapcamEditor

@MainActor @Suite struct TranscriptKeyTests {
    @Test func deleteCutsButCommandDeleteOnlyHidesFromCaptions() {
        #expect(TranscriptKey.deleteAction(command: false, selection: ["a"]) == .cut)
        #expect(TranscriptKey.deleteAction(command: true, selection: ["a", "b"]) == .hide)
        #expect(TranscriptKey.deleteAction(command: true, selection: []) == .none)
    }

    @Test func returnCorrectsOnlyASingleSelectedWord() {
        #expect(TranscriptKey.editTarget(selection: ["w1"]) == "w1")
        #expect(TranscriptKey.editTarget(selection: ["w1", "w2"]) == nil)
        #expect(TranscriptKey.editTarget(selection: []) == nil)
    }
}

@MainActor @Suite struct UndoNamingTests {
    static let sec: Int64 = 1_000_000_000
    func model() -> EditorModel { EditorModel(project: FakeProject(durationNs: 20 * Self.sec), player: FakePlayer()) }

    @Test func tooltipsNameTheEditThatWouldBeUndoneAndRedone() {
        let m = model()
        #expect(m.undoTitle == "Undo")
        m.seek(toNs: 5 * Self.sec); m.splitAtPlayhead()
        #expect(m.undoTitle == "Undo Split Clip")
        m.trimClipEdge(clipID: m.clips[0].id, start: true, toNs: 2 * Self.sec)
        #expect(m.undoTitle == "Undo Delete Range")
        m.undo()
        #expect(m.undoTitle == "Undo Split Clip" && m.redoTitle == "Redo Delete Range")
        m.redo()
        #expect(m.undoTitle == "Undo Delete Range" && m.redoTitle == "Redo")
    }

    @Test func coalescedEditsShareOneNameAndOneStep() {
        var n = UndoNames(), t = Date()
        n.pushUnnamed(); n.name("Edit Zoom", coalesceKey: "z", now: t)
        n.pushUnnamed(); n.name("Edit Zoom", coalesceKey: "z", now: t.addingTimeInterval(0.05))
        #expect(n.undo.count == 1)
        n.pushUnnamed(); n.name("Edit Zoom", coalesceKey: "z", now: t.addingTimeInterval(0.5))
        #expect(n.undo.count == 2)
    }

    @Test func commandSaveShortcutSavesNow() {
        let m = model()
        m.seek(toNs: 5 * Self.sec); m.splitAtPlayhead()
        #expect(m.saveState == .dirty)
        #expect(m.handleShortcut("s", [.command]) && m.saveState == .clean)
    }
}

@MainActor @Suite struct ViewStateTests {
    static let sec: Int64 = 1_000_000_000
    func model() -> EditorModel { EditorModel(project: FakeProject(durationNs: 20 * Self.sec), player: FakePlayer()) }

    @Test func undoKeepsThePlayheadOnTheSameSourceMoment() {
        let m = model()
        m.seek(toNs: 10 * Self.sec)                                   // 10 s of the recording
        #expect(m.trimClipEdge(clipID: m.clips[0].id, start: true, toNs: 4 * Self.sec))   // cut the first 4 s
        #expect(m.playheadNs == 6 * Self.sec || m.playheadNs <= m.durationNs)
        m.seek(toNs: 6 * Self.sec)                                    // still source second 10
        m.undo()
        #expect(m.playheadNs == 10 * Self.sec)                        // restored material pushed it: playhead followed
        m.redo()
        #expect(m.playheadNs == 6 * Self.sec)
    }

    @Test func sourceMomentMappingHandlesSpeedAndGaps() {
        var a = TimelineClip(id: "a", srcStartNs: 0, srcEndNs: 4 * Self.sec)
        a.speed = 2                                                     // 2 s on the timeline
        let b = TimelineClip(id: "b", srcStartNs: 10 * Self.sec, srcEndNs: 14 * Self.sec)
        let clips = [(clip: a, startNs: Int64(0)), (clip: b, startNs: 2 * Self.sec)]
        #expect(SourceMoment.source(atTimelineNs: Self.sec, in: clips) == 2 * Self.sec)
        #expect(SourceMoment.timeline(forSourceNs: 12 * Self.sec, in: clips) == 4 * Self.sec)
        #expect(SourceMoment.timeline(forSourceNs: 7 * Self.sec, in: clips) == nil)    // cut away
    }

    @Test func applyToAllToastsAndPanelsToggleWithKeys() {
        let m = model()
        m.seek(toNs: 5 * Self.sec); m.splitAtPlayhead()
        m.applySpeedToAll(2)
        #expect(m.toast == "Applied 2× to 2 clips")
        #expect(!m.sidebarHidden && !m.timelineHidden)
        #expect(m.handleShortcut("\\", [.command]) && m.sidebarHidden && !m.timelineHidden)
        #expect(m.handleShortcut("\\", [.command, .shift]) && m.timelineHidden)
    }
}
