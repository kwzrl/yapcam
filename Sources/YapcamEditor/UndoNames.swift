import Foundation

/// Names of the edits on the undo/redo stacks, so the toolbar can say "Undo Trim Clip". Every edit pushes an entry (nil =
/// unnamed, shown as plain "Undo"), so the stacks stay aligned with the project history.
struct UndoNames: Equatable {
    private(set) var undo: [String?] = [], redo: [String?] = []
    private var lastKey: String?, lastAt = Date.distantPast
    static let coalesceWindow: TimeInterval = 0.1

    var undoTitle: String { (undo.last ?? nil).map { "Undo \($0)" } ?? "Undo" }
    var redoTitle: String { (redo.last ?? nil).map { "Redo \($0)" } ?? "Redo" }

    /// A new edit happened (a fresh one invalidates redo).
    mutating func pushUnnamed() { undo.append(nil); redo = [] }
    /// Gives the edit just pushed its name. Same-key edits less than 100 ms apart share one undo step in core
    /// (coalesced_edit), so the entry pushed for the repeat is dropped.
    mutating func name(_ name: String?, coalesceKey: String?, now: Date) {
        defer { lastAt = now; lastKey = coalesceKey }
        if let k = coalesceKey, k == lastKey, now.timeIntervalSince(lastAt) < Self.coalesceWindow, undo.count > 1 { undo.removeLast(); return }
        if !undo.isEmpty { undo[undo.count - 1] = name }
    }
    mutating func undone() { if let n = undo.popLast() { redo.append(n) }; lastKey = nil }
    mutating func redone() { if let n = redo.popLast() { undo.append(n) }; lastKey = nil }
}
