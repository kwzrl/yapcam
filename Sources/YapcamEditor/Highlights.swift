import Foundation
import CoreGraphics
import YapcamCore

/// Mask / highlight / spotlight region (core `canvas.highlights`, drawn by render after zoom/crop).
public struct HighlightRegion: Equatable, Identifiable, Sendable {
    public var id: String
    public var startNs: Int64, endNs: Int64
    public var rect: [Double]            // normalized [x, y, w, h]
    public var space: String             // source (follows zoom/crop) | canvas
    public var radius: Double, opacity: Double, dimOpacity: Double
    public var fill: [Double], stroke: [Double]
    public var strokeWidth: Double
    /// Disabled masks draw nothing and don't count toward the 32 simultaneous masks (core `enabled`, missing = true).
    public var enabled = true
    /// Moving mask: strictly ordered rectangles at timeline times inside the mask; the initial `rect` applies from its start.
    public var keyframes: [RegionKeyframe] = []
    /// Core `kind: "blur"`: the region shows a blurred copy of the picture (sensitive data) instead of drawing a cover.
    public var isBlur = false
    /// Gaussian strength in canvas pixels (core: 0…128, default 32).
    public var blurRadius = HighlightRegion.defaultBlurRadius
    public static let defaultBlurRadius = 32.0, blurRadiusRange = 0.0...128.0
    public var span: TimeSpan { TimeSpan(startNs: startNs, endNs: endNs) }

    public enum Kind: String, CaseIterable, Sendable { case highlight, blur, mask, spotlight
        public var label: String { switch self { case .highlight: "Highlight"; case .blur: "Mask (blur)"; case .mask: "Mask (cover)"; case .spotlight: "Spotlight" } }
    }
    /// Which preset this region most closely matches (for the chip title and inspector).
    public var kind: Kind {
        if isBlur { return .blur }
        if fill.count == 4, fill[3] >= 0.99, dimOpacity == 0 { return .mask }
        if strokeWidth == 0 && dimOpacity >= 0.5 { return .spotlight }
        return .highlight
    }
    public static func preset(_ kind: Kind, id: String, start: Int64, end: Int64) -> HighlightRegion {
        var h = HighlightRegion(id: id, startNs: start, endNs: end, rect: [0.25, 0.25, 0.5, 0.5], space: "source", radius: 12,
                                opacity: 1, dimOpacity: 0.5, fill: [1, 0.85, 0.2, 0], stroke: [1, 0.85, 0.2, 1], strokeWidth: 3)
        h.apply(kind)
        return h
    }
    public mutating func apply(_ kind: Kind) {
        isBlur = kind == .blur
        switch kind {
        case .blur: fill = [fill[0], fill[1], fill[2], 0]; dimOpacity = 0; strokeWidth = 0; stroke = [stroke[0], stroke[1], stroke[2], 0]
        case .highlight: fill = [fill[0], fill[1], fill[2], 0]; dimOpacity = 0.5; strokeWidth = max(strokeWidth, 3); stroke = [stroke[0], stroke[1], stroke[2], 1]
        case .mask: fill = [0.1, 0.1, 0.1, 1]; dimOpacity = 0; strokeWidth = 0; stroke = [0, 0, 0, 0]
        case .spotlight: fill = [fill[0], fill[1], fill[2], 0]; dimOpacity = 0.65; strokeWidth = 0; stroke = [stroke[0], stroke[1], stroke[2], 0]
        }
    }
}

public struct RegionKeyframe: Equatable, Sendable { public var tlNs: Int64; public var rect: [Double] }

extension HighlightRegion {
    func withState(enabled: Bool, keyframes: [RegionKeyframe]) -> HighlightRegion { var h = self; h.enabled = enabled; h.keyframes = keyframes; return h }
}

extension HighlightRegion {
    /// Rectangle at a timeline time: linear from the initial rect to the first key, between keys, then the last key held.
    public func rect(atNs t: Int64) -> [Double] {
        guard let first = keyframes.first else { return rect }
        func lerp(_ a: [Double], _ b: [Double], _ f: Double) -> [Double] { zip(a, b).map { $0 + ($1 - $0) * f } }
        if t <= startNs { return rect }
        if t < first.tlNs { return lerp(rect, first.rect, Double(t - startNs) / Double(max(first.tlNs - startNs, 1))) }
        for (a, b) in zip(keyframes, keyframes.dropFirst()) where t < b.tlNs { return lerp(a.rect, b.rect, Double(t - a.tlNs) / Double(max(b.tlNs - a.tlNs, 1))) }
        return keyframes.last!.rect
    }
    /// The mask after moving or trimming it to [start, end]. Core rejects keyframes outside the interval, so:
    /// a move (same length) shifts every keyframe with it; a trim keeps the keys that are still inside, starts from the box the
    /// picture had at the new start, and ends on the box it had at the new end when later keys were cut off.
    func retimed(startNs newStart: Int64, endNs newEnd: Int64) -> HighlightRegion {
        var r = self
        r.startNs = newStart; r.endNs = newEnd
        guard !keyframes.isEmpty else { return r }
        if newEnd - newStart == endNs - startNs {
            let delta = newStart - startNs
            r.keyframes = keyframes.map { RegionKeyframe(tlNs: $0.tlNs + delta, rect: $0.rect) }
            return r
        }
        r.rect = newStart > startNs ? rect(atNs: newStart) : rect
        var kept = keyframes.filter { $0.tlNs > newStart && $0.tlNs <= newEnd }
        if keyframes.contains(where: { $0.tlNs > newEnd }), kept.last?.tlNs != newEnd {
            kept.append(RegionKeyframe(tlNs: newEnd, rect: rect(atNs: newEnd)))
        }
        r.keyframes = kept
        return r
    }
    /// The two halves of a split at `t`: keys partition at the cut and both halves keep the picture's motion.
    func split(atNs t: Int64) -> (first: HighlightRegion, second: HighlightRegion) {
        let atCut = rect(atNs: t)
        var a = self, b = self
        a.endNs = t; b.startNs = t; b.rect = atCut
        let before = keyframes.filter { $0.tlNs < t }, after = keyframes.filter { $0.tlNs > t }
        a.keyframes = keyframes.isEmpty ? [] : before + [RegionKeyframe(tlNs: t, rect: atCut)]
        b.keyframes = after
        return (a, b)
    }
}

public let maxOverlappingHighlights = 32

extension EditorModel {
    private func nums(_ v: JSONValue?) -> [Double] {
        if case .array(let a)? = v { return a.compactMap { if case .number(let d) = $0 { d } else { nil } } }
        return []
    }
    private func num(_ v: JSONValue?, _ d: Double) -> Double { if case .number(let x)? = v { x } else { d } }

    public var highlights: [HighlightRegion] {
        guard case .array(let rows)? = value("canvas.highlights") else { return [] }
        return rows.compactMap { row in
            guard case .object(let o) = row, case .string(let id)? = o["id"], case .number(let a)? = o["tl_start_ns"], case .number(let b)? = o["tl_end_ns"] else { return nil }
            let rect = nums(o["rect"]), fill = nums(o["fill"]), stroke = nums(o["stroke"])
            var space = "source"; if case .string(let s)? = o["space"] { space = s }
            var enabled = true; if case .bool(let e)? = o["enabled"] { enabled = e }
            var keys: [RegionKeyframe] = []
            if case .array(let ks)? = o["keyframes"] {
                keys = ks.compactMap { k in
                    guard case .object(let ko) = k, case .number(let t)? = ko["tl_ns"] else { return nil }
                    let r = nums(ko["rect"]); return r.count == 4 ? RegionKeyframe(tlNs: Int64(t), rect: r) : nil
                }
            }
            return HighlightRegion(id: id, startNs: Int64(a), endNs: Int64(b), rect: rect.count == 4 ? rect : [0.25, 0.25, 0.5, 0.5], space: space,
                                   radius: num(o["radius"], 12), opacity: num(o["opacity"], 1), dimOpacity: num(o["dim_opacity"], 0.5),
                                   fill: fill.count == 4 ? fill : [1, 0.85, 0.2, 0], stroke: stroke.count == 4 ? stroke : [1, 0.85, 0.2, 1],
                                   strokeWidth: num(o["stroke_width"], 3), isBlur: { if case .string("blur")? = o["kind"] { true } else { false } }(),
                                   blurRadius: min(max(num(o["blur_radius"], HighlightRegion.defaultBlurRadius), 0), 128))
                .withState(enabled: enabled, keyframes: keys)
        }
    }

    private func json(_ h: HighlightRegion) -> JSONValue {
        func arr(_ a: [Double]) -> JSONValue { .array(a.map { .number($0) }) }
        return .object(["id": .string(h.id), "tl_start_ns": .number(Double(h.startNs)), "tl_end_ns": .number(Double(h.endNs)),
                        "rect": arr(h.rect), "space": .string(h.space), "radius": .number(h.radius), "opacity": .number(h.opacity),
                        "dim_opacity": .number(h.dimOpacity), "fill": arr(h.fill), "stroke": arr(h.stroke), "stroke_width": .number(h.strokeWidth),
                        "kind": .string(h.isBlur ? "blur" : "highlight"), "blur_radius": .number(h.blurRadius),
                        "enabled": .bool(h.enabled),
                        "keyframes": .array(h.keyframes.map { .object(["tl_ns": .number(Double($0.tlNs)), "rect": arr($0.rect)]) })])
    }
    private func writeHighlights(_ hs: [HighlightRegion]) { set("canvas.highlights", .array(hs.map(json))) }
    func writeHighlightList(_ hs: [HighlightRegion]) { writeHighlights(hs) }

    public func addHighlightAtPlayhead(kind: HighlightRegion.Kind = .highlight) {
        // New regions inherit the style of the last edited one (when it is of the same kind).
        addHighlight(fromNs: playheadNs, kind: kind)
    }

    public func updateHighlight(id: String, _ change: (inout HighlightRegion) -> Void) {
        writeHighlights(highlights.map { var h = $0; if h.id == id { change(&h); lastRegionStyle = h }; return h })
    }
    /// "Apply to all": copies the style (not the time or box) of one region to every other region of the same kind.
    public func applyHighlightStyleToAll(from id: String) {
        guard let src = highlights.first(where: { $0.id == id }) else { return }
        writeHighlights(highlights.map { var h = $0
            if h.id != id, h.kind == src.kind { h.fill = src.fill; h.stroke = src.stroke; h.strokeWidth = src.strokeWidth; h.radius = src.radius; h.dimOpacity = src.dimOpacity; h.opacity = src.opacity; h.blurRadius = src.blurRadius }
            return h })
    }
    public func setHighlightEnabled(id: String, _ on: Bool) { updateHighlightKeepingStyle(id: id) { $0.enabled = on } }
    /// Edits a region without making it the style new regions inherit (state such as enabled/keys is never inherited).
    func updateHighlightKeepingStyle(id: String, _ change: (inout HighlightRegion) -> Void) {
        writeHighlights(highlights.map { var h = $0; if h.id == id { change(&h) }; return h })
    }
    /// Moving mask: stores the current box as a keyframe at the playhead (replacing a key at the same time).
    public func addRegionKeyframeAtPlayhead(id: String) {
        guard let h = highlights.first(where: { $0.id == id }), playheadNs > h.startNs, playheadNs <= h.endNs else { lastError = "Move the playhead inside the mask first."; return }
        let t = playheadNs, here = h.rect(atNs: t)
        updateHighlightKeepingStyle(id: id) { r in
            r.keyframes = (r.keyframes.filter { $0.tlNs != t } + [RegionKeyframe(tlNs: t, rect: here)]).sorted { $0.tlNs < $1.tlNs }
        }
    }
    public func removeRegionKeyframes(id: String) { updateHighlightKeepingStyle(id: id) { $0.keyframes = [] } }
    public func setHighlightKind(id: String, _ kind: HighlightRegion.Kind) { updateHighlight(id: id) { $0.apply(kind) } }
    public func removeHighlight(id: String) { writeHighlights(highlights.filter { $0.id != id }) }

    // MARK: rect drag on the preview (one command per gesture)

    public func previewHighlightRect(id: String, rect: [Double]) {
        let w = min(max(rect[2], 0.02), 1), h = min(max(rect[3], 0.02), 1)
        let x = min(max(rect[0], 0), 1 - w), y = min(max(rect[1], 0), 1 - h)
        highlightRectPreview = (id, [x, y, w, h])
    }
    public func commitHighlightRect() {
        guard let p = highlightRectPreview else { return }
        highlightRectPreview = nil
        guard let cur = highlights.first(where: { $0.id == p.id }), cur.rect(atNs: playheadNs) != p.rect else { return }
        if !cur.keyframes.isEmpty, playheadNs > cur.startNs, playheadNs <= cur.endNs {
            // A moving mask: the box edited at this time becomes (or moves) the keyframe here.
            let t = playheadNs
            updateHighlightKeepingStyle(id: p.id) { r in
                r.keyframes = (r.keyframes.filter { $0.tlNs != t } + [RegionKeyframe(tlNs: t, rect: p.rect)]).sorted { $0.tlNs < $1.tlNs }
            }
            return
        }
        updateHighlight(id: p.id) { $0.rect = p.rect }
    }
    public func displayedRect(of h: HighlightRegion) -> [Double] {
        if let p = highlightRectPreview, p.id == h.id { return p.rect }
        return h.rect(atNs: playheadNs)
    }
}
