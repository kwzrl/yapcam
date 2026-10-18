import AppKit
import ServiceManagement
import SwiftUI
import YapcamEditor
import YapcamRender

@MainActor final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(tab: SettingsTab? = nil) {
        if let tab { SettingsTabs.shared.selection = tab }
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 480),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Yapcam Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView().environmentObject(AppSettings.shared))
            w.center()
            RecordingController.shared.engine.registerExcluded(w)
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsTab: String, CaseIterable { case general, recording, editing, quickExport, shortcuts, experimental, advanced }

@MainActor final class SettingsTabs: ObservableObject {
    static let shared = SettingsTabs()
    @Published var selection = SettingsTab.general
}

struct SettingsView: View {
    @ObservedObject private var tabs = SettingsTabs.shared
    var body: some View {
        TabView(selection: $tabs.selection) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            RecordingSettings().tabItem { Label("Recording", systemImage: "record.circle") }.tag(SettingsTab.recording)
            EditingSettings().tabItem { Label("Editing", systemImage: "slider.horizontal.3") }.tag(SettingsTab.editing)
            QuickExportSettings().tabItem { Label("Quick export", systemImage: "square.and.arrow.up") }.tag(SettingsTab.quickExport)
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag(SettingsTab.shortcuts)
            ExperimentalSettings().tabItem { Label("Experimental", systemImage: "flask") }.tag(SettingsTab.experimental)
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag(SettingsTab.advanced)
        }
        .frame(width: 560, height: 480)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var s: AppSettings
    @State private var loginOn = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var confirmReset = false
    var body: some View {
        Form {
            Toggle("Start Yapcam at login", isOn: Binding(get: { loginOn }, set: { on in
                loginError = LoginItem.set(on); loginOn = LoginItem.isEnabled
            }))
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
            Toggle("Hide Dock Icon", isOn: Binding(get: { !s.showInDock }, set: { s.showInDock = !$0 }))
            Text("The icon only disappears while no project window is open.").font(.caption).foregroundStyle(.secondary)
            Toggle("Show menu bar item", isOn: $s.showMenuBarItem)
            Section("Permissions") {
                Button("Review permissions…") { OnboardingWindow.shared.show(reason: nil, all: true) }
            }
            Section {
                Button("Reset preferences…") { confirmReset = true }
                Text("Puts every setting back to its default. Your recordings, the recents list and the recordings folder stay as they are.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .confirmationDialog("Reset all preferences?", isPresented: $confirmReset) {
            Button("Reset Preferences", role: .destructive) { s.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct RecordingSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            LabeledContent("Save new projects to") {
                VStack(alignment: .trailing) {
                    Text((s.storageDirectory.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    HStack {
                        Button("Choose…") { chooseFolder() }
                        Button("Show in Finder") { NSWorkspace.shared.open(s.storageDirectory) }
                    }
                }
            }
            if let free = freeSpace { LabeledContent("Free space", value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) }
            Toggle("Bring a recorded window to the front when recording starts", isOn: $s.raiseWindowOnStart)
            Text("Needs Accessibility access. Without it the window stays where it is.").font(.caption).foregroundStyle(.secondary)
            Toggle("Dim the screen outside the area while choosing it", isOn: $s.dimAreaOutside)
            Toggle("Highlight recorded area during recording", isOn: $s.highlightRecordedArea)
            Toggle("Create zooms automatically", isOn: $s.createAutoZooms)
            Toggle("Show recording widget", isOn: $s.showRecordingWidget)
            Picker("Countdown", selection: $s.countdown) { ForEach(GearMenu.countdownChoices, id: \.1) { Text($0.0).tag($0.1) } }
            CameraResolutionRow()
            Toggle("Play start and stop sounds", isOn: $s.playSounds)
            Toggle("Record keystrokes", isOn: $s.recordKeystrokes)
            Text("Keystrokes are stored with the recording to show key overlays in the editor. Needs Input Monitoring permission. Never uploaded anywhere.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
    private var freeSpace: Int64? {
        try? s.storageDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }
    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = s.storageDirectory
        if p.runModal() == .OK, let url = p.url { s.storageDirectory = url }
    }
}

struct EditingSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            Toggle("Use last project settings as default for new recordings", isOn: $s.reuseLastProjectSettings)
            Text("A preset marked as default always wins. Without one, On starts new projects from the look of the most recently edited project; Off (or no earlier project) uses the standard look.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Ask to keep a new recording when its editor closes right away", isOn: $s.askKeepOnFirstClose)
            Text("If you close a brand-new recording within 10 seconds, Yapcam asks whether to keep it or move it to the Trash.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Use autosave (every 30 s)", isOn: $s.autosaveEnabled)
            Text(s.autosaveEnabled ? "Edits are saved 30 seconds after your last change. Closing a project window and quitting always save."
                                   : "Edits are saved only when you close the project window or quit. A crash can lose changes since then.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Save presets in") {
                VStack(alignment: .trailing) {
                    Text((PresetsFolder.effective(s.presetsDirectory).path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    HStack {
                        Button("Choose…") { choosePresets() }
                        if s.presetsDirectory != nil { Button("Use Standard Folder") { s.presetsDirectory = nil; PresetsFolder.apply(nil) } }
                        Button("Show in Finder") {
                            let d = PresetsFolder.effective(s.presetsDirectory)
                            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(d)
                        }
                    }
                }
            }
            Text("Look presets saved from the editor are files in this folder. Existing presets are not moved; copy them over to keep using them.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
    private func choosePresets() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Choose"; p.directoryURL = PresetsFolder.effective(s.presetsDirectory)
        if p.runModal() == .OK, let url = p.url { s.presetsDirectory = url; PresetsFolder.apply(url) }
    }
}

struct QuickExportSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            Section("Quick export settings") {
                Picker("Format", selection: format) { ForEach(ExportSettings.primaryFormats, id: \.self) { Text($0 == .gif ? "GIF" : "MP4").tag($0) } }
                Picker("Resolution", selection: $s.quickExport.outputHeight) {
                    ForEach(ExportSettings.heights(for: s.quickExport.format), id: \.self) { Text($0 == 2160 ? "4K" : String($0) + "p").tag($0) }
                }
                Picker("Frame rate", selection: $s.quickExport.fps) { ForEach(ExportSettings.frameRates(for: s.quickExport.format), id: \.self) { Text("\($0) fps").tag($0) } }
                if s.quickExport.format != .gif {
                    Picker("Compression", selection: compression) { ForEach(ExportSettings.Compression.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Picker("Codec", selection: $s.quickExport.codec) {
                        ForEach(ExportSettings.codecs(for: .clipboard), id: \.self) { Text($0 == .h264 ? "H.264" : "HEVC").tag($0) }
                    }
                    Toggle("Include audio", isOn: $s.quickExport.includeAudio)
                }
            }
            Toggle("Show quick export widget after recording", isOn: $s.showQuickExportWidget)
            Text("The widget offers Copy, Save and Edit instead of opening the editor right away. Quick export uses the settings above; Copy and Save in the widget, the Record menu and the shortcuts all use them.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Always keep the project after using the widget", isOn: $s.alwaysKeepProjectAfterQuickExport)
            Text("Off: closing the widget after a Copy or Save asks whether to keep the project or move it to the Trash.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("After a quick export", selection: $s.actionAfterQuickExport) { ForEach(ActionAfterQuickExport.allCases) { Text($0.title).tag($0) } }
            Picker("After recording", selection: $s.afterRecording) { ForEach(AfterRecording.allCases) { Text($0.title).tag($0) } }
        }.formStyle(.grouped)
    }
    private var format: Binding<ExportSettings.Format> {
        Binding(get: { s.quickExport.format }, set: { f in
            var e = s.quickExport; e.format = f
            e.includeAudio = f == .gif ? false : AppSettings.defaultQuickExport.includeAudio
            s.quickExport = e.closestValidPreset(for: .file)
        })
    }
    private var compression: Binding<ExportSettings.Compression> {
        Binding(get: { s.quickExport.compression ?? .social }, set: { c in
            var e = s.quickExport; e.compression = c
            s.quickExport = e.closestValidPreset(for: .file)
        })
    }
}

/// The Shortcuts tab: Recording (global) and Editing (the editor's single keys, via EditorKeyBindings); both rebindable.
struct ShortcutSettings: View {
    enum Group: String, CaseIterable, Identifiable { case recording = "Recording", editing = "Editing"; var id: String { rawValue } }
    @EnvironmentObject var s: AppSettings
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @State private var group = Group.recording

    @State private var editingRefresh = 0
    @State private var editingRefused: String?

    var body: some View {
        let conflicts = HotkeyManager.conflicts(in: s)
        Form {
            Picker("", selection: $group) { ForEach(Group.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            if group == .recording {
                Section("Recording (work from any app)") { ForEach(HotkeyAction.allCases.filter(\.isGlobal)) { row($0, conflicts) } }
                Section("In Yapcam") { ForEach(HotkeyAction.allCases.filter { !$0.isGlobal }) { row($0, conflicts) } }
                Button("Restore defaults") { s.resetShortcuts() }
            } else {
                Section("Editor keys") {
                    ForEach(EditorKeyBindings.actions) { a in
                        LabeledContent(a.title) {
                            HStack(spacing: 8) {
                                SingleKeyRecorder(key: Binding(
                                    get: { EditorKeyBindings.shared.key(for: a.id) },
                                    set: { k in
                                        editingRefused = EditingKeyRules.setKey(k, for: a.id) ? nil : "“\(String(k).uppercased())” is already used or reserved."
                                        editingRefresh += 1
                                    }), refresh: editingRefresh)
                                Button { _ = EditingKeyRules.setKey(nil, for: a.id); editingRefresh += 1 } label: { Image(systemName: "arrow.counterclockwise") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Back to \(String(a.defaultKey).uppercased())")
                                    .accessibilityLabel("Reset \(a.title) key").disabled(EditorKeyBindings.shared.key(for: a.id) == a.defaultKey)
                            }
                        }
                    }
                }
                if let editingRefused { Label(editingRefused, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                Button("Restore defaults") { EditorKeyBindings.shared.resetAll(); editingRefused = nil; editingRefresh += 1 }
                    .disabled(!EditorKeyBindings.shared.isCustomized)
                Text("Single keys, active while an editor window is in front.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .onChange(of: s.shortcuts) { _, _ in hotkeys.rebind() }
    }

    private func row(_ a: HotkeyAction, _ conflicts: Set<HotkeyAction>) -> some View {
        LabeledContent(a.title) {
            HStack(spacing: 8) {
                if hotkeys.failed.contains(a) || conflicts.contains(a) {
                    Label(conflicts.contains(a) ? "Already used" : "Not able to register", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).labelStyle(.titleAndIcon)
                }
                ShortcutRecorder(combo: Binding(get: { s.combo(for: a) ?? .none }, set: { s.setCombo($0.isNone ? nil : $0, for: a) }))
                Button { s.setCombo(nil, for: a) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Clear shortcut").accessibilityLabel("Clear \(a.title) shortcut")
                    .disabled(s.combo(for: a) == nil)
            }
        }
    }
}

struct AdvancedSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            Picker("Frame rate", selection: $s.maxFPS) { Text("Automatic (display rate)").tag(0); Text("Up to 30 fps").tag(30); Text("Up to 60 fps").tag(60) }
            Text("Automatic follows your display's refresh rate. A cap is only for slower Macs or smaller files.").font(.caption).foregroundStyle(.secondary)
            Toggle("Disable hardware-accelerated encoding", isOn: $s.disableHardwareEncoding)
            Text("Exports use the software video encoder. Slower, but can avoid encoder problems. Decoding is managed by macOS.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Hide desktop icons while recording", isOn: $s.hideDesktopIcons)
            Text("Desktop icons are excluded from the recording. Finder and your desktop stay unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Reset window positions") {
                WindowPositions.resetAll()
                ToolbarPanelController.shared.hide(); ToolbarPanelController.shared.show()
                CameraPreviewPanel.shared.update()
            }
            .help("The toolbar, camera preview and Recordings window go back to their default places")
            Button("Show onboarding again") { s.hasCompletedOnboarding = false; OnboardingWindow.shared.show(reason: nil) }
            Button("Export diagnostics…") { ProjectActions.exportDiagnostics() }
            Button("Open logs folder") {
                NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Yapcam"))
            }
        }.formStyle(.grouped)
    }
}

/// Start at login through the system's login-item service. `set` returns a message when macOS refuses.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if on, SMAppService.mainApp.status == .requiresApproval { return "Allow Yapcam in System Settings → General → Login Items." }
            return nil
        } catch {
            return "Couldn't change the login item (\(UserMessage.clean(error.localizedDescription, fallback: "unknown problem"))). It works from the installed app."
        }
    }
}

/// Click, then press the new combination. Esc cancels.
/// What a key press means while a shortcut recorder is waiting (Esc cancels; a usable combo is taken; anything else beeps).
enum RecorderKey {
    enum Outcome<Value: Equatable>: Equatable { case cancel, accept(Value), reject }
    static let escape: UInt16 = 53
    static func decide(keyCode: UInt16, combo: KeyCombo?) -> Outcome<KeyCombo> {
        if keyCode == escape { return .cancel }
        if let combo { return .accept(combo) }
        return .reject
    }
    static func decideEditing(keyCode: UInt16, chars: String?, modifiers: NSEvent.ModifierFlags) -> Outcome<Character> {
        if keyCode == escape { return .cancel }
        if let c = EditingKeyRules.character(chars: chars, modifiers: modifiers) { return .accept(c) }
        return .reject
    }
}

/// Pure rules for the Editing tab, so they can be tested without UI.
enum EditingKeyRules {
    /// The editor key a key-down stands for: one printable character, no ⌘/⌃/⌥.
    static func character(chars: String?, modifiers: NSEvent.ModifierFlags) -> Character? {
        guard modifiers.intersection([.command, .control, .option]).isEmpty, let c = chars, c.count == 1 else { return nil }
        return c.first
    }
    @discardableResult static func setKey(_ k: Character?, for id: String, in b: EditorKeyBindings = .shared) -> Bool { b.setKey(k, for: id) }
}

/// Click, then press one key to rebind an editor action (Esc cancels).
struct SingleKeyRecorder: View {
    @Binding var key: Character
    var refresh = 0
    @State private var recording = false
    @State private var monitor: Any?
    var body: some View {
        Button(recording ? "Press a key…" : String(key).uppercased()) { recording ? stop() : start() }
            .frame(minWidth: 80).onDisappear { stop() }.id(refresh)
            .accessibilityLabel("Editor key").accessibilityValue(String(key).uppercased())
            .accessibilityHint("Activate, then press the new key")
    }
    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch RecorderKey.decideEditing(keyCode: e.keyCode, chars: e.charactersIgnoringModifiers, modifiers: e.modifierFlags) {
            case .cancel: stop()
            case .accept(let c): key = c; stop()
            case .reject: NSSound.beep()
            }
            return nil
        }
    }
    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press shortcut…" : (combo.isNone ? "Not set" : combo.display)) { toggle() }
            .frame(minWidth: 120)
            .onDisappear { stop() }
            .accessibilityLabel("Shortcut")
            .accessibilityValue(recording ? "Recording: press the new key combination, or Escape to cancel" : (combo.isNone ? "Not set" : combo.display))
            .accessibilityHint("Activate, then press the new key combination")
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch RecorderKey.decide(keyCode: e.keyCode, combo: KeyCombo(event: e)) {
            case .cancel: stop()
            case .accept(let c): combo = c; stop()
            case .reject: NSSound.beep()
            }
            return nil
        }
    }
    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Features that are off by default and may change.
struct ExperimentalSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            Toggle("Variable frame rate export", isOn: $s.experimentalVariableFrameRate)
            Text("Leaves out frames that are exact copies of the previous one, which makes files of mostly still screens smaller. Applies to quick export and to the editor Export dialog. Some players and editors handle variable frame rate poorly; leave off if you plan to edit the file elsewhere. GIFs are never affected.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Recording engine", value: "ScreenCaptureKit")
            Text("Yapcam has one capture engine, so there is nothing to choose.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}
