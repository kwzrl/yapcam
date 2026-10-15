import Foundation
import YapcamCore

/// Fixed clip speeds of the reference's speed menu.
public let clipSpeedOptions: [Double] = [0.5, 0.75, 1, 1.2, 1.4, 1.6, 1.8, 2, 3, 4, 8, 16, 24]
/// Zoom levels reached by the digit keys: 1 → 1.0×, 2 → 1.2× … 9 → 2.6×; 0 → the default level.
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
    }

    /// Microphone / system-audio volume in 0…100 % (0 mutes); stored as dB gain plus the mute flag.
    public func setVolume(percent: Int, system: Bool) {
        let p = min(max(percent, 0), 100)
        let prefix = system ? "audio.system" : "audio.mic"
        var cmds: [EditorCommand] = [.set(path: "\(prefix)_muted", value: .bool(p == 0))]
        if p > 0 { cmds.append(.set(path: "\(prefix)_gain_db", value: .number(20 * log10(Double(p) / 100)))) }
        perform(.batch(cmds))
    }
    public func volumePercent(system: Bool) -> Int {
        let prefix = system ? "audio.system" : "audio.mic"
        if bool("\(prefix)_muted") { return 0 }
        return Int((pow(10, number("\(prefix)_gain_db") / 20) * 100).rounded())
    }

    // MARK: split / ripple delete (C, X)

    /// C: splits the selected zoom, camera layout or region at the playhead; with nothing like that selected, the clip.
    public func splitContextAware() {
        let ph = playheadNs
        switch selection {
        case .zoom(let id):
            guard let z = zooms.first(where: { $0.id == id }), ph - z.startNs >= minItemNs, z.endNs - ph >= minItemNs else { tooShortToSplit(); return }
            perform(.batch([.updateZoom(id: id, startNs: nil, endNs: ph, scale: nil, focusX: nil, focusY: nil),
                            .addZoom(startNs: ph, endNs: z.endNs, scale: z.scale, focusX: z.focusX, focusY: z.focusY)]))
        case .highlight(let id):
            guard let h = highlights.first(where: { $0.id == id }), ph - h.startNs >= minItemNs, h.endNs - ph >= minItemNs else { tooShortToSplit(); return }
            var second = h; second.id = "region-" + UUID().uuidString.prefix(8).lowercased(); second.startNs = ph
            var first = h; first.endNs = ph
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

    public func setSelectedZoomLevel(_ level: Double) {
        guard let z = selectedZoom else { return }
        setZoomScale(id: z.id, min(max(level, zoomLevelRange.lowerBound), zoomLevelRange.upperBound))
    }
    public func stepSelectedZoomLevel(by delta: Double) { if let z = selectedZoom { setSelectedZoomLevel(((z.scale + delta) * 10).rounded() / 10) } }
    public func toggleSelectedZoomEnabled() { if let z = selectedZoom { setZoomEnabled(id: z.id, !z.enabled) } }
    public func duplicateSelectedZoom() {
        guard let z = selectedZoom else { return }
        let len = z.endNs - z.startNs
        let start = min(z.endNs, max(0, durationNs - len))
        let before = Set(zooms.map(\.id))
        perform(.addZoom(startNs: start, endNs: start + len, scale: z.scale, focusX: z.focusX, focusY: z.focusY))
        if let new = zooms.first(where: { !before.contains($0.id) }) { selection = .zoom(new.id) }
    }
    /// "Apply zoom level to all other zooms" (one undo step).
    public func applyZoomLevelToAll() {
        guard let z = selectedZoom else { return }
        perform(.batch(zooms.filter { $0.id != z.id }.map { .updateZoom(id: $0.id, startNs: nil, endNs: nil, scale: z.scale, focusX: nil, focusY: nil) }))
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
