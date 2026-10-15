import AppKit
import Carbon.HIToolbox
import SwiftUI

enum SourceMode: String, CaseIterable, Identifiable {
    case display, window, area, device
    var id: String { rawValue }
    var title: String { switch self { case .display: "Display"; case .window: "Window"; case .area: "Area"; case .device: "Device" } }
    var symbol: String {
        switch self { case .display: "display"; case .window: "macwindow"; case .area: "rectangle.dashed"; case .device: "iphone" }
    }
}

/// A global key combination (Carbon key code + Carbon modifier mask).
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let startStop = KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey))
    static let pauseResume = KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey))

    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        // A global shortcut needs at least one of ⌘ ⌥ ⌃ to avoid swallowing normal typing.
        guard m & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m)
    }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyCombo.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        if let n = names[Int(code)] { return n }
        // Resolve the character through the current keyboard layout.
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let layout = unsafeBitCast(ptr, to: CFData.self)
        let data = CFDataGetBytePtr(layout)!
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status = data.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                           UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                           &dead, 4, &len, &chars)
        }
        return status == noErr && len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "?"
    }
}

/// All user preferences, persisted in UserDefaults. Plain stored properties with
/// `didSet` persistence keep the view code trivial.
@MainActor final class AppSettings: ObservableObject {
    static let shared = AppSettings(store: AppDefaults.store)
    private let d: UserDefaults

    @Published var sourceMode: SourceMode { didSet { d.set(sourceMode.rawValue, forKey: "sourceMode") } }
    @Published var displayID: UInt32 { didSet { d.set(Int(displayID), forKey: "displayID") } }
    @Published var windowID: UInt32 { didSet { d.set(Int(windowID), forKey: "windowID") } }
    @Published var areaDisplayID: UInt32 { didSet { d.set(Int(areaDisplayID), forKey: "areaDisplayID") } }
    @Published var areaRect: CGRect? { didSet { d.set(areaRect.map { NSStringFromRect($0) }, forKey: "areaRect") } }
    @Published var deviceID: String? { didSet { d.set(deviceID, forKey: "deviceID") } }
    @Published var lastCameraID: String? { didSet { d.set(lastCameraID, forKey: "lastCameraID") } }
    @Published var lastMicrophoneID: String? { didSet { d.set(lastMicrophoneID, forKey: "lastMicrophoneID") } }
    @Published var systemAudio: Bool { didSet { d.set(systemAudio, forKey: "systemAudio") } }
    @Published var microphoneID: String? { didSet { d.set(microphoneID, forKey: "microphoneID") } }
    @Published var cameraID: String? { didSet { d.set(cameraID, forKey: "cameraID") } }
    @Published var countdown: Int { didSet { d.set(countdown, forKey: "countdown") } }
    @Published var recordKeystrokes: Bool { didSet { d.set(recordKeystrokes, forKey: "recordKeystrokes") } }
    @Published var maxFPS: Int { didSet { d.set(maxFPS, forKey: "maxFPS") } }
    @Published var openEditorAfterRecording: Bool { didSet { d.set(openEditorAfterRecording, forKey: "openEditor") } }
    @Published var playSounds: Bool { didSet { d.set(playSounds, forKey: "playSounds") } }
    @Published var hideDesktopIcons: Bool { didSet { d.set(hideDesktopIcons, forKey: "hideDesktopIcons") } }
    @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }
    @Published var showMenuBarItem: Bool { didSet { d.set(showMenuBarItem, forKey: "showMenuBarItem") } }
    @Published var storageDirectory: URL { didSet { d.set(storageDirectory.path, forKey: "storageDirectory") } }
    @Published var startStopShortcut: KeyCombo { didSet { store(startStopShortcut, "shortcutStartStop") } }
    @Published var pauseShortcut: KeyCombo { didSet { store(pauseShortcut, "shortcutPause") } }
    @Published var hasCompletedOnboarding: Bool { didSet { d.set(hasCompletedOnboarding, forKey: "onboarded") } }

    static var defaultStorage: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Yapcam", directoryHint: .isDirectory)
    }

    private func store(_ c: KeyCombo, _ key: String) {
        d.set(try? JSONEncoder().encode(c), forKey: key)
    }
    private static func load(_ key: String, default def: KeyCombo, from d: UserDefaults) -> KeyCombo {
        (d.data(forKey: key).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }) ?? def
    }

    init(store: UserDefaults) {
        d = store
        sourceMode = SourceMode(rawValue: d.string(forKey: "sourceMode") ?? "") ?? .display
        displayID = UInt32(d.integer(forKey: "displayID"))
        windowID = UInt32(d.integer(forKey: "windowID"))
        areaDisplayID = UInt32(d.integer(forKey: "areaDisplayID"))
        areaRect = d.string(forKey: "areaRect").map { NSRectFromString($0) }
        deviceID = d.string(forKey: "deviceID")
        lastCameraID = d.string(forKey: "lastCameraID")
        lastMicrophoneID = d.string(forKey: "lastMicrophoneID")
        systemAudio = d.object(forKey: "systemAudio") as? Bool ?? true
        microphoneID = d.string(forKey: "microphoneID")
        cameraID = d.string(forKey: "cameraID")
        let cd = d.object(forKey: "countdown") as? Int ?? 3
        countdown = [0, 3, 5].contains(cd) ? cd : 3
        recordKeystrokes = d.object(forKey: "recordKeystrokes") as? Bool ?? false
        maxFPS = d.object(forKey: "maxFPS") as? Int == 30 ? 30 : 60
        openEditorAfterRecording = d.object(forKey: "openEditor") as? Bool ?? true
        playSounds = d.object(forKey: "playSounds") as? Bool ?? false
        hideDesktopIcons = d.object(forKey: "hideDesktopIcons") as? Bool ?? false
        showInDock = d.object(forKey: "showInDock") as? Bool ?? true
        showMenuBarItem = d.object(forKey: "showMenuBarItem") as? Bool ?? true
        storageDirectory = d.string(forKey: "storageDirectory").map { URL(filePath: $0, directoryHint: .isDirectory) } ?? Self.defaultStorage
        startStopShortcut = Self.load("shortcutStartStop", default: .startStop, from: store)
        pauseShortcut = Self.load("shortcutPause", default: .pauseResume, from: store)
        hasCompletedOnboarding = d.bool(forKey: "onboarded")
    }

    func resetShortcuts() { startStopShortcut = .startStop; pauseShortcut = .pauseResume }
}
