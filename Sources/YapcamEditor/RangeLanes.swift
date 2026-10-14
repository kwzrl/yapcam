import Foundation
import YapcamCore

public struct LayoutSegment: Equatable, Identifiable, Sendable {
    public var id: String
    public var startNs: Int64, endNs: Int64
    public var mode: String            // screen | camera | overlay | side_by_side
    public var cameraPosition: [Double]?
    public var cameraSize: Double?
}

public let layoutModes: [(label: String, value: String)] = [
    ("Screen only", "screen"), ("Camera only", "camera"), ("Overlay", "overlay"), ("Side by side", "side_by_side")]

/// Camera layout segments and "hide cursor" ranges live in project settings as arrays; edits
/// rewrite the whole array through `set`, which core validates and records as one undo step.
extension EditorModel {
    public var layouts: [LayoutSegment] {
        guard case .array(let rows)? = value("camera.layouts") else { return [] }
        return rows.compactMap { row in
            guard case .object(let o) = row, case .string(let id)? = o["id"], case .number(let a)? = o["tl_start_ns"],
                  case .number(let b)? = o["tl_end_ns"], case .string(let mode)? = o["mode"] else { return nil }
            var pos: [Double]?
            if case .array(let p)? = o["camera_position"] { pos = p.compactMap { if case .number(let v) = $0 { v } else { nil } } }
            var size: Double?
            if case .number(let v)? = o["camera_size"] { size = v }
            return LayoutSegment(id: id, startNs: Int64(a), endNs: Int64(b), mode: mode, cameraPosition: pos, cameraSize: size)
        }
    }

    /// Cursor ranges with `visible == false`, as (index into cursor.ranges, span).
    public var cursorHides: [(index: Int, span: TimeSpan)] {
        guard case .array(let rows)? = value("cursor.ranges") else { return [] }
        return rows.enumerated().compactMap { i, row in
            guard case .object(let o) = row, case .number(let a)? = o["tl_start_ns"], case .number(let b)? = o["tl_end_ns"] else { return nil }
            if case .bool(true)? = o["visible"] { return nil }
            return (i, TimeSpan(startNs: Int64(a), endNs: Int64(b)))
        }
    }

    private func layoutJSON(_ l: LayoutSegment) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(l.id), "tl_start_ns": .number(Double(l.startNs)),
                                      "tl_end_ns": .number(Double(l.endNs)), "mode": .string(l.mode)]
        if let p = l.cameraPosition { o["camera_position"] = .array(p.map { .number($0) }) }
        if let s = l.cameraSize { o["camera_size"] = .number(s) }
        return .object(o)
    }
    private func writeLayouts(_ ls: [LayoutSegment]) { set("camera.layouts", .array(ls.sorted { $0.startNs < $1.startNs }.map(layoutJSON))) }

    public func addLayoutAtPlayhead(mode: String = "camera") {
        guard hasCamera else { lastError = "This recording has no camera track."; return }
        let start = playheadNs, end = min(start + 3_000_000_000, durationNs)
        guard end - start >= minZoomDurationNs else { lastError = "Not enough room for a layout here."; return }
        // Overlapping segments are rejected rather than silently reordered.
        if layouts.contains(where: { $0.startNs < end && $0.endNs > start }) { lastError = "A camera layout already covers this time."; return }
        let l = LayoutSegment(id: "layout-" + UUID().uuidString.prefix(8).lowercased(), startNs: start, endNs: end, mode: mode)
        writeLayouts(layouts + [l]); selection = .layout(l.id)
    }
    public func setLayoutMode(id: String, _ mode: String) {
        writeLayouts(layouts.map { var l = $0; if l.id == id { l.mode = mode }; return l })
    }
    public func removeLayout(id: String) { writeLayouts(layouts.filter { $0.id != id }) }

    public func addCursorHideAtPlayhead() {
        let start = playheadNs, end = min(start + 2_000_000_000, durationNs)
        guard end - start >= minZoomDurationNs else { lastError = "Not enough room here."; return }
        guard case .array(let rows)? = value("cursor.ranges") ?? .array([]) else { return }
        let row: JSONValue = .object(["tl_start_ns": .number(Double(start)), "tl_end_ns": .number(Double(end)), "visible": .bool(false)])
        set("cursor.ranges", .array(rows + [row])); selection = .cursorHide(rows.count)
    }
    public func removeCursorHide(index: Int) {
        guard case .array(var rows)? = value("cursor.ranges"), rows.indices.contains(index) else { return }
        rows.remove(at: index); set("cursor.ranges", .array(rows))
    }

    // MARK: range drags (layouts and cursor-hide ranges share the zoom preview mechanism)

    public static func cursorKey(_ i: Int) -> String { "cursor:\(i)" }

    public func previewRange(key: String, current: TimeSpan, startNs: Int64? = nil, endNs: Int64? = nil, moveToStartNs: Int64? = nil) {
        var s = current.startNs, e = current.endNs
        if let m = moveToStartNs { let len = e - s; s = min(max(m, 0), max(0, durationNs - len)); e = s + len }
        else {
            if let startNs { s = max(0, min(startNs, e - minZoomDurationNs)) }
            if let endNs { e = min(durationNs, max(endNs, s + minZoomDurationNs)) }
        }
        zoomPreviewSet(key, (s, e))
    }

    public func commitRange(key: String) {
        guard let r = zoomPreviewTake(key) else { return }
        if key.hasPrefix("cursor:"), let i = Int(key.dropFirst(7)), case .array(var rows)? = value("cursor.ranges"), rows.indices.contains(i),
           case .object(var o) = rows[i] {
            o["tl_start_ns"] = .number(Double(r.start)); o["tl_end_ns"] = .number(Double(r.end)); rows[i] = .object(o)
            set("cursor.ranges", .array(rows))
        } else if layouts.contains(where: { $0.id == key }) {
            writeLayouts(layouts.map { var l = $0; if l.id == key { l.startNs = r.start; l.endNs = r.end }; return l })
        }
    }
}
