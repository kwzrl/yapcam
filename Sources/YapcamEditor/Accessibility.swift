import Foundation
import AppKit

/// One thing on the timeline that can be selected, in a form usable without a pointer (VoiceOver, keyboard).
public struct SelectableItem: Equatable, Sendable {
    public var selection: EditorSelection
    public var startNs: Int64, endNs: Int64
    public var label: String
    /// Key used by the range-drag machinery (nil for clips, zooms use their id).
    public var rangeKey: String?
}

extension EditorModel {
    /// Everything selectable, ordered by start time (ties by lane order), for Up/Down navigation and VoiceOver.
    public var selectableItems: [SelectableItem] {
        var out: [(order: Int, item: SelectableItem)] = []
        for (i, e) in clipStarts().enumerated() {
            out.append((0, SelectableItem(selection: .clip(e.clip.id), startNs: e.startNs, endNs: e.startNs + e.clip.timelineDurationNs,
                                          label: "Clip \(i + 1)\(e.clip.speed == 1 ? "" : String(format: ", %.2g× speed", e.clip.speed))", rangeKey: nil)))
        }
        for z in zooms {
            out.append((1, SelectableItem(selection: .zoom(z.id), startNs: z.startNs, endNs: z.endNs,
                                          label: String(format: "Zoom %.1f×", z.scale) + (z.mode == .auto ? ", automatic" : ""), rangeKey: z.id)))
        }
        for l in layouts { out.append((2, SelectableItem(selection: .layout(l.id), startNs: l.startNs, endNs: l.endNs, label: "Camera layout, " + (layoutModes.first { $0.value == l.mode }?.label ?? l.mode), rangeKey: l.id))) }
        for h in cursorHides { out.append((3, SelectableItem(selection: .cursorHide(h.index), startNs: h.span.startNs, endNs: h.span.endNs, label: "Cursor hidden", rangeKey: Self.cursorKey(h.index)))) }
        for h in highlights { out.append((4, SelectableItem(selection: .highlight(h.id), startNs: h.startNs, endNs: h.endNs, label: h.kind.label + " region", rangeKey: h.id))) }
        for t in allText { out.append((5, SelectableItem(selection: .text(t.kind, t.id), startNs: t.startNs, endNs: t.endNs, label: "\(t.kind.label): \(t.text)", rangeKey: Self.textKey(t)))) }
        for m in music { out.append((6, SelectableItem(selection: .music(m.id), startNs: m.startNs, endNs: m.endNs, label: "Music: \(m.title)", rangeKey: m.id))) }
        return out.sorted { ($0.item.startNs, $0.order) < ($1.item.startNs, $1.order) }.map(\.item)
    }

    public func describe(_ selection: EditorSelection) -> String {
        guard let item = selectableItems.first(where: { $0.selection == selection }) else { return "Nothing selected" }
        return "\(item.label), \(formatTimecode(item.startNs)) to \(formatTimecode(item.endNs))"
    }
    public var selectionDescription: String { describe(selection) }

    /// Up/Down: select the next/previous item in time order; wraps around. Seeks to its start so the preview shows it.
    @discardableResult
    public func selectAdjacent(forward: Bool) -> Bool {
        let items = selectableItems
        guard !items.isEmpty else { return false }
        let current = items.firstIndex { $0.selection == selection }
        let next: Int
        if let current { next = (current + (forward ? 1 : -1) + items.count) % items.count }
        else { next = forward ? (items.firstIndex { $0.startNs >= playheadNs } ?? 0) : (items.lastIndex { $0.startNs <= playheadNs } ?? items.count - 1) }
        selection = items[next].selection; extraZoomSelection = []
        seek(toNs: items[next].startNs)
        return true
    }

    /// Option+Left/Right: playhead to the previous/next edit point (project start/end, clip, zoom and overlay edges, clicks).
    @discardableResult
    public func jumpToEditPoint(forward: Bool) -> Bool {
        var points = Set<Int64>([0, durationNs])
        for i in selectableItems { points.insert(i.startNs); points.insert(i.endNs) }
        points.formUnion(project.clickTimesNs); points.formUnion(project.markerTimesNs)
        let sorted = points.filter { $0 >= 0 && $0 <= durationNs }.sorted()
        let target = forward ? sorted.first { $0 > playheadNs } : sorted.last { $0 < playheadNs }
        guard let target else { return false }
        seek(toNs: target); return true
    }

    /// Control+Left/Right: move the selected zoom/overlay/music item in time without dragging.
    public func nudgeSelection(byNs delta: Int64) {
        guard let item = selectableItems.first(where: { $0.selection == selection }), let key = item.rangeKey else { return }
        let span = TimeSpan(startNs: item.startNs, endNs: item.endNs)
        if case .zoom(let id) = selection { moveZoom(id: id, toStartNs: item.startNs + delta); return }   // zooms: one discrete step per nudge
        previewRange(key: key, current: span, moveToStartNs: item.startNs + delta); commitRange(key: key)
    }

    /// Spoken by VoiceOver when selection changes.
    public func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
