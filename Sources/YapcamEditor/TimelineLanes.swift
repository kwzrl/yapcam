import AppKit
import SwiftUI
import YapcamDesign

/// Which overlay lanes the timeline shows (CAM-22, S-EDT-36/37/85). A lane shows when it has content (the camera lane whenever
/// the recording has a camera), unless the user hid it; a lane the user shows stays even when empty. Choices are per user.
struct LaneVisibility: Equatable {
    var shown: Set<String> = [], hidden: Set<String> = []

    /// Menu order and the number key that toggles each lane (1 is the zoom track, which is always there).
    static let menu: [(lane: TimelineLane, title: String, key: Character)] = [
        (.camera, "Layouts", "2"), (.typing, "Shortcuts", "3"), (.highlight, "Masks", "4"), (.text, "Text", "5"),
        (.caption, "Captions", "6"), (.music, "Music", "7"), (.cursor, "Cursor", "8")]
    static func lane(forKey k: Character) -> TimelineLane? { menu.first { $0.key == k }?.lane }

    func visible(contentLanes: [TimelineLane]) -> [TimelineLane] {
        TimelineLane.allCases.filter { l in !hidden.contains(l.rawValue) && (shown.contains(l.rawValue) || contentLanes.contains(l)) }
    }
    mutating func set(_ lane: TimelineLane, visible: Bool) {
        if visible { shown.insert(lane.rawValue); hidden.remove(lane.rawValue) } else { hidden.insert(lane.rawValue); shown.remove(lane.rawValue) }
    }
    mutating func show(_ lane: TimelineLane) { set(lane, visible: true) }
}

extension EditorModel {
    /// Lanes that have something to show (the camera lane always, when there is a camera, so layouts can be added by clicking).
    var contentLanes: [TimelineLane] {
        var out: [TimelineLane] = []
        if !typingSuggestions.isEmpty { out.append(.typing) }
        if hasCamera || !layouts.isEmpty { out.append(.camera) }
        if !cursorHides.isEmpty { out.append(.cursor) }
        if !highlights.isEmpty { out.append(.highlight) }
        if !textItems(.annotation).isEmpty || !textItems(.reaction).isEmpty { out.append(.text) }
        if !textItems(.caption).isEmpty { out.append(.caption) }
        if !music.isEmpty { out.append(.music) }
        return out
    }
    var visibleLanes: [TimelineLane] { laneVisibility.visible(contentLanes: contentLanes) }
    var visibleLaneCount: Int { 1 + visibleLanes.count }                       // the zoom track counts

    func setLane(_ lane: TimelineLane, visible: Bool) {
        laneVisibility.set(lane, visible: visible)
        defaults.set(Array(laneVisibility.shown).sorted(), forKey: "editor.lanes.shown")
        defaults.set(Array(laneVisibility.hidden).sorted(), forKey: "editor.lanes.hidden")
    }
    func toggleLane(_ lane: TimelineLane) { setLane(lane, visible: !visibleLanes.contains(lane)) }
    func loadLaneVisibility() {
        laneVisibility = LaneVisibility(shown: Set(defaults.stringArray(forKey: "editor.lanes.shown") ?? []),
                                        hidden: Set(defaults.stringArray(forKey: "editor.lanes.hidden") ?? []))
    }
    /// The Mask button above the preview and key 4: shows the masks lane and adds a mask at the playhead.
    func showMasksAndAddAtPlayhead() { setLane(.highlight, visible: true); addHighlightAtPlayhead() }

    /// Layout drawn by clicking (3 s) or dragging on the Layouts lane: clamped to the free gap instead of rejected.
    func addLayout(fromNs a: Int64, toNs b: Int64? = nil, mode: String = "camera") {
        guard hasCamera else { lastError = "This recording has no camera track."; return }
        guard let (s, e) = Self.freeSpan(from: a, to: b, defaultLength: 3_000_000_000, durationNs: durationNs,
                                         others: layouts.map { ($0.startNs, $0.endNs) }, minNs: minItemNs) else {
            lastError = "A camera layout already covers this time."; return
        }
        let l = LayoutSegment(id: "layout-" + UUID().uuidString.prefix(8).lowercased(), startNs: s, endNs: e, mode: mode)
        writeLayoutList(layouts + [l]); selection = .layout(l.id)
    }
    /// Mask drawn by clicking (3 s) or dragging on the Masks lane.
    func addHighlight(fromNs a: Int64, toNs b: Int64? = nil, kind: HighlightRegion.Kind = .highlight) {
        let s0 = max(0, min(a, durationNs)), e0 = b.map { max(0, min($0, durationNs)) } ?? min(s0 + 3_000_000_000, durationNs)
        let (s, e) = (min(s0, e0), max(s0, e0))
        guard e - s >= minItemNs else { lastError = "Not enough room for a region here."; return }
        var h = HighlightRegion.preset(kind, id: "region-" + UUID().uuidString.prefix(8).lowercased(), start: s, end: e)
        if let last = lastRegionStyle, last.kind == kind { h.fill = last.fill; h.stroke = last.stroke; h.strokeWidth = last.strokeWidth; h.radius = last.radius; h.dimOpacity = last.dimOpacity; h.opacity = last.opacity; h.blurRadius = last.blurRadius }
        writeHighlightList(highlights + [h]); selection = .highlight(h.id)
    }

    /// The span a click (default length) or drag may take without overlapping `others`; nil when the start itself is taken.
    static func freeSpan(from a: Int64, to b: Int64?, defaultLength: Int64, durationNs: Int64, others: [(Int64, Int64)], minNs: Int64) -> (Int64, Int64)? {
        let s0 = max(0, min(a, durationNs)), e0 = b.map { max(0, min($0, durationNs)) } ?? min(s0 + defaultLength, durationNs)
        var s = min(s0, e0), e = max(s0, e0)
        let forward = b == nil || b! >= a
        // The anchor (where the pointer went down) must be free; the far end stops at the next item in the drag direction.
        if forward {
            if others.contains(where: { $0.0 <= s && s < $0.1 }) { return nil }
            if let n = others.filter({ $0.0 >= s && $0.0 < e }).map(\.0).min() { e = n }
        } else {
            if others.contains(where: { $0.0 < e && e <= $0.1 }) { return nil }
            if let p = others.filter({ $0.1 > s && $0.1 <= e }).map(\.1).max() { s = p }
        }
        return e - s >= minNs ? (s, e) : nil
    }
}

extension EditorModel {
    /// ⌥ held alone turns the cut tool on for as long as it is held; releasing restores what it was (S-EDT-19).
    func optionHeld(_ down: Bool) {
        if down {
            guard optionRestoresCutTool == nil else { return }
            optionRestoresCutTool = cutToolActive; cutToolActive = true
        } else if let was = optionRestoresCutTool {
            optionRestoresCutTool = nil; cutToolActive = was
        }
    }
    /// Whether the modifier state means "⌥ alone".
    static func isOptionAlone(_ flags: NSEvent.ModifierFlags) -> Bool {
        let f = flags.intersection([.command, .control, .option, .shift])
        return f == .option
    }
}

/// "N visible timelines": a menu with a check per lane.
struct LaneMenu: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        Menu {
            Text("Zooms").foregroundStyle(.secondary)
            ForEach(LaneVisibility.menu, id: \.lane) { item in
                Button { model.toggleLane(item.lane) } label: {
                    if model.visibleLanes.contains(item.lane) { Label("\(item.title)  \(item.key)", systemImage: "checkmark") } else { Text("\(item.title)  \(item.key)") }
                }
            }
        } label: {
            Text("\(model.visibleLaneCount) timelines").font(.system(size: 11, weight: .medium)).foregroundStyle(Yap.faint)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Choose which timelines are shown (keys 2–8)")
        .accessibilityLabel("Visible timelines")
    }
}

/// Where the playhead was when a project was closed, remembered per project (MKT-201 follow-up: reopen where you were).
enum PlayheadMemory {
    static let key = "editor.playheads", limit = 50
    static func restore(path: String, durationNs: Int64, defaults: UserDefaults) -> Int64? {
        guard let d = defaults.dictionary(forKey: key), let v = (d[path] as? NSNumber)?.int64Value else { return nil }
        // Back at the very end means "done": start from the beginning again.
        return v > 0 && v < durationNs - 200_000_000 ? v : nil
    }
    static func remember(path: String, ns: Int64, defaults: UserDefaults) {
        var d = defaults.dictionary(forKey: key) ?? [:]
        d[path] = NSNumber(value: ns)
        if d.count > limit { for k in d.keys.sorted().prefix(d.count - limit) where k != path { d.removeValue(forKey: k) } }
        defaults.set(d, forKey: key)
    }
}

extension EditorModel {
    func restorePlayhead() {
        guard let path = playheadMemoryPath, let ns = PlayheadMemory.restore(path: path, durationNs: durationNs, defaults: defaults) else { return }
        seek(toNs: ns)
    }
    func rememberPlayhead() {
        guard let path = playheadMemoryPath else { return }
        PlayheadMemory.remember(path: path, ns: playheadNs, defaults: defaults)
    }
}
