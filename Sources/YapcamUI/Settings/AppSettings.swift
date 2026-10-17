import AppKit
import YapcamCapture
import YapcamEditor
import YapcamRender
import Carbon.HIToolbox
import SwiftUI

/// What happens when a recording stops.
enum AfterRecording: String, CaseIterable, Identifiable {
    case createProject, exportCopy, exportSave
    var id: String { rawValue }
    var title: String {
        switch self { case .createProject: "Create project"; case .exportCopy: "Export and copy to clipboard"; case .exportSave: "Export and save to file" }
    }
    var recordLabel: String {
        switch self { case .createProject: "Start recording"; case .exportCopy: "Record & Copy"; case .exportSave: "Record & Save" }
    }
}

/// What happens after a quick export finishes (reference: "Action after quick export", default do nothing).
enum ActionAfterQuickExport: String, CaseIterable, Identifiable {
    case nothing, revealInFinder
    var id: String { rawValue }
    var title: String { self == .nothing ? "Do nothing" : "Show the file in Finder" }
}

enum SourceMode: String, CaseIterable, Identifiable {
    case display, window, area, device
    var id: String { rawValue }
    /// Modes offered in the toolbar. Device recording stays in the code but has no UI entry until a real device is tested.
    static let toolbarModes: [SourceMode] = [.display, .window, .area]
    var title: String { switch self { case .display: "Display"; case .window: "Window"; case .area: "Area"; case .device: "Device" } }
    var symbol: String {
        switch self { case .display: "display"; case .window: "macwindow"; case .area: "rectangle.dashed"; case .device: "iphone" }
    }
}

/// A global key combination (Carbon key code + Carbon modifier mask).
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

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
        guard let data = CFDataGetBytePtr(layout) else { return "?" }
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
    let d: UserDefaults   // the backing store (also read off the main actor by editor hooks)

    @Published var sourceMode: SourceMode { didSet { d.set(sourceMode.rawValue, forKey: "sourceMode") } }
    @Published var displayID: UInt32 { didSet { d.set(Int(displayID), forKey: "displayID") } }
    @Published var windowID: UInt32 { didSet { d.set(Int(windowID), forKey: "windowID") } }
    @Published var areaDisplayID: UInt32 { didSet { d.set(Int(areaDisplayID), forKey: "areaDisplayID") } }
    @Published var areaRect: CGRect? { didSet { d.set(areaRect.map { NSStringFromRect($0) }, forKey: "areaRect") } }
    @Published var deviceID: String? { didSet { d.set(deviceID, forKey: "deviceID") } }
    @Published var lastCameraID: String? { didSet { d.set(lastCameraID, forKey: "lastCameraID") } }
    @Published var lastMicrophoneID: String? { didSet { d.set(lastMicrophoneID, forKey: "lastMicrophoneID") } }
    @Published var systemAudio: Bool { didSet { d.set(systemAudio, forKey: "systemAudio") } }
    /// With `systemAudio` on: record only the apps in `systemAudioApps` (bundle ids) instead of all apps.
    @Published var systemAudioSelectedOnly: Bool { didSet { d.set(systemAudioSelectedOnly, forKey: "systemAudioSelectedOnly") } }
    @Published var systemAudioApps: [String] { didSet { d.set(systemAudioApps, forKey: "systemAudioApps") } }
    @Published var areaCustomRatioW: CGFloat { didSet { d.set(Double(areaCustomRatioW), forKey: "areaCustomRatioW") } }
    @Published var areaCustomRatioH: CGFloat { didSet { d.set(Double(areaCustomRatioH), forKey: "areaCustomRatioH") } }
    /// New projects start from the look of the most recent one instead of the default preset.
    @Published var reuseLastProjectSettings: Bool { didSet { d.set(reuseLastProjectSettings, forKey: "reuseLastProjectSettings") } }
    /// Folder for look presets; nil = the standard folder.
    @Published var presetsDirectory: URL? { didSet { d.set(presetsDirectory?.path, forKey: "presetsDirectory") } }
    /// Experimental: exports (quick export) omit exact duplicate frames (variable frame rate).
    @Published var experimentalVariableFrameRate: Bool { didSet { d.set(experimentalVariableFrameRate, forKey: "experimentalVariableFrameRate") } }
    /// Editor autosave 30 s after the last edit (closing a window and quitting always save).
    @Published var autosaveEnabled: Bool { didSet { d.set(autosaveEnabled, forKey: "autosaveEnabled"); EditorHooks.apply(self) } }
    @Published var microphoneID: String? { didSet { d.set(microphoneID, forKey: "microphoneID") } }
    @Published var cameraID: String? { didSet { d.set(cameraID, forKey: "cameraID") } }
    @Published var cameraMaxResolution: CameraMaxResolution { didSet { d.set(cameraMaxResolution.rawValue, forKey: "cameraMaxResolution") } }
    @Published var countdown: Int { didSet { d.set(countdown, forKey: "countdown") } }
    @Published var recordKeystrokes: Bool { didSet { d.set(recordKeystrokes, forKey: "recordKeystrokes") } }
    @Published var maxFPS: Int { didSet { d.set(maxFPS, forKey: "maxFPS") } }
    @Published var openEditorAfterRecording: Bool { didSet { d.set(openEditorAfterRecording, forKey: "openEditor") } }
    @Published var playSounds: Bool { didSet { d.set(playSounds, forKey: "playSounds") } }
    /// Microphone menu: new projects start with "Clean up voice" on (noise + level), see ProjectActions.applyRecordTimeAudio.
    @Published var cleanVoiceOnRecord: Bool { didSet { d.set(cleanVoiceOnRecord, forKey: "cleanVoiceOnRecord") } }
    /// Settings → Advanced: export with the VideoToolbox software encoder (decoding stays system-managed).
    @Published var disableHardwareEncoding: Bool { didSet { d.set(disableHardwareEncoding, forKey: "disableHardwareEncoding") } }
    /// What the editor's export reads (EditorWindows.hardwareEncodingEnabled): the stored switch, off the main actor.
    nonisolated static func hardwareEncodingEnabledInStore(_ store: UserDefaults = AppDefaults.store) -> Bool {
        !(store.object(forKey: "disableHardwareEncoding") as? Bool ?? false)
    }
    /// Read by the editor when an export starts; that can be off the main thread, so it reads the store, not `shared`.
    nonisolated static func variableFrameRateInStore(_ store: UserDefaults = AppDefaults.store) -> Bool {
        store.object(forKey: "experimentalVariableFrameRate") as? Bool ?? false
    }
    @Published var hideDesktopIcons: Bool { didSet { d.set(hideDesktopIcons, forKey: "hideDesktopIcons") } }
    /// While a recording runs the Dock icon is hidden (reference "Hide Dock Icon", default on). The menu bar item stays.
    @Published var hideDockWhileRecording: Bool { didSet { d.set(hideDockWhileRecording, forKey: "hideDockWhileRecording") } }
    /// The recents list stays open next to the picker (reference: openRecentProjectsWithRecordingPicker, off).
    @Published var showRecentsWithPicker: Bool { didSet { d.set(showRecentsWithPicker, forKey: "showRecentsWithPicker") } }
    /// Camera preview in the picker's camera menu ("Hide camera preview").
    @Published var hideCameraPreview: Bool { didSet { d.set(hideCameraPreview, forKey: "hideCameraPreview") } }
    @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }
    @Published var showMenuBarItem: Bool { didSet { d.set(showMenuBarItem, forKey: "showMenuBarItem") } }
    @Published var storageDirectory: URL { didSet { d.set(storageDirectory.path, forKey: "storageDirectory") } }
    /// Only the shortcuts the user changed; everything else uses `HotkeyAction.defaultCombo`.
    @Published var shortcuts: [String: KeyCombo] { didSet { d.set(try? JSONEncoder().encode(shortcuts), forKey: "shortcuts.v2") } }
    @Published var highlightRecordedArea: Bool { didSet { d.set(highlightRecordedArea, forKey: "highlightRecordedArea") } }
    @Published var removedRecents: Set<String> { didSet { d.set(Array(removedRecents), forKey: "removedRecents") } }
    @Published var savedWindowSizes: [String] { didSet { d.set(savedWindowSizes, forKey: "savedWindowSizes") } }
    /// Area sizes the user saved in the area toolbar ("1280x720").
    @Published var savedAreaSizes: [String] { didSet { d.set(savedAreaSizes, forKey: "savedAreaSizes") } }
    /// Export settings used by quick export and the quick export widget (Settings → Quick export).
    @Published var quickExport: ExportSettings { didSet { d.set(try? JSONEncoder().encode(quickExport), forKey: "quickExport.v1") } }
    /// Editor window appearance (Settings → Editing): dark by default, like the reference.
    @Published var editorAppearance: EditorAppearance { didSet { d.set(editorAppearance.rawValue, forKey: "editorAppearance"); EditorWindows.appearance = editorAppearance } }
    /// Quick export widget: keep the project after Copy / Save without asking (off: closing the widget asks Keep or Trash).
    @Published var alwaysKeepProjectAfterQuickExport: Bool { didSet { d.set(alwaysKeepProjectAfterQuickExport, forKey: "alwaysKeepProjectAfterQuickExport") } }
    @Published var actionAfterQuickExport: ActionAfterQuickExport { didSet { d.set(actionAfterQuickExport.rawValue, forKey: "actionAfterQuickExport") } }
    @Published var showRecordingWidget: Bool { didSet { d.set(showRecordingWidget, forKey: "showRecordingWidget") } }
    @Published var createAutoZooms: Bool { didSet { d.set(createAutoZooms, forKey: "createAutoZooms") } }
    @Published var afterRecording: AfterRecording { didSet { d.set(afterRecording.rawValue, forKey: "afterRecording") } }
    @Published var showQuickExportWidget: Bool { didSet { d.set(showQuickExportWidget, forKey: "showQuickExportWidget") } }
    @Published var hasCompletedOnboarding: Bool { didSet { d.set(hasCompletedOnboarding, forKey: "onboarded") } }

    /// Frame-rate cap: 0 = automatic (follows the display's refresh rate; the reference has no picker), or an explicit 30 / 60 kept
    /// from earlier versions. Anything else counts as automatic.
    static func cap(_ saved: Int?) -> Int { saved == 30 || saved == 60 ? saved! : 0 }

    /// Render's default export: MP4, 720p, 60 fps, H.264, social compression, with audio (reference default).
    static var defaultQuickExport: ExportSettings { ExportSettings() }

    static var defaultStorage: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Yapcam", directoryHint: .isDirectory)
    }

    private func store(_ c: KeyCombo, _ key: String) {
        d.set(try? JSONEncoder().encode(c), forKey: key)
    }
    private static func load(_ key: String, default def: KeyCombo, from d: UserDefaults) -> KeyCombo {
        (d.data(forKey: key).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }) ?? def
    }

    /// The defaults this instance persists into (tests reopen settings from the same store).
    var debugStore: UserDefaults { d }

    init(store: UserDefaults) {
        d = store
        let saved = SourceMode(rawValue: d.string(forKey: "sourceMode") ?? "") ?? .display
        sourceMode = SourceMode.toolbarModes.contains(saved) ? saved : .display
        displayID = UInt32(d.integer(forKey: "displayID"))
        windowID = UInt32(d.integer(forKey: "windowID"))
        areaDisplayID = UInt32(d.integer(forKey: "areaDisplayID"))
        areaRect = d.string(forKey: "areaRect").map { NSRectFromString($0) }
        deviceID = d.string(forKey: "deviceID")
        lastCameraID = d.string(forKey: "lastCameraID")
        lastMicrophoneID = d.string(forKey: "lastMicrophoneID")
        systemAudio = d.object(forKey: "systemAudio") as? Bool ?? false      // reference default: off
        systemAudioSelectedOnly = d.object(forKey: "systemAudioSelectedOnly") as? Bool ?? false
        systemAudioApps = d.stringArray(forKey: "systemAudioApps") ?? []
        areaCustomRatioW = CGFloat(d.object(forKey: "areaCustomRatioW") as? Double ?? 16)
        areaCustomRatioH = CGFloat(d.object(forKey: "areaCustomRatioH") as? Double ?? 10)
        reuseLastProjectSettings = d.object(forKey: "reuseLastProjectSettings") as? Bool ?? true
        presetsDirectory = d.string(forKey: "presetsDirectory").map { URL(filePath: $0, directoryHint: .isDirectory) }
        experimentalVariableFrameRate = d.object(forKey: "experimentalVariableFrameRate") as? Bool ?? false
        autosaveEnabled = d.object(forKey: "autosaveEnabled") as? Bool ?? true
        microphoneID = d.string(forKey: "microphoneID")
        cameraID = d.string(forKey: "cameraID")
        cameraMaxResolution = CameraMaxResolution(rawValue: d.integer(forKey: "cameraMaxResolution")) ?? .hd1080
        let cd = d.object(forKey: "countdown") as? Int ?? 0
        countdown = [0, 3, 5, 10].contains(cd) ? cd : 0
        recordKeystrokes = d.object(forKey: "recordKeystrokes") as? Bool ?? true     // reference default: on (still needs Input Monitoring)
        maxFPS = AppSettings.cap(d.object(forKey: "maxFPS") as? Int)
        openEditorAfterRecording = d.object(forKey: "openEditor") as? Bool ?? true
        playSounds = d.object(forKey: "playSounds") as? Bool ?? true
        cleanVoiceOnRecord = d.object(forKey: "cleanVoiceOnRecord") as? Bool ?? false
        disableHardwareEncoding = d.object(forKey: "disableHardwareEncoding") as? Bool ?? false
        hideDesktopIcons = d.object(forKey: "hideDesktopIcons") as? Bool ?? false
        hideDockWhileRecording = d.object(forKey: "hideDockWhileRecording") as? Bool ?? true
        showRecentsWithPicker = d.object(forKey: "showRecentsWithPicker") as? Bool ?? false
        hideCameraPreview = d.object(forKey: "hideCameraPreview") as? Bool ?? false
        showInDock = d.object(forKey: "showInDock") as? Bool ?? true
        showMenuBarItem = d.object(forKey: "showMenuBarItem") as? Bool ?? true
        storageDirectory = d.string(forKey: "storageDirectory").map { URL(filePath: $0, directoryHint: .isDirectory) } ?? Self.defaultStorage
        shortcuts = (store.data(forKey: "shortcuts.v2").flatMap { try? JSONDecoder().decode([String: KeyCombo].self, from: $0) }) ?? [:]
        highlightRecordedArea = store.object(forKey: "highlightRecordedArea") as? Bool ?? true
        removedRecents = Set(store.stringArray(forKey: "removedRecents") ?? [])
        savedWindowSizes = store.stringArray(forKey: "savedWindowSizes") ?? []
        savedAreaSizes = store.stringArray(forKey: "savedAreaSizes") ?? []
        quickExport = (d.data(forKey: "quickExport.v1").flatMap { try? JSONDecoder().decode(ExportSettings.self, from: $0) })
            .map { $0.closestValidPreset(for: .file) } ?? AppSettings.defaultQuickExport
        editorAppearance = EditorAppearance(rawValue: d.string(forKey: "editorAppearance") ?? "") ?? .dark
        alwaysKeepProjectAfterQuickExport = d.object(forKey: "alwaysKeepProjectAfterQuickExport") as? Bool ?? false
        actionAfterQuickExport = ActionAfterQuickExport(rawValue: d.string(forKey: "actionAfterQuickExport") ?? "") ?? .nothing
        showRecordingWidget = store.object(forKey: "showRecordingWidget") as? Bool ?? true
        createAutoZooms = store.object(forKey: "createAutoZooms") as? Bool ?? true
        afterRecording = AfterRecording(rawValue: store.string(forKey: "afterRecording") ?? "") ?? .createProject
        showQuickExportWidget = store.object(forKey: "showQuickExportWidget") as? Bool ?? true
        hasCompletedOnboarding = d.bool(forKey: "onboarded")
    }

    func combo(for action: HotkeyAction) -> KeyCombo? {
        if let c = shortcuts[action.rawValue] { return c.isNone ? nil : c }
        return action.defaultCombo
    }
    func setCombo(_ combo: KeyCombo?, for action: HotkeyAction) {
        if combo == action.defaultCombo { shortcuts[action.rawValue] = nil }
        else { shortcuts[action.rawValue] = combo ?? KeyCombo.none }   // not `.none`: that would mean Optional.none
    }
    func resetShortcuts() { shortcuts = [:] }

    var startStopShortcut: KeyCombo { combo(for: .startStop) ?? .none }
    var pauseShortcut: KeyCombo { combo(for: .pauseResume) ?? .none }
}

extension AppSettings {
    /// The activation policy the app should have: a hidden Dock icon stays hidden; with the Dock icon shown it
    /// goes away while a recording runs when `hideDockWhileRecording` is on.
    static func activationPolicy(showInDock: Bool, hideWhileRecording: Bool, recording: Bool, editorOpen: Bool = false) -> NSApplication.ActivationPolicy {
        if editorOpen { return .regular }                     // an open project always has a Dock icon (Hide Dock Icon applies when nothing is open)
        guard showInDock else { return .accessory }
        return recording && hideWhileRecording ? .accessory : .regular
    }
    var activationPolicy: NSApplication.ActivationPolicy {
        let phase = RecordingController.shared.phase
        return Self.activationPolicy(showInDock: showInDock, hideWhileRecording: hideDockWhileRecording, recording: phase == .recording || phase == .paused, editorOpen: EditorWindows.openCount > 0)
    }
}

extension AppSettings {
    /// "Reset preferences": every preference goes back to its default. The recordings folder, the recents list and the
    /// onboarding flag stay (resetting them would hide existing recordings or replay the welcome).
    func resetToDefaults() {
        let name = "yapcam.reset.\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: name)!
        defer { scratch.removePersistentDomain(forName: name) }
        let f = AppSettings(store: scratch)
        sourceMode = f.sourceMode; displayID = f.displayID; windowID = f.windowID; areaDisplayID = f.areaDisplayID; areaRect = f.areaRect
        deviceID = f.deviceID; lastCameraID = f.lastCameraID; lastMicrophoneID = f.lastMicrophoneID
        systemAudio = f.systemAudio; systemAudioSelectedOnly = f.systemAudioSelectedOnly; systemAudioApps = f.systemAudioApps
        areaCustomRatioW = f.areaCustomRatioW; areaCustomRatioH = f.areaCustomRatioH
        reuseLastProjectSettings = f.reuseLastProjectSettings; presetsDirectory = f.presetsDirectory
        experimentalVariableFrameRate = f.experimentalVariableFrameRate; autosaveEnabled = f.autosaveEnabled
        microphoneID = f.microphoneID; cameraID = f.cameraID; cameraMaxResolution = f.cameraMaxResolution
        countdown = f.countdown; recordKeystrokes = f.recordKeystrokes; maxFPS = f.maxFPS
        openEditorAfterRecording = f.openEditorAfterRecording; playSounds = f.playSounds; hideDesktopIcons = f.hideDesktopIcons; disableHardwareEncoding = f.disableHardwareEncoding; cleanVoiceOnRecord = f.cleanVoiceOnRecord
        hideDockWhileRecording = f.hideDockWhileRecording; showRecentsWithPicker = f.showRecentsWithPicker; hideCameraPreview = f.hideCameraPreview
        showInDock = f.showInDock; showMenuBarItem = f.showMenuBarItem
        shortcuts = f.shortcuts; highlightRecordedArea = f.highlightRecordedArea; savedWindowSizes = f.savedWindowSizes; savedAreaSizes = f.savedAreaSizes
        editorAppearance = f.editorAppearance; actionAfterQuickExport = f.actionAfterQuickExport; alwaysKeepProjectAfterQuickExport = f.alwaysKeepProjectAfterQuickExport; quickExport = f.quickExport; showRecordingWidget = f.showRecordingWidget; createAutoZooms = f.createAutoZooms
        afterRecording = f.afterRecording; showQuickExportWidget = f.showQuickExportWidget
    }
}
