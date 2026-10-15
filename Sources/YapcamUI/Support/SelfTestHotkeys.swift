import AppKit
import Carbon.HIToolbox
import YapcamCapture

/// Extra QA hooks for `--ui-record-selftest` / `--drive-input-selftest`:
///   --hotkey-script "recordDisplay,wait:1.5,return,wait:3,marker,pauseResume,wait:1,pauseResume,wait:2,startStop"
///       posts the real global shortcuts (and Return/Escape) from inside the app, so the WindowServer →
///       Carbon hotkey → app path is exercised exactly as a user's keypress would.
///   --after-recording create|widget|copy|save [--save-to <file.mp4>]
///       runs the recording with that after-recording choice and logs what happened.
/// Everything goes to ~/Library/Logs/Yapcam/probe.log.
struct SelfTestOptions: Equatable {
    var hotkeyScript: [HotkeyStep]?
    var afterRecording: String?
    var saveTo: String?

    static let afterRecordingChoices = ["create", "widget", "copy", "save"]
}

enum HotkeyStep: Equatable {
    case hotkey(HotkeyAction)
    case wait(Double)
    case key(String)          // "return" | "escape"
    case expect(String)       // log the controller phase: expect:recording

    /// "startStop,wait:2,marker" → steps; nil with a reason when something isn't understood.
    static func parse(_ text: String, error: inout String?) -> [HotkeyStep]? {
        var out: [HotkeyStep] = []
        for raw in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
            if raw.hasPrefix("wait:") {
                guard let s = Double(raw.dropFirst(5)), s >= 0, s <= 600 else { error = "bad wait in “\(raw)” (0…600 seconds)"; return nil }
                out.append(.wait(s))
            } else if raw.hasPrefix("expect:") {
                out.append(.expect(String(raw.dropFirst(7))))
            } else if raw == "return" || raw == "escape" {
                out.append(.key(raw))
            } else if let a = HotkeyAction(rawValue: raw) {
                out.append(.hotkey(a))
            } else {
                error = "unknown step “\(raw)” (use an action name such as startStop, recordDisplay, pauseResume, restart, marker; or wait:N, return, escape, expect:<phase>)"
                return nil
            }
        }
        guard !out.isEmpty else { error = "the script is empty"; return nil }
        return out
    }
}

@MainActor enum SelfTestKeys {
    /// Carbon modifier mask → CGEvent flags.
    static func flags(for modifiers: UInt32) -> CGEventFlags {
        var f: CGEventFlags = []
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.maskCommand) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.maskAlternate) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.maskControl) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.maskShift) }
        return f
    }

    static func post(keyCode: Int, flags: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    static func press(_ combo: KeyCombo) { post(keyCode: Int(combo.keyCode), flags: flags(for: combo.modifiers)) }

    /// Runs the script; logs each step with the controller phase before and after.
    static func run(_ steps: [HotkeyStep], tag: String) async {
        let rec = RecordingController.shared
        let settings = AppSettings.shared
        for step in steps {
            switch step {
            case .wait(let s): try? await Task.sleep(for: .seconds(s))
            case .expect(let p): Probe.log("\(tag) expect:\(p) phase=\(rec.phase) \(matches(rec.phase, p) ? "OK" : "MISMATCH")")
            case .key(let k):
                let before = rec.phase
                post(keyCode: k == "return" ? kVK_Return : kVK_Escape, flags: [])
                try? await Task.sleep(for: .milliseconds(700))
                Probe.log("\(tag) key \(k): phase \(before) → \(rec.phase)")
            case .hotkey(let a):
                guard let combo = settings.combo(for: a) else { Probe.log("\(tag) hotkey \(a.rawValue): no shortcut set"); continue }
                let before = rec.phase
                press(combo)
                try? await Task.sleep(for: .milliseconds(900))
                Probe.log("\(tag) hotkey \(a.rawValue) \(combo.display) (global=\(a.isGlobal)): phase \(before) → \(rec.phase) markers=\(rec.markers.count)")
            }
        }
    }

    static func matches(_ phase: RecordingPhase, _ name: String) -> Bool {
        switch (phase, name) {
        case (.idle, "idle"), (.recording, "recording"), (.paused, "paused"), (.starting, "starting"), (.finishing, "finishing"): return true
        case (.countdown, "countdown"): return true
        default: return false
        }
    }
}
