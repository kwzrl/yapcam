import AppKit
import SwiftUI

@MainActor final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 400),
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
            StorageSettings().tabItem { Label("Storage", systemImage: "internaldrive") }
            ExperimentalSettings().tabItem { Label("Experimental", systemImage: "flask") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520, height: 400)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            Picker("Countdown", selection: $s.countdown) {
                Text("None").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5); Text("10 seconds").tag(10)
            }
            Section("Appearance of the app") {
                Toggle("Show recording widget while recording", isOn: $s.showRecordingWidget)
                Toggle("Show in Dock", isOn: $s.showInDock)
                Toggle("Show menu bar item", isOn: $s.showMenuBarItem)
            }
            Section("Permissions") {
                Button("Review permissions…") { OnboardingWindow.shared.show(reason: nil, all: true) }
            }
        }.formStyle(.grouped)
    }
}

struct RecordingSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            Picker("Frame rate", selection: $s.maxFPS) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
            CameraResolutionRow()
            LabeledContent("System audio") { SystemAudioPicker().frame(width: 280) }
            Toggle("Hide desktop icons while recording", isOn: $s.hideDesktopIcons)
            Text("Restarts Finder briefly. Icons are restored when recording ends, and on the next launch if Yapcam quit unexpectedly.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Play start and stop sounds", isOn: $s.playSounds)
            Toggle("Highlight the recorded area", isOn: $s.highlightRecordedArea)
            Text("While recording an area, the rest of the display is dimmed. The dimming is never part of the recording.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Record keystrokes", isOn: $s.recordKeystrokes)
            Text("Keystrokes are stored with the recording to show key overlays in the editor. Needs Input Monitoring permission. Never uploaded anywhere.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

struct EditingSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            Toggle("Create zooms automatically", isOn: $s.createAutoZooms)
            Text("New recordings get zooms placed from your clicks. You can change or remove them in the editor.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("New projects reuse the last project's look", isOn: $s.reuseLastProjectSettings)
            Text("Off: new projects start from your default preset (or the standard look). On: from the look of the most recently edited project instead; with no earlier project the default preset is used.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Save edits automatically", isOn: $s.autosaveEnabled)
            Text(s.autosaveEnabled ? "Edits are saved 30 seconds after your last change. Closing a project window and quitting always save."
                                   : "Edits are saved only when you close the project window or quit. A crash can lose changes since then.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

struct QuickExportSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            Picker("After recording", selection: $s.afterRecording) { ForEach(AfterRecording.allCases) { Text($0.title).tag($0) } }
            Toggle("Show quick export widget after recording", isOn: $s.showQuickExportWidget)
            Text("The widget offers Copy, Save and Edit instead of opening the editor right away. Quick export makes a 1080p MP4 with audio.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

struct ShortcutSettings: View {
    @EnvironmentObject var s: AppSettings
    @ObservedObject private var hotkeys = HotkeyManager.shared

    var body: some View {
        let conflicts = HotkeyManager.conflicts(in: s)
        Form {
            Section("Recording (work from any app)") { ForEach(HotkeyAction.allCases.filter(\.isGlobal)) { row($0, conflicts) } }
            Section("In Yapcam") { ForEach(HotkeyAction.allCases.filter { !$0.isGlobal }) { row($0, conflicts) } }
            Button("Restore defaults") { s.resetShortcuts() }
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

struct StorageSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            LabeledContent("Recordings folder") {
                VStack(alignment: .trailing) {
                    Text((s.storageDirectory.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    HStack {
                        Button("Choose…") { choose() }
                        Button("Show in Finder") { NSWorkspace.shared.open(s.storageDirectory) }
                    }
                }
            }
            LabeledContent("Presets folder") {
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
            if let free = freeSpace {
                LabeledContent("Free space", value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
            }
            Text("Each recording is a .yapcam package in this folder. Nothing leaves your Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
    private func choosePresets() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Choose"; p.directoryURL = PresetsFolder.effective(s.presetsDirectory)
        if p.runModal() == .OK, let url = p.url { s.presetsDirectory = url; PresetsFolder.apply(url) }
    }
    private var freeSpace: Int64? {
        try? s.storageDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = s.storageDirectory
        if p.runModal() == .OK, let url = p.url { s.storageDirectory = url }
    }
}

struct AdvancedSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
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
