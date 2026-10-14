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
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            StorageSettings().tabItem { Label("Storage", systemImage: "internaldrive") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520, height: 400)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            Picker("Countdown", selection: $s.countdown) {
                Text("None").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5)
            }
            Toggle("Open the editor when a recording stops", isOn: $s.openEditorAfterRecording)
            Section("Appearance of the app") {
                Toggle("Show in Dock", isOn: $s.showInDock)
                Toggle("Show menu bar item", isOn: $s.showMenuBarItem)
            }
            Section("Permissions") {
                Button("Review permissions…") { OnboardingWindow.shared.show(reason: nil) }
            }
        }.formStyle(.grouped)
    }
}

private struct RecordingSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            Picker("Frame rate", selection: $s.maxFPS) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
            Toggle("Hide desktop icons while recording", isOn: $s.hideDesktopIcons)
            Text("Restarts Finder briefly. Icons are restored when recording ends, and on the next launch if Yapcam quit unexpectedly.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Play start and stop sounds", isOn: $s.playSounds)
            Toggle("Record keystrokes", isOn: $s.recordKeystrokes)
            Text("Keystrokes are stored with the recording to show key overlays in the editor. Needs Input Monitoring permission. Never uploaded anywhere.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

private struct ShortcutSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            LabeledContent("Start / stop recording") { ShortcutRecorder(combo: $s.startStopShortcut) }
            LabeledContent("Pause / resume") { ShortcutRecorder(combo: $s.pauseShortcut) }
            Button("Restore defaults") { s.resetShortcuts() }
        }.formStyle(.grouped)
    }
}

private struct StorageSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            LabeledContent("Recordings folder") {
                VStack(alignment: .trailing) {
                    Text(s.storageDirectory.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                    HStack {
                        Button("Choose…") { choose() }
                        Button("Show in Finder") { NSWorkspace.shared.open(s.storageDirectory) }
                    }
                }
            }
            if let free = freeSpace {
                LabeledContent("Free space", value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
            }
            Text("Each recording is a .yapcam package in this folder. Nothing leaves your Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
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

private struct AdvancedSettings: View {
    @EnvironmentObject var s: AppSettings
    var body: some View {
        Form {
            Button("Reset toolbar position") {
                for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("toolbarPos.") {
                    UserDefaults.standard.removeObject(forKey: key)
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
        Button(recording ? "Press shortcut…" : combo.display) { toggle() }
            .frame(minWidth: 120)
            .onDisappear { stop() }
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
