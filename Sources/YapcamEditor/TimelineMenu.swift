import AppKit
import SwiftUI
import YapcamCore

/// Context menus of the timeline (S-EDT-21/22, BS-6, CAM-54/55). Pure part: what was clicked (`TimelineClick.menuTarget`),
/// which entries that gives (`TimelineMenu.entries`) and what each entry does (`TimelineMenu.Action.apply`).
enum TimelineMenu {
    enum Target: Equatable {
        case clip(id: String, atNs: Int64)
        case zoom(id: String)
        case layout(id: String), highlight(id: String), text(TextKind, id: String), music(id: String), cursorHide(Int)
        case empty(atNs: Int64)
    }
    enum VolumeTrack: Equatable { case both, mic, system }

    enum Action: Equatable {
        case clipSpeed(id: String, Double), speedToAll(Double)
        case clipVolume(id: String, percent: Int, VolumeTrack)
        case removeClip(id: String), splitClip(id: String, atNs: Int64), resetTrim(id: String), resetAllTrims
        case clipHideCursor(id: String, Bool), clipSmoothingOff(id: String, Bool)
        case removeZoom(id: String), duplicateZoom(id: String), zoomEnabled(id: String, Bool), zoomLevel(id: String, Double)
        case allZoomsEnabled(Bool), restoreAutoZooms, removeAllZooms
        case duplicate(EditorSelection), setEnabled(EditorSelection, Bool), delete(EditorSelection), focusStart(EditorSelection)
        case pasteSettings, addZoom(atNs: Int64)
    }

    struct Entry: Equatable {
        var title: String
        var action: Action?
        var checked = false
        var enabled = true
        var shortcut: String?
        var children: [Entry] = []
        var isSeparator = false
        static let separator = Entry(title: "", action: nil, isSeparator: true)
    }

    static let zoomLevels: [Double] = [1, 1.2, 1.4, 1.6, 1.8, 2, 2.2, 2.4, 2.6, 3, 4]
    static let volumeSteps = [100, 90, 80, 70, 60, 50, 40, 30, 20, 10, 0]

    @MainActor static func entries(for t: Target, in m: EditorModel) -> [Entry] {
        switch t {
        case .clip(let id, let ns): return clipEntries(id: id, atNs: ns, m)
        case .zoom(let id): return zoomEntries(id: id, m)
        case .layout(let id): return rangeEntries(.layout(id), enabled: m.layouts.first { $0.id == id }?.enabled, duplicable: true)
        case .highlight(let id): return rangeEntries(.highlight(id), enabled: m.highlights.first { $0.id == id }?.enabled, duplicable: true, focus: true)
        case .text(let kind, let id): return rangeEntries(.text(kind, id), enabled: nil, duplicable: kind != .caption)
        case .music(let id): return rangeEntries(.music(id), enabled: nil, duplicable: false)
        case .cursorHide(let i): return rangeEntries(.cursorHide(i), enabled: nil, duplicable: false)
        case .empty(let ns):
            return [Entry(title: "Paste Settings", action: .pasteSettings, enabled: m.itemClipboard != nil, shortcut: "⌘V"),
                    Entry(title: "Add Zoom Here", action: .addZoom(atNs: ns), enabled: ns >= 0 && ns < m.durationNs)]
        }
    }

    private static func rangeEntries(_ sel: EditorSelection, enabled: Bool?, duplicable: Bool, focus: Bool = false) -> [Entry] {
        var out: [Entry] = []
        if duplicable { out.append(Entry(title: "Duplicate", action: .duplicate(sel))) }
        if let enabled { out.append(Entry(title: "Disable", action: .setEnabled(sel, !enabled), checked: !enabled)) }
        if focus { out.append(Entry(title: "Focus Timeline on Start", action: .focusStart(sel))) }
        if !out.isEmpty { out.append(.separator) }
        out.append(Entry(title: "Delete", action: .delete(sel), shortcut: "⌫"))
        return out
    }

    @MainActor private static func zoomEntries(id: String, _ m: EditorModel) -> [Entry] {
        guard let z = m.zooms.first(where: { $0.id == id }) else { return [] }
        let levels = zoomLevels.map { l in
            Entry(title: String(format: l == l.rounded() ? "%.0f×" : "%.1f×", l), action: .zoomLevel(id: id, l), checked: abs(z.scale - l) < 0.05)
        }
        return [Entry(title: "Remove", action: .removeZoom(id: id), shortcut: "⌫"),
                Entry(title: "Duplicate", action: .duplicateZoom(id: id), shortcut: "⌘D"),
                Entry(title: "Disable", action: .zoomEnabled(id: id, !z.enabled), checked: !z.enabled, shortcut: "D"),
                Entry(title: "Set Zoom Level", action: nil, children: levels),
                .separator,
                Entry(title: "Disable All", action: .allZoomsEnabled(false), enabled: m.zooms.contains { $0.enabled }),
                Entry(title: "Enable All", action: .allZoomsEnabled(true), enabled: m.zooms.contains { !$0.enabled }),
                .separator,
                Entry(title: "Restore Automatic Zooms", action: .restoreAutoZooms, enabled: m.hasMouseData),
                Entry(title: "Remove All Zooms", action: .removeAllZooms)]
    }

    @MainActor private static func clipEntries(id: String, atNs ns: Int64, _ m: EditorModel) -> [Entry] {
        guard let c = m.clips.first(where: { $0.id == id }) else { return [] }
        var speeds = clipSpeedOptions.map { Entry(title: $0 == 1 ? "1× (normal)" : clipSpeedLabel($0), action: .clipSpeed(id: id, $0), checked: abs(c.speed - $0) < 0.001) }
        speeds += [.separator, Entry(title: "Apply \(clipSpeedLabel(c.speed)) to All Clips", action: .speedToAll(c.speed), enabled: m.clips.count > 1)]
        func volume(_ track: VolumeTrack, _ title: String) -> Entry {
            let current: Int? = {
                let mic = Int((c.micGain * 100).rounded()), sys = Int((c.systemGain * 100).rounded())
                switch track { case .mic: return mic; case .system: return sys; case .both: return mic == sys ? mic : nil }
            }()
            let kids = volumeSteps.map { Entry(title: $0 == 0 ? "Muted" : "\($0) %", action: .clipVolume(id: id, percent: $0, track), checked: current == $0) }
            return Entry(title: title, action: nil, children: kids)
        }
        var out = [Entry(title: "Set Speed", action: nil, children: speeds), volume(.both, "Set Volume")]
        if m.hasMic { out += [volume(.mic, "Microphone Volume"), volume(.system, "System Audio Volume")] }
        out += [.separator,
                Entry(title: "Remove", action: .removeClip(id: id), enabled: m.clips.count > 1, shortcut: "⌫"),
                .separator,
                Entry(title: "Split Here", action: .splitClip(id: id, atNs: ns), enabled: m.canSplit(clipID: id, atNs: ns), shortcut: "C"),
                Entry(title: "Reset Trim", action: .resetTrim(id: id), enabled: m.hasTrim(clipID: id)),
                Entry(title: "Reset All Trims and Cuts", action: .resetAllTrims, enabled: m.hasTrimsOrCuts)]
        if m.hasMouseData {
            out += [.separator,
                    Entry(title: "Hide Cursor", action: .clipHideCursor(id: id, !c.hideCursor), checked: c.hideCursor),
                    Entry(title: "Disable Smooth Cursor Movement", action: .clipSmoothingOff(id: id, !c.disableSmoothing), checked: c.disableSmoothing)]
        }
        return out
    }
}

extension TimelineClick {
    /// What a secondary click at `i.point` is on. Pure and side-effect free (unlike `begin`); nil on the ruler.
    static func menuTarget(_ i: Input) -> TimelineMenu.Target? {
        let p = i.point, g = i.geometry, l = i.layout
        guard p.x.isFinite, p.y.isFinite, p.y >= l.clipTop else { return nil }
        let ns = g.ns(forX: p.x)
        if p.y >= l.lanesTop {
            guard let hit = LaneHitTest.topmost(x: p.x, y: p.y, items: i.rangeItems, preview: i.rangePreview, geometry: g) else { return .empty(atNs: ns) }
            switch hit.tag {
            case .layout(let id): return .layout(id: id)
            case .highlight(let id): return .highlight(id: id)
            case .text(let k, let id): return .text(k, id: id)
            case .music(let id): return .music(id: id)
            case .cursorHide(let n): return .cursorHide(n)
            default: return .empty(atNs: ns)
            }
        }
        if p.y >= l.zoomTop {
            if let z = i.zooms.last(where: { p.x >= g.x(forNs: $0.startNs) - 2 && p.x <= g.x(forNs: $0.endNs) + 2 }) { return .zoom(id: z.id) }
            return .empty(atNs: ns)
        }
        if p.y < l.zoomTop - TimelineLayout.gap, let c = i.clips.first(where: { p.x >= g.x(forNs: $0.startNs) && p.x < g.x(forNs: $0.endNs) }) {
            return .clip(id: c.id, atNs: ns)
        }
        return .empty(atNs: ns)
    }
}

extension EditorModel {
    /// Splitting a clip at a time needs the time strictly inside the clip with `minItemNs` left on both sides.
    func canSplit(clipID: String, atNs ns: Int64) -> Bool {
        guard let e = clipStarts().first(where: { $0.clip.id == clipID }) else { return false }
        return ns - e.startNs >= minItemNs && e.startNs + e.clip.timelineDurationNs - ns >= minItemNs
    }
    /// S-EDT-21 "Split": at the click time, not the playhead; two clips meet at `ns` (one undo step).
    public func contextSplit(clipID: String, atNs ns: Int64) {
        guard canSplit(clipID: clipID, atNs: ns) else { lastError = "That part would be too short to split."; return }
        perform(.split(atNs: ns))
    }
    /// Whether cut-away source touches this clip (so "Reset trim" would bring something back).
    func hasTrim(clipID: String) -> Bool {
        guard let c = clips.first(where: { $0.id == clipID }) else { return false }
        return trimGaps().contains { $0.endNs == c.srcStartNs || $0.startNs == c.srcEndNs }
    }
    /// CAM-54/55: one undo step; "both" scales microphone and system audio together (without a microphone only system audio).
    func setClipVolume(clipID: String, percent: Int, track: TimelineMenu.VolumeTrack) {
        guard clips.contains(where: { $0.id == clipID }) else { return }
        let v = JSONValue.number(Double(min(max(percent, 0), 100)) / 100)
        var patch: [String: JSONValue] = [:]
        if track != .system && (hasMic || track == .mic) { patch["mic_gain"] = v }
        if track != .mic { patch["system_gain"] = v }
        perform(.setClipSettings(clipID: clipID, patch: patch))
    }
    public func setClipCursor(clipID: String, hide: Bool? = nil, smoothingOff: Bool? = nil) {
        guard clips.contains(where: { $0.id == clipID }) else { return }
        var patch: [String: JSONValue] = [:]
        if let hide { patch["hide_cursor"] = .bool(hide) }
        if let smoothingOff { patch["disable_smoothing"] = .bool(smoothingOff) }
        if !patch.isEmpty { perform(.setClipSettings(clipID: clipID, patch: patch)) }
    }
    public func setAllZoomsEnabled(_ on: Bool) {
        let cmds = zooms.filter { $0.enabled != on }.map { EditorCommand.updateZoom(id: $0.id, startNs: nil, endNs: nil, scale: nil, focusX: nil, focusY: nil, enabled: on) }
        if !cmds.isEmpty { perform(.batch(cmds)) }
    }
    public func removeAllZooms() {
        guard !zooms.isEmpty else { return }
        perform(.batch(zooms.map { .removeZoom(id: $0.id) })); selection = .none; extraZoomSelection = []
    }
    /// Copies a mask, layout or text item right after itself (new id, same length, moved to the next free time when it would overrun).
    public func duplicateItem(_ sel: EditorSelection) {
        func shifted(_ s: Int64, _ e: Int64) -> (Int64, Int64) {
            let len = e - s, start = min(e, max(0, durationNs - len)); return (start, start + len)
        }
        switch sel {
        case .highlight(let id):
            guard var h = highlights.first(where: { $0.id == id }) else { return }
            let (s, e) = shifted(h.startNs, h.endNs); h = h.retimed(startNs: s, endNs: e); h.id = "region-" + UUID().uuidString.prefix(8).lowercased()
            writeHighlightList(highlights + [h]); selection = .highlight(h.id)
        case .layout(let id):
            guard var l = layouts.first(where: { $0.id == id }) else { return }
            let (s, e) = shifted(l.startNs, l.endNs); l.startNs = s; l.endNs = e; l.id = "layout-" + UUID().uuidString.prefix(8).lowercased()
            writeLayoutList(layouts + [l]); selection = .layout(l.id)
        case .text(let kind, let id):
            guard kind != .caption, var t = textItems(kind).first(where: { $0.id == id }) else { return }
            let (s, e) = shifted(t.startNs, t.endNs); t.startNs = s; t.endNs = e; t.id = "text-" + UUID().uuidString.prefix(8).lowercased()
            writeTextList(kind, textItems(kind) + [t]); selection = .text(kind, t.id)
        default: break
        }
    }
    func startNs(of sel: EditorSelection) -> Int64? {
        switch sel {
        case .highlight(let id): highlights.first { $0.id == id }?.startNs
        case .layout(let id): layouts.first { $0.id == id }?.startNs
        default: nil
        }
    }

    /// Runs a menu entry. Item-based actions select the item first, like the click that opened the menu.
    func apply(_ a: TimelineMenu.Action) {
        switch a {
        case .clipSpeed(let id, let s): setSpeed(clipID: id, s)
        case .speedToAll(let s): applySpeedToAll(s)
        case .clipVolume(let id, let p, let t): setClipVolume(clipID: id, percent: p, track: t)
        case .removeClip(let id): selection = .clip(id); deleteSelection()
        case .splitClip(let id, let ns): contextSplit(clipID: id, atNs: ns)
        case .resetTrim(let id): resetTrim(clipID: id)
        case .resetAllTrims: resetAllTrimsAndCuts()
        case .clipHideCursor(let id, let on): setClipCursor(clipID: id, hide: on)
        case .clipSmoothingOff(let id, let on): setClipCursor(clipID: id, smoothingOff: on)
        case .removeZoom(let id): selection = .zoom(id); extraZoomSelection = []; deleteSelection()
        case .duplicateZoom(let id): selection = .zoom(id); duplicateSelectedZoom()
        case .zoomEnabled(let id, let on): setZoomEnabled(id: id, on)
        case .zoomLevel(let id, let l): setZoomScale(id: id, l)
        case .allZoomsEnabled(let on): setAllZoomsEnabled(on)
        case .restoreAutoZooms: regenerateAutoZooms()
        case .removeAllZooms: removeAllZooms()
        case .duplicate(let sel): duplicateItem(sel)
        case .setEnabled(let sel, let on):
            switch sel {
            case .highlight(let id): setHighlightEnabled(id: id, on)
            case .layout(let id): setLayoutEnabled(id: id, on)
            default: break
            }
        case .delete(let sel): selection = sel; deleteSelection()
        case .focusStart(let sel): if let ns = startNs(of: sel) { selection = sel; seek(toNs: ns) }
        case .pasteSettings: pasteSettings()
        case .addZoom(let ns): addZoom(fromNs: ns)
        }
    }
}

// MARK: AppKit host

/// Transparent overlay that only answers secondary clicks (and ⌃-click), so ordinary clicks and drags reach the SwiftUI gesture
/// underneath. SwiftUI's `.contextMenu` cannot know where in a chip the click landed; `menu(for:)` here does.
struct TimelineContextMenuHost: NSViewRepresentable {
    /// Called with the click point (timeline-content coordinates); returns the menu to show, after selecting what was hit.
    var menuAt: @MainActor (CGPoint) -> NSMenu?

    func makeNSView(context: Context) -> HostView { let v = HostView(); v.menuAt = menuAt; return v }
    func updateNSView(_ v: HostView, context: Context) { v.menuAt = menuAt }

    final class HostView: NSView {
        var menuAt: (@MainActor (CGPoint) -> NSMenu?)?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let secondary = e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            let p = convert(event.locationInWindow, from: nil)
            return menuAt?(p)
        }
    }
}

@MainActor final class MenuActionTarget: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

extension TimelineMenu {
    /// Builds the NSMenu for entries; every item keeps its action target alive through `representedObject`.
    @MainActor static func nsMenu(_ entries: [Entry], run: @escaping (Action) -> Void) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for e in entries {
            if e.isSeparator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: e.title, action: nil, keyEquivalent: "")
            item.isEnabled = e.enabled; item.state = e.checked ? .on : .off
            if !e.children.isEmpty { item.submenu = nsMenu(e.children, run: run) }
            else if let a = e.action {
                let t = MenuActionTarget { run(a) }
                item.target = t; item.action = #selector(MenuActionTarget.fire); item.representedObject = t
            }
            if let s = e.shortcut {
                item.keyEquivalentModifierMask = s.hasPrefix("⌘") ? .command : []
                let k = s.replacingOccurrences(of: "⌘", with: "")
                item.keyEquivalent = k == "⌫" ? "\u{8}" : k.lowercased()
            }
            menu.addItem(item)
        }
        return menu
    }
}
