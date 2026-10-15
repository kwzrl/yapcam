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
    public var span: TimeSpan { TimeSpan(startNs: startNs, endNs: endNs) }

    public enum Kind: String, CaseIterable, Sendable { case highlight, mask, spotlight
        public var label: String { switch self { case .highlight: "Highlight"; case .mask: "Mask (hide)"; case .spotlight: "Spotlight" } }
    }
    /// Which preset this region most closely matches (for the chip title and inspector).
    public var kind: Kind {
        if fill.count == 4, fill[3] >= 0.99, dimOpacity == 0 { return .mask }
        if strokeWidth == 0 && dimOpacity >= 0.5 { return .spotlight }
        return .highlight
    }
    public static func preset(_ kind: Kind, id: String, start: Int64, end: Int64) -> HighlightRegion {
        var h = HighlightRegion(id: id, startNs: start, endNs: end, rect: [0.25, 0.25, 0.5, 0.5], space: "source", radius: 12,
                                opacity: 1, dimOpacity: 0.4, fill: [1, 0.85, 0.2, 0], stroke: [1, 0.85, 0.2, 1], strokeWidth: 3)
        h.apply(kind)
        return h
    }
    public mutating func apply(_ kind: Kind) {
        switch kind {
        case .highlight: fill = [fill[0], fill[1], fill[2], 0]; dimOpacity = 0.4; strokeWidth = max(strokeWidth, 3); stroke = [stroke[0], stroke[1], stroke[2], 1]
        case .mask: fill = [0.1, 0.1, 0.1, 1]; dimOpacity = 0; strokeWidth = 0; stroke = [0, 0, 0, 0]
        case .spotlight: fill = [fill[0], fill[1], fill[2], 0]; dimOpacity = 0.65; strokeWidth = 0; stroke = [stroke[0], stroke[1], stroke[2], 0]
        }
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
            return HighlightRegion(id: id, startNs: Int64(a), endNs: Int64(b), rect: rect.count == 4 ? rect : [0.25, 0.25, 0.5, 0.5], space: space,
                                   radius: num(o["radius"], 12), opacity: num(o["opacity"], 1), dimOpacity: num(o["dim_opacity"], 0.4),
                                   fill: fill.count == 4 ? fill : [1, 0.85, 0.2, 0], stroke: stroke.count == 4 ? stroke : [1, 0.85, 0.2, 1],
                                   strokeWidth: num(o["stroke_width"], 3))
        }
    }

    private func json(_ h: HighlightRegion) -> JSONValue {
        func arr(_ a: [Double]) -> JSONValue { .array(a.map { .number($0) }) }
        return .object(["id": .string(h.id), "tl_start_ns": .number(Double(h.startNs)), "tl_end_ns": .number(Double(h.endNs)),
                        "rect": arr(h.rect), "space": .string(h.space), "radius": .number(h.radius), "opacity": .number(h.opacity),
                        "dim_opacity": .number(h.dimOpacity), "fill": arr(h.fill), "stroke": arr(h.stroke), "stroke_width": .number(h.strokeWidth)])
    }
    private func writeHighlights(_ hs: [HighlightRegion]) { set("canvas.highlights", .array(hs.map(json))) }
    func writeHighlightList(_ hs: [HighlightRegion]) { writeHighlights(hs) }

    public func addHighlightAtPlayhead(kind: HighlightRegion.Kind = .highlight) {
        let start = playheadNs, end = min(start + 3_000_000_000, durationNs)
        guard end - start >= minItemNs else { lastError = "Not enough room for a region here."; return }
        let h = HighlightRegion.preset(kind, id: "region-" + UUID().uuidString.prefix(8).lowercased(), start: start, end: end)
        writeHighlights(highlights + [h])
        if lastError == nil { selection = .highlight(h.id) }
    }

    public func updateHighlight(id: String, _ change: (inout HighlightRegion) -> Void) {
        writeHighlights(highlights.map { var h = $0; if h.id == id { change(&h) }; return h })
    }
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
        guard let cur = highlights.first(where: { $0.id == p.id }), cur.rect != p.rect else { return }
        updateHighlight(id: p.id) { $0.rect = p.rect }
    }
    public func displayedRect(of h: HighlightRegion) -> [Double] {
        if let p = highlightRectPreview, p.id == h.id { return p.rect }
        return h.rect
    }
}
