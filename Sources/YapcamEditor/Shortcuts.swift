import Foundation

public struct ShortcutModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = ShortcutModifiers(rawValue: 1), shift = ShortcutModifiers(rawValue: 2)
    public static let option = ShortcutModifiers(rawValue: 4), control = ShortcutModifiers(rawValue: 8)
}

extension EditorModel {
    /// Character shortcuts of the editor, following the reference's layout (all handled here so they can be tested):
    /// C split · X ripple delete · S speed menu · V volume menu (⌃V system audio) · J/K/L shuttle · Z add zoom ·
    /// A/M/D, 1–9, 0, =/- on a selected zoom · ⌘D duplicate · ⌘C/⌘V copy/paste settings · ⌘=/⌘- timeline zoom ·
    /// ⌘1…⌘0 inspector sections · ⌘K palette. Returns whether the key was used.
    @discardableResult
    public func handleShortcut(_ key: Character, _ mods: ShortcutModifiers = []) -> Bool {
        let k = Character(String(key).lowercased())
        if mods.contains(.command) {
            switch k {
            case "k": paletteVisible = true; return true
            case "e": if mods.contains(.shift) { performExport(.picker); return true }; return false
            case "s":
                if mods.contains(.option) { performExport(.saveToFile); return true }
                if mods.contains(.shift) { return false }
                saveNow(); return true                  // ⌘S: save now (S-01); autosave still runs

            case "c":
                if mods.contains(.option) { performExport(.copyToClipboard); return true }
                copyFrameHandler?()                  // ⌘C always copies the frame; item settings are copied from the context menus (S-EDT-60)
                return true
            case "v": return pasteSettings()
            case "x": return cutSelection()
            case "d": if selectedZoom != nil { duplicateSelectedZoom(); return true }; return false
            case "\\": if mods.contains(.shift) { timelineHidden.toggle() } else { sidebarHidden.toggle() }; return true
            case "=", "+": zoomTimeline(by: 1.25); return true
            case "-": zoomTimeline(by: 0.8); return true
            case "0"..."9": return selectInspector(digit: k)
            default: return false
            }
        }
        if mods.contains(.control) { if k == "v" { volumeMenuSystem = true; volumeMenuVisible = true; return true }; return false }
        guard let k = keyBindings.canonical(k) else { return false }        // Settings can move these keys
        switch k {
        case "j", "k", "l": shuttle(k); return true
        case "c": splitContextAware(); return true
        case "x": rippleDeleteToPreviousCut(); return true
        case "s": speedMenuVisible = true; return true
        case "v": volumeMenuSystem = false; volumeMenuVisible = true; return true
        case "z":
            if mods.contains(.shift) { fitTimeline(width: timelineViewportWidth) } else { addZoomAtPlayhead() }
            return true
        case "[": trim(keepAfter: true); return true
        case "]": trim(keepAfter: false); return true
        case "a": if let z = selectedZoom { setZoomMode(id: z.id, .auto); return true }; return false
        case "m": if let z = selectedZoom { setZoomMode(id: z.id, .manual); return true }; return false
        case "d": if selectedZoom != nil { toggleSelectedZoomEnabled(); return true }; return false
        case "0"..."9":
            guard selectedZoom != nil else {                              // no zoom selected: 2…8 show or hide timelines (4 = masks)
                guard let lane = LaneVisibility.lane(forKey: k), offersLane(lane) else { return false }
                toggleLane(lane); return true
            }
            guard selectedZoom != nil, let d = k.wholeNumberValue else { return false }
            setSelectedZoomLevel(d == 0 ? defaultZoomScale : zoomLevel(forDigit: d), coalesce: true); return true
        case "=", "+": if selectedZoom != nil { stepSelectedZoomLevel(by: 0.2); return true }; return false
        case "-": if selectedZoom != nil { stepSelectedZoomLevel(by: -0.2); return true }; return false
        default: return false
        }
    }
}
