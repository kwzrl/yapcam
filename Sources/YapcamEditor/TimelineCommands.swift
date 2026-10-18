import Foundation
import YapcamCore

/// Fixed clip speeds of the reference's speed menu.
public let clipSpeedOptions: [Double] = [0.5, 0.75, 1, 1.2, 1.4, 1.6, 1.8, 2, 3, 4, 8, 16, 24]
/// Zoom levels reached by the digit keys: 1 → 1.0×, 2 → 1.2× … 9 → 2.6×; 0 → the project's default level
/// (`EditorModel.defaultZoomScale`, which core updates whenever a zoom level in 1…4 is committed).
public func zoomLevel(forDigit d: Int) -> Double { d == 0 ? 2.0 : 1.0 + 0.2 * Double(d - 1) }
public let zoomLevelRange = 1.0...4.0

/// What ⌘C copied: the settings of one timeline item, pasted onto another of the same kind with ⌘V.
public enum ItemClipboard: Equatable {
    case zoom(scale: Double, focusX: Double, focusY: Double, easeIn: Int64, easeOut: Int64, enabled: Bool)
    case clipSpeed(Double)
    case layoutMode(String)
    case region(HighlightRegion.Kind, fill: [Double], stroke: [Double], strokeWidth: Double, radius: Double, dim: Double, opacity: Double)
}

extension EditorModel {
    // MARK: speed and volume menus (S, V)

    /// The clip a speed change applies to: the selected clip, else the clip under the playhead.
    public var speedTargetClip: TimelineClip? {
        if case .clip(let id) = selection, let c = clips.first(where: { $0.id == id }) { return c }
        return clipStarts().last { $0.startNs <= playheadNs }?.clip
    }
    public func setSpeedOfTarget(_ speed: Double) { if let c = speedTargetClip { setSpeed(clipID: c.id, speed) } }
    /// One undo step for every clip.
    public func applySpeedToAll(_ speed: Double) {
        let s = min(max(speed, 0.05), 32)
        perform(.batch(clips.map { .setSpeed(clipID: $0.id, speed: s) }))
        showToast(Toast.appliedToAll(speed: s, count: clips.count))
    }

    /// Volume of the target clip's microphone or system audio in 0…100 % (0 mutes), stored as a linear amplitude on the clip.
    public func setVolume(percent: Int, system: Bool) {
        guard let c = speedTargetClip else { return }
        let p = min(max(percent, 0), 100)
        perform(.setClipSettings(clipID: c.id, patch: [system ? "system_gain" : "mic_gain": .number(Double(p) / 100)]))
    }
    public func volumePercent(system: Bool) -> Int {
        guard let c = speedTargetClip else { return 100 }
        return Int(((system ? c.systemGain : c.micGain) * 100).rounded())
    }
    /// "Hide cursor in this part" / "Disable smooth cursor movement" for the target clip.
    public func setClipCursor(hide: Bool? = nil, smoothingOff: Bool? = nil) {
        guard let c = speedTargetClip else { return }
        var patch: [String: JSONValue] = [:]
        if let hide { patch["hide_cursor"] = .bool(hide) }
        if let smoothingOff { patch["disable_smoothing"] = .bool(smoothingOff) }
        guard !patch.isEmpty else { return }
        perform(.setClipSettings(clipID: c.id, patch: patch))
    }

    // MARK: split / ripple delete (C, X)

    /// C: splits the selected zoom, camera layout or region at the playhead; with nothing like that selected, the clip.
    public func splitContextAware() {
        let ph = playheadNs
        switch selection {
        case .zoom(let id):
            guard let z = zooms.first(where: { $0.id == id }), ph - z.startNs >= minItemNs, z.endNs - ph >= minItemNs else { tooShortToSplit(); return }
            // Both halves keep style, mode, enabled state and easing; one undo step.
            perform(.batch([.updateZoom(id: id, startNs: nil, endNs: ph, scale: nil, focusX: nil, focusY: nil),
                            .insertZoomWith(startNs: ph, endNs: z.endNs, patch: zoomPatch(z))]))
        case .highlight(let id):
            guard let h = highlights.first(where: { $0.id == id }), ph - h.startNs >= minItemNs, h.endNs - ph >= minItemNs else { tooShortToSplit(); return }
            // Keyframes partition at the cut; the second half starts from the box the first one ends with.
            var (first, second) = h.split(atNs: ph)
            second.id = "region-" + UUID().uuidString.prefix(8).lowercased()
            first.id = id
            writeHighlightList(highlights.map { $0.id == id ? first : $0 } + [second])
        case .layout(let id):
            guard let l = layouts.first(where: { $0.id == id }), ph - l.startNs >= minItemNs, l.endNs - ph >= minItemNs else { tooShortToSplit(); return }
            var second = l; second.id = "layout-" + UUID().uuidString.prefix(8).lowercased(); second.startNs = ph
            var first = l; first.endNs = ph
            writeLayoutList(layouts.map { $0.id == id ? first : $0 } + [second])
        default: splitAtPlayhead()
        }
    }
    private func tooShortToSplit() { lastError = "That part would be too short to split." }

    /// X: removes the video from the previous cut up to the playhead.
    public func rippleDeleteToPreviousCut() {
        guard playheadNs > 0, playheadNs < durationNs else { lastError = "Move the playhead inside the clip first."; return }
        let previous = clipStarts().map(\.startNs).filter { $0 < playheadNs }.max() ?? 0
        guard playheadNs - previous > 0 else { return }
        let target = previous
        perform(.deleteRange(startNs: target, endNs: playheadNs))
        seek(toNs: target)
    }

    // MARK: zoom keys (A, M, D, ⌘D, 1–9, 0, =, -)

    /// The level new zooms get and the 0 key applies (`zoom_settings.default_scale`, 1…4, factory 2).
    public var defaultZoomScale: Double { min(max(number("zoom_settings.default_scale", default: 2), zoomLevelRange.lowerBound), zoomLevelRange.upperBound) }
    /// Keys and steppers change the level in quick succession: those edits are coalesced (same key within 100 ms = one undo step).
    public func setSelectedZoomLevel(_ level: Double, coalesce: Bool = false) {
        guard let z = selectedZoom else { return }
        let l = min(max(level, zoomLevelRange.lowerBound), zoomLevelRange.upperBound)
        // MKT-125: with several zooms selected (⌘/⇧-click) the level goes to all of them in one undo step.
        let ids = selectedZoomIDs
        let cmd = ids.count > 1 ? EditorCommand.batch(ids.map { .updateZoom(id: $0, startNs: nil, endNs: nil, scale: l, focusX: nil, focusY: nil) })
                                : EditorCommand.updateZoom(id: z.id, startNs: nil, endNs: nil, scale: l, focusX: nil, focusY: nil)
        perform(coalesce ? .coalesced(key: "zoom-level:\(ids.joined(separator: ","))", command: cmd) : cmd)
    }
    public func stepSelectedZoomLevel(by delta: Double) { if let z = selectedZoom { setSelectedZoomLevel(((z.scale + delta) * 10).rounded() / 10, coalesce: true) } }
    /// Everything of a zoom that a copy of it must keep (level, focus, mode, style/lens, enabled, easing).
    func zoomPatch(_ z: TimelineZoom) -> [String: JSONValue] {
        var p: [String: JSONValue] = ["scale": .number(z.scale), "target": .array([.number(z.focusX), .number(z.focusY)]), "mode": .string(z.mode.rawValue),
                                      "enabled": .bool(z.enabled), "ease_in_ns": .number(Double(z.easeInNs)), "ease_out_ns": .number(Double(z.easeOutNs))]
        if let l = z.lens { p["style"] = .string("lens"); p["lens"] = .object(["radius": .number(l.radius), "bevel": .number(l.bevel), "chromatic_aberration": .number(l.chromaticAberration)]) }
        else { p["style"] = .string("classic") }
        return p
    }
    /// The primary selected zoom first, then the ⌘/⇧-click extras that still exist (timeline order).
    var selectedZoomIDs: [String] {
        guard let z = selectedZoom else { return [] }
        return [z.id] + zooms.map(\.id).filter { extraZoomSelection.contains($0) && $0 != z.id }
    }
    /// Enable/disable: every selected zoom follows the primary one, flipped (one undo step).
    public func toggleSelectedZoomEnabled() {
        guard let z = selectedZoom else { return }
        let ids = selectedZoomIDs
        if ids.count > 1 { perform(.batch(ids.map { .updateZoom(id: $0, startNs: nil, endNs: nil, scale: nil, focusX: nil, focusY: nil, enabled: !z.enabled) })) }
        else { setZoomEnabled(id: z.id, !z.enabled) }
    }
    public func duplicateSelectedZoom() {
        guard let z = selectedZoom else { return }
        let len = z.endNs - z.startNs
        let start = min(z.endNs, max(0, durationNs - len))
        let before = Set(zooms.map(\.id))
        perform(.insertZoomWith(startNs: start, endNs: start + len, patch: zoomPatch(z)))
        if let new = zooms.first(where: { !before.contains($0.id) }) { selection = .zoom(new.id) }
    }
    /// "Apply zoom level to all other zooms" (one undo step).
    public func applyZoomLevelToAll() {
        guard let z = selectedZoom else { return }
        perform(.batch(zooms.filter { $0.id != z.id }.map { .updateZoom(id: $0.id, startNs: nil, endNs: nil, scale: z.scale, focusX: nil, focusY: nil) }))
        showToast(Toast.appliedToAll(zoomLevel: z.scale, count: zooms.count - 1))
    }

    // MARK: copy / paste settings (⌘C, ⌘V)

    /// Copies the selected item's settings; returns false when nothing copyable is selected.
    @discardableResult public func copySelectedSettings() -> Bool {
        switch selection {
        case .zoom: if let z = selectedZoom { itemClipboard = .zoom(scale: z.scale, focusX: z.focusX, focusY: z.focusY, easeIn: z.easeInNs, easeOut: z.easeOutNs, enabled: z.enabled) }
        case .clip(let id): if let c = clips.first(where: { $0.id == id }) { itemClipboard = .clipSpeed(c.speed) }
        case .layout(let id): if let l = layouts.first(where: { $0.id == id }) { itemClipboard = .layoutMode(l.mode) }
        case .highlight(let id):
            if let h = highlights.first(where: { $0.id == id }) { itemClipboard = .region(h.kind, fill: h.fill, stroke: h.stroke, strokeWidth: h.strokeWidth, radius: h.radius, dim: h.dimOpacity, opacity: h.opacity) }
        default: return false
        }
        return itemClipboard != nil
    }
    /// Pastes onto the selected item when it is of the copied kind.
    @discardableResult public func pasteSettings() -> Bool {
        guard let clip = itemClipboard else { return false }
        switch (clip, selection) {
        case (.zoom(let s, let fx, let fy, let ei, let eo, let en), .zoom(let id)):
            perform(.updateZoom(id: id, startNs: nil, endNs: nil, scale: s, focusX: fx, focusY: fy, easeInNs: ei, easeOutNs: eo, enabled: en))
        case (.clipSpeed(let v), .clip(let id)): setSpeed(clipID: id, v)
        case (.layoutMode(let m), .layout(let id)): setLayoutMode(id: id, m)
        case (.region(_, let fill, let stroke, let sw, let r, let dim, let op), .highlight(let id)):
            updateHighlight(id: id) { $0.fill = fill; $0.stroke = stroke; $0.strokeWidth = sw; $0.radius = r; $0.dimOpacity = dim; $0.opacity = op }
        default: return false
        }
        return true
    }
}

// MARK: reset trims and cuts, cut (⌘X)

extension EditorModel {
    /// Spans of the original recording that are not on the timeline, each with the timeline boundary they belong at
    /// (the end of the last clip, in timeline order, that ends at or before the gap; 0 when none).
    func trimGaps() -> [(startNs: Int64, endNs: Int64, atNs: Int64)] {
        let total = project.sourceDurationNs
        guard total > 0 else { return [] }
        let covered = clips.map { (a: $0.srcStartNs, b: $0.srcEndNs) }.sorted { $0.a < $1.a }
        var gaps: [(Int64, Int64)] = [], cursor: Int64 = 0
        for c in covered { if c.a > cursor { gaps.append((cursor, c.a)) }; cursor = max(cursor, c.b) }
        if cursor < total { gaps.append((cursor, total)) }
        let starts = clipStarts()
        return gaps.map { g in
            let before = starts.last { $0.clip.srcEndNs <= g.0 }
            return (g.0, g.1, before.map { $0.startNs + $0.clip.timelineDurationNs } ?? 0)
        }
    }
    func restoreCommands(_ gaps: [(startNs: Int64, endNs: Int64, atNs: Int64)], like template: TimelineClip?) -> [EditorCommand] {
        // Last boundary first, so earlier boundaries keep their timeline positions while clips are inserted.
        gaps.sorted { $0.atNs > $1.atNs || ($0.atNs == $1.atNs && $0.startNs > $1.startNs) }.map {
            .insertSource(startNs: $0.startNs, endNs: $0.endNs, atNs: $0.atNs, speed: template?.speed ?? 1,
                          micGain: template?.micGain ?? 1, systemGain: template?.systemGain ?? 1,
                          hideCursor: template?.hideCursor ?? false, disableSmoothing: template?.disableSmoothing ?? false)
        }
    }
    /// Whether anything of the recording is cut away.
    public var hasTrimsOrCuts: Bool { !trimGaps().isEmpty }
    /// "Reset all trims and cuts": the whole recording is back on the timeline (one undo step); other clips are untouched.
    public func resetAllTrimsAndCuts() {
        let gaps = trimGaps()
        guard !gaps.isEmpty else { return }
        perform(.batch(restoreCommands(gaps, like: nil)))
    }
    /// "Reset trim" of one clip: the cut-away parts directly before and after it come back next to it with its speed and settings.
    public func resetTrim(clipID: String) {
        guard let entry = clipStarts().first(where: { $0.clip.id == clipID }) else { return }
        let c = entry.clip, end = entry.startNs + c.timelineDurationNs
        var cmds: [(startNs: Int64, endNs: Int64, atNs: Int64)] = []
        for g in trimGaps() {
            if g.endNs == c.srcStartNs { cmds.append((g.startNs, g.endNs, entry.startNs)) }
            else if g.startNs == c.srcEndNs { cmds.append((g.startNs, g.endNs, end)) }
        }
        guard !cmds.isEmpty else { return }
        perform(.batch(restoreCommands(cmds, like: c)))
    }
    /// ⌘X: copies the selected item's settings and removes the item (one undo step); nothing selected = false.
    @discardableResult public func cutSelection() -> Bool {
        guard selection != .none, copySelectedSettings() else { return false }
        deleteSelection(); return true
    }
}
