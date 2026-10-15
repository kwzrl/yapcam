import AppKit
import Carbon.HIToolbox

/// Everything that has a keyboard shortcut. Global ones work from any app; the rest are menu shortcuts.
enum HotkeyAction: String, CaseIterable, Identifiable {
    case startStop, recordDisplay, recordWindow, recordArea, pauseResume, restart, marker
    case toggleWidget, prompterPlay, toggleNotes, cancel, quickExportCopy, quickExportSave, openLast
    var id: String { rawValue }

    var title: String {
        switch self {
        case .startStop: "Start / finish recording"
        case .recordDisplay: "Record display"
        case .recordWindow: "Record window"
        case .recordArea: "Record area"
        case .pauseResume: "Pause / resume"
        case .restart: "Restart recording"
        case .marker: "Add marker"
        case .toggleWidget: "Show / hide toolbar"
        case .prompterPlay: "Teleprompter play / pause"
        case .toggleNotes: "Show / hide speaker notes"
        case .cancel: "Cancel recording"
        case .quickExportCopy: "Quick export: copy to clipboard"
        case .quickExportSave: "Quick export: save to file"
        case .openLast: "Open last recording"
        }
    }

    /// Registered system-wide (works while another app is in front). The others are menu shortcuts.
    var isGlobal: Bool {
        switch self {
        case .toggleNotes, .quickExportCopy, .quickExportSave, .openLast: false
        default: true
        }
    }

    var defaultCombo: KeyCombo? {
        let cmdOpt = UInt32(cmdKey | optionKey)
        switch self {
        case .startStop: return KeyCombo(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey | controlKey))
        case .recordDisplay: return KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: cmdOpt)
        case .recordWindow: return KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: cmdOpt)
        case .recordArea: return KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: cmdOpt)
        case .pauseResume: return KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: cmdOpt)
        case .restart: return KeyCombo(keyCode: UInt32(kVK_Delete), modifiers: cmdOpt)
        case .marker: return KeyCombo(keyCode: UInt32(kVK_ANSI_F), modifiers: cmdOpt | UInt32(controlKey))
        case .toggleWidget: return KeyCombo(keyCode: UInt32(kVK_ANSI_Quote), modifiers: cmdOpt)
        case .prompterPlay: return KeyCombo(keyCode: UInt32(kVK_ANSI_Period), modifiers: cmdOpt)
        case .toggleNotes: return KeyCombo(keyCode: UInt32(kVK_ANSI_Slash), modifiers: cmdOpt)
        case .cancel: return nil
        case .quickExportCopy: return KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: cmdOpt)
        case .quickExportSave: return KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: cmdOpt)
        case .openLast: return KeyCombo(keyCode: UInt32(kVK_ANSI_Z), modifiers: cmdOpt)
        }
    }
}

extension KeyCombo {
    /// "No shortcut" marker (the user cleared it).
    static let none = KeyCombo(keyCode: 0xFFFF, modifiers: 0)
    var isNone: Bool { keyCode == 0xFFFF }

    /// Menu key equivalent for this combo (nil when there is no sensible character).
    var menuKey: (key: String, flags: NSEvent.ModifierFlags)? {
        guard !isNone else { return nil }
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        switch Int(keyCode) {
        case kVK_Return: return ("\r", f)
        case kVK_Delete: return ("\u{8}", f)
        case kVK_Space: return (" ", f)
        default:
            let name = KeyCombo.keyName(keyCode)
            guard name.count == 1 else { return nil }
            return (name.lowercased(), f)
        }
    }
}

/// Registers every global shortcut and reports the ones macOS refused (or that clash with another of ours).
@MainActor final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()
    @Published private(set) var failed: Set<HotkeyAction> = []
    private var keys: [HotkeyAction: GlobalHotKey] = [:]

    func rebind() {
        let settings = AppSettings.shared
        keys.values.forEach { $0.unregister() }
        keys = [:]
        var failures: Set<HotkeyAction> = []
        var used: [KeyCombo: HotkeyAction] = [:]
        for action in HotkeyAction.allCases where action.isGlobal {
            guard let combo = settings.combo(for: action), !combo.isNone else { continue }
            if used[combo] != nil { failures.insert(action); continue }       // same keys as another action
            used[combo] = action
            let key = GlobalHotKey()
            if key.register(combo, action: { HotkeyActions.perform(action) }) { keys[action] = key }
            else { failures.insert(action); Probe.log("could not register \(action.rawValue) shortcut \(combo.display)") }
        }
        failed = failures
    }

    /// Combos used by more than one action (global or menu): the Shortcuts tab flags them.
    static func conflicts(in settings: AppSettings) -> Set<HotkeyAction> {
        var seen: [KeyCombo: HotkeyAction] = [:]
        var out: Set<HotkeyAction> = []
        for a in HotkeyAction.allCases {
            guard let c = settings.combo(for: a), !c.isNone else { continue }
            if seen[c] != nil { out.insert(a) } else { seen[c] = a }
        }
        return out
    }
}

/// What each shortcut does.
@MainActor enum HotkeyActions {
    static func perform(_ action: HotkeyAction) {
        let rec = RecordingController.shared
        let settings = AppSettings.shared
        switch action {
        case .startStop: rec.toggleStartStop()
        case .recordDisplay: if rec.phase == .idle { settings.sourceMode = .display; SourceOverlay.shared.show(.display) }
        case .recordWindow: if rec.phase == .idle { settings.sourceMode = .window; SourceOverlay.shared.show(.window) }
        case .recordArea: if rec.phase == .idle { settings.sourceMode = .area; AreaPicker.begin() }
        case .pauseResume: rec.togglePause()
        case .restart: rec.confirmRestart()
        case .marker: rec.addMarker()
        case .toggleWidget: ToolbarPanelController.shared.toggle()
        case .prompterPlay: rec.prompterPlaying.toggle()
        case .toggleNotes: NotesWindow.shared.toggle()
        case .cancel: rec.confirmCancel()
        case .quickExportCopy: QuickExport.shared.runOnLast(.copy)
        case .quickExportSave: QuickExport.shared.runOnLast(.save)
        case .openLast: ProjectActions.openLast()
        }
    }
}
