import CoreGraphics
import Foundation

/// What a pointer-down on the timeline means. Pure: the view feeds in a snapshot and applies the answer, so every
/// lane × tool combination is testable without a window (the scissors-on-zoom bug lived in the untested click path).
enum TimelineClick {
    enum ZoomPart: Equatable { case start, end, move(grabOffsetNs: Int64) }

    struct Input {
        var point: CGPoint
        var layout: TimelineLayout
        var geometry: TimelineGeometry
        var cutTool: Bool
        var multiSelect: Bool                              // ⇧ or ⌘ held
        var durationNs: Int64
        var zooms: [(id: String, startNs: Int64, endNs: Int64)]     // displayed ranges, drawing order
        var rangeItems: [LaneHitTest.Item]
        var rangePreview: [String: (start: Int64, end: Int64)]
        var typing: [(startNs: Int64, endNs: Int64)]
        var clips: [(id: String, startNs: Int64, endNs: Int64)]
    }

    enum Action: Equatable {
        case scrub(selectClip: String?)                    // nil clears the selection
        case typingPopover(startNs: Int64)
        case rangeDrag(key: String, part: LaneHitTest.Part, select: EditorSelection)
        case rangeSelectOnly(EditorSelection)              // scissors over an item that cannot be split: select, never drag
        case rangeCut(select: EditorSelection, atNs: Int64)
        case zoomCreate(atNs: Int64)
        case zoomCut(id: String, atNs: Int64)
        case zoomToggleSelect(id: String)
        case zoomDrag(id: String, part: ZoomPart)
        case clipCut(atNs: Int64)
        case nothing
    }

    static func splittable(_ s: EditorSelection) -> Bool {
        switch s { case .layout, .highlight: return true; default: return false }
    }

    static func decide(_ i: Input) -> Action {
        let p = i.point, g = i.geometry, l = i.layout
        guard p.x.isFinite, p.y.isFinite else { return .nothing }
        if p.y < l.clipTop { return .scrub(selectClip: nil) }
        let ns = g.ns(forX: p.x)
        if l.lanes.contains(.typing), p.y >= l.typingTop, p.y < l.typingTop + TimelineLayout.laneHeight,
           let sp = i.typing.first(where: { p.x >= g.x(forNs: $0.startNs) - 2 && p.x <= g.x(forNs: $0.endNs) + 2 }) {
            return .typingPopover(startNs: sp.startNs)
        }
        if p.y >= l.lanesTop {
            if let hit = LaneHitTest.topmost(x: p.x, y: p.y, items: i.rangeItems, preview: i.rangePreview, geometry: g) {
                if i.cutTool {
                    return splittable(hit.tag) ? .rangeCut(select: hit.tag, atNs: ns) : .rangeSelectOnly(hit.tag)
                }
                return .rangeDrag(key: hit.key, part: hit.part, select: hit.tag)
            }
            return i.cutTool ? .nothing : .scrub(selectClip: nil)
        }
        if p.y >= l.zoomTop {
            if let z = i.zooms.last(where: { p.x >= g.x(forNs: $0.startNs) - 2 && p.x <= g.x(forNs: $0.endNs) + 2 }) {
                if i.cutTool { return .zoomCut(id: z.id, atNs: ns) }
                if i.multiSelect { return .zoomToggleSelect(id: z.id) }
                let x0 = g.x(forNs: z.startNs), x1 = g.x(forNs: z.endNs)
                let h = min(TimelineLayout.edgeHandle, (x1 - x0) / 3)
                if p.x <= x0 + h { return .zoomDrag(id: z.id, part: .start) }
                if p.x >= x1 - h { return .zoomDrag(id: z.id, part: .end) }
                return .zoomDrag(id: z.id, part: .move(grabOffsetNs: ns - z.startNs))
            }
            guard !i.cutTool else { return .nothing }
            return p.x >= 0 && ns < i.durationNs ? .zoomCreate(atNs: ns) : .scrub(selectClip: nil)
        }
        let clip = i.clips.first(where: { p.x >= g.x(forNs: $0.startNs) && p.x < g.x(forNs: $0.endNs) })
        if p.y < l.zoomTop - TimelineLayout.gap, let clip {
            return i.cutTool ? .clipCut(atNs: ns) : .scrub(selectClip: clip.id)
        }
        return .scrub(selectClip: nil)
    }
}
