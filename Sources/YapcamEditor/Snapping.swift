import Foundation

public struct SnapTarget: Equatable, Sendable {
    public enum Kind: String, Sendable { case playhead, clipEdge, zoomEdge, click, start, end }
    public var ns: Int64
    public var kind: Kind
}

public struct SnapResult: Equatable, Sendable {
    public var ns: Int64
    public var target: SnapTarget?   // non-nil → draw a snap guide
}

public enum Snapping {
    /// Snap `ns` to the nearest target within `thresholdPx` (converted via geometry).
    public static func snap(_ ns: Int64, targets: [SnapTarget], geometry: TimelineGeometry,
                            thresholdPx: Double = 8, enabled: Bool = true) -> SnapResult {
        guard enabled else { return SnapResult(ns: ns, target: nil) }
        let thresholdNs = Int64(thresholdPx / geometry.pixelsPerSecond * 1e9)
        var best: SnapTarget?
        var bestDist = Int64.max
        for t in targets {
            let d = abs(t.ns - ns)
            if d <= thresholdNs && d < bestDist { best = t; bestDist = d }
        }
        if let best { return SnapResult(ns: best.ns, target: best) }
        return SnapResult(ns: ns, target: nil)
    }

    public static func targets(clips: [TimelineClip], zooms: [TimelineZoom], clicks: [Int64], playheadNs: Int64,
                               durationNs: Int64, excludingZoom: String? = nil, includePlayhead: Bool = true) -> [SnapTarget] {
        var out: [SnapTarget] = [.init(ns: 0, kind: .start), .init(ns: durationNs, kind: .end)]
        if includePlayhead { out.append(.init(ns: playheadNs, kind: .playhead)) }
        var t: Int64 = 0
        for c in clips { out.append(.init(ns: t, kind: .clipEdge)); t += c.timelineDurationNs; out.append(.init(ns: t, kind: .clipEdge)) }
        for z in zooms where z.id != excludingZoom {
            out.append(.init(ns: z.startNs, kind: .zoomEdge)); out.append(.init(ns: z.endNs, kind: .zoomEdge))
        }
        out += clicks.map { .init(ns: $0, kind: .click) }
        return out
    }
}
