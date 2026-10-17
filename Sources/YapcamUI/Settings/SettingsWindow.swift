import AppKit
import ServiceManagement
import SwiftUI
import YapcamRender

@MainActor final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
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

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            RecordingSettings().tabItem { Label("Recording", systemImage: "record.circle") }
            EditingSettings().tabItem { Label("Editing", systemImage: "slider.horizontal.3") }
            QuickExportSettings().tabItem { Label("Quick export", systemImage: "square.and.arrow.up") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            ExperimentalSettings().tabItem { Label("Experimental", systemImage: "flask") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
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
            Text("Off: new projects start from your default preset (or the standard look). On: from the look of the most recently edited project instead; with no earlier project the default preset is used.")
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

/// The Shortcuts tab: Recording (rebindable, global) and Editing (the editor's fixed keys, shown for reference).
struct ShortcutSettings: View {
    enum Group: String, CaseIterable, Identifiable { case recording = "Recording", editing = "Editing"; var id: String { rawValue } }
    @EnvironmentObject var s: AppSettings
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @State private var group = Group.recording

    static let editingKeys: [(String, String)] = [
        ("Cut slice at current time", "C"), ("Remove slice before previous cut", "X"),
        ("Play or increase speed", "L"), ("Play backward or increase speed", "J"), ("Stop and reset speed", "K"),
    ]

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
                    ForEach(Self.editingKeys, id: \.0) { LabeledContent($0.0, value: $0.1) }
                }
                Text("The editor's keys are fixed for now. They work while an editor window is in front.").font(.caption).foregroundStyle(.secondary)
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
            Picker("Frame rate", selection: $s.maxFPS) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
            Text("Recording follows your display; this only caps the rate. 60 is right for almost everyone.").font(.caption).foregroundStyle(.secondary)
            Toggle("Hide desktop icons while recording", isOn: $s.hideDesktopIcons)
            Text("Restarts Finder briefly. Icons are restored when recording ends, and on the next launch if Yapcam quit unexpectedly.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Reset toolbar position") {
                for key in AppDefaults.store.dictionaryRepresentation().keys where key.hasPrefix(ToolbarPanelController.positionKeyPrefix) {
                    AppDefaults.store.removeObject(forKey: key)
                }
                ToolbarPanelController.shared.hide(); ToolbarPanelController.shared.show()
            }
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
            if e.keyCode == 53 { stop(); return nil }
            if let c = KeyCombo(event: e) { combo = c; stop() } else { NSSound.beep() }
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
