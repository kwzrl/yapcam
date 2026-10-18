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
