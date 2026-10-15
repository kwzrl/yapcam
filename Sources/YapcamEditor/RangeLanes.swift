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
        } else if let t = textItem(key: key) {
            updateText(t.kind, id: t.id) { $0.startNs = r.start; $0.endNs = r.end }
        } else if music.contains(where: { $0.id == key }) {
            commitMusicSpan(id: key, start: r.start, end: r.end)
        } else if highlights.contains(where: { $0.id == key }) {
            updateHighlight(id: key) { $0.startNs = r.start; $0.endNs = r.end }
        } else if layouts.contains(where: { $0.id == key }) {
            writeLayouts(layouts.map { var l = $0; if l.id == key { l.startNs = r.start; l.endNs = r.end }; return l })
        }
    }
}

public struct AudioRangeRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var track: String            // mic | system_audio
    public var span: TimeSpan
    public var startGainDb: Double, endGainDb: Double
}

/// Volume-over-time ("ducking") ranges: gain ramps linearly from start to end gain across the span.
extension EditorModel {
    public var audioRanges: [AudioRangeRow] {
        guard case .array(let rows)? = value("audio.ranges") else { return [] }
        return rows.compactMap { row in
            guard case .object(let o) = row, case .string(let id)? = o["id"], case .string(let track)? = o["track"],
                  case .number(let a)? = o["tl_start_ns"], case .number(let b)? = o["tl_end_ns"],
                  case .number(let g0)? = o["start_gain_db"], case .number(let g1)? = o["end_gain_db"] else { return nil }
            return AudioRangeRow(id: id, track: track, span: TimeSpan(startNs: Int64(a), endNs: Int64(b)), startGainDb: g0, endGainDb: g1)
        }
    }
    private func write(_ rows: [AudioRangeRow]) {
        set("audio.ranges", .array(rows.map { r in
            .object(["id": .string(r.id), "track": .string(r.track), "tl_start_ns": .number(Double(r.span.startNs)),
                     "tl_end_ns": .number(Double(r.span.endNs)), "start_gain_db": .number(r.startGainDb), "end_gain_db": .number(r.endGainDb)])
        }))
    }
    public func addAudioRangeAtPlayhead(track: String, gainDb: Double = -12) {
        let end = min(playheadNs + 3_000_000_000, durationNs)
        guard end - playheadNs >= minZoomDurationNs else { lastError = "Not enough room here."; return }
        let r = AudioRangeRow(id: "audio-" + UUID().uuidString.prefix(8).lowercased(), track: track,
                              span: TimeSpan(startNs: playheadNs, endNs: end), startGainDb: gainDb, endGainDb: gainDb)
        write(audioRanges + [r])
    }
    public func updateAudioRange(id: String, startGainDb: Double? = nil, endGainDb: Double? = nil, span: TimeSpan? = nil) {
        write(audioRanges.map { var r = $0
            if r.id == id {
                if let startGainDb { r.startGainDb = min(max(startGainDb, -96), 24) }
                if let endGainDb { r.endGainDb = min(max(endGainDb, -96), 24) }
                if let span, span.durationNs >= minZoomDurationNs { r.span = span }
            }
            return r })
    }
    public func removeAudioRange(id: String) { write(audioRanges.filter { $0.id != id }) }

    /// Crop of the recorded screen as insets (fractions of the source) → `canvas.crop` [x, y, w, h].
    public var cropInsets: (left: Double, top: Double, right: Double, bottom: Double) {
        let c = numbers("canvas.crop")
        guard c.count == 4 else { return (0, 0, 0, 0) }
        return (c[0], c[1], 1 - c[0] - c[2], 1 - c[1] - c[3])
    }
    public func setCrop(left: Double, top: Double, right: Double, bottom: Double) {
        let l = min(max(left, 0), 0.9), t = min(max(top, 0), 0.9)
        let r = min(max(right, 0), 0.9 - l), b = min(max(bottom, 0), 0.9 - t)
        set("canvas.crop", color: [l, t, 1 - l - r, 1 - t - b])    // `color` writes a 4-number array
    }
}
