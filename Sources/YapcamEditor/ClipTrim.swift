import Foundation

/// Edge-drag trim of a clip (S-EDT-23). Pure planning: `plan` turns "the pointer is at timeline time T" into the amount that
/// really changes (clamped to the minimum length and to the cut-away source next to the edge) and the core commands.
/// A start edge keeps its timeline position (later clips ripple), so shrinking removes head material and growing puts
/// the trimmed material back in front of the clip; the end edge mirrors that.
enum ClipTrim {
    enum Edge: Equatable { case start, end }

    struct Clip: Equatable {
        var id: String
        var startNs: Int64                 // on the timeline
        var srcStartNs: Int64, srcEndNs: Int64
        var speed: Double
        var durationNs: Int64 { Int64(Double(srcEndNs - srcStartNs) / max(speed, 0.0001)) }
        var endNs: Int64 { startNs + durationNs }
    }

    struct Plan: Equatable {
        /// Timeline time the edge ends up at after clamping (what a preview line shows).
        var edgeNs: Int64
        /// Signed change of the clip's timeline length: negative = shrink, positive = restore trimmed source.
        var deltaNs: Int64
        var commands: [EditorCommand]
    }

    /// `restorableBeforeNs` / `restorableAfterNs`: cut-away source directly before the clip's first / after its last frame.
    static func plan(clip c: Clip, edge: Edge, targetNs: Int64, minLengthNs: Int64,
                     restorableBeforeNs: Int64, restorableAfterNs: Int64,
                     settings: (mic: Double, system: Double, hideCursor: Bool, disableSmoothing: Bool)) -> Plan {
        let speed = max(c.speed, 0.0001)
        // Wanted change in clip length (timeline ns): start edge dragged right shrinks, end edge dragged left shrinks.
        let raw = edge == .start ? targetNs - c.startNs : c.endNs - targetNs
        let maxShrink = max(c.durationNs - minLengthNs, 0)
        let maxGrow = Int64(Double(edge == .start ? restorableBeforeNs : restorableAfterNs) / speed)
        let shrink = min(max(raw, 0), maxShrink)
        let grow = min(max(-raw, 0), maxGrow)
        let delta = grow > 0 ? grow : -shrink
        let edgeNs: Int64
        switch edge {
        case .start: edgeNs = c.startNs + (delta < 0 ? -delta : 0)
        case .end: edgeNs = c.endNs + delta
        }
        if delta == 0 { return Plan(edgeNs: edge == .start ? c.startNs : c.endNs, deltaNs: 0, commands: []) }
        if delta < 0 {
            let cut = -delta
            return Plan(edgeNs: edgeNs, deltaNs: delta,
                        commands: [edge == .start ? .deleteRange(startNs: c.startNs, endNs: c.startNs + cut) : .deleteRange(startNs: c.endNs - cut, endNs: c.endNs)])
        }
        let src = Int64(Double(delta) * speed)
        // Growth extends the same clip over the cut-away source (core `restore_clip_edge`), so its settings and identity stay.
        let boundary = edge == .start ? c.srcStartNs - src : c.srcEndNs + src
        return Plan(edgeNs: edgeNs, deltaNs: delta, commands: [.restoreClipEdge(clipID: c.id, start: edge == .start, sourceNs: boundary)])
    }
}

extension EditorModel {
    func trimPlan(clipID: String, edge: ClipTrim.Edge, targetNs: Int64) -> ClipTrim.Plan? {
        guard let e = clipStarts().first(where: { $0.clip.id == clipID }) else { return nil }
        let c = e.clip, gaps = trimGaps()
        let before = gaps.first { $0.endNs == c.srcStartNs }.map { $0.endNs - $0.startNs } ?? 0
        let after = gaps.first { $0.startNs == c.srcEndNs }.map { $0.endNs - $0.startNs } ?? 0
        return ClipTrim.plan(clip: .init(id: c.id, startNs: e.startNs, srcStartNs: c.srcStartNs, srcEndNs: c.srcEndNs, speed: c.speed),
                             edge: edge, targetNs: targetNs, minLengthNs: minItemNs, restorableBeforeNs: before, restorableAfterNs: after,
                             settings: (c.micGain, c.systemGain, c.hideCursor, c.disableSmoothing))
    }
    /// Commits an edge drag as one undo step; returns whether anything changed.
    @discardableResult public func trimClipEdge(clipID: String, start: Bool, toNs ns: Int64) -> Bool {
        guard let plan = trimPlan(clipID: clipID, edge: start ? .start : .end, targetNs: ns), !plan.commands.isEmpty else { return false }
        perform(plan.commands.count == 1 ? plan.commands[0] : .batch(plan.commands))
        return true
    }
}
