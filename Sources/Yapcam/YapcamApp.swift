import AppKit
import SwiftUI

@main
struct YapcamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // All windows are AppKit-managed; this scene only satisfies the App protocol.
        Settings { EmptyView() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let startStopKey = GlobalHotKey()
    private let pauseKey = GlobalHotKey()
    private var statusItem: NSStatusItem?
    private var recordingObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--probe-record") {
            let seconds = args.indices.contains(i + 1) ? Double(args[i + 1]) ?? 5 : 5
            Task {
                await Probe.report()
                do { Probe.log("record ok \(try await Probe.record(seconds: seconds).path)") }
                catch { Probe.log("record failed \(error)") }
                NSApp.terminate(nil)
            }
            return
        }

        if let i = args.firstIndex(of: "--snapshot-ui"), args.indices.contains(i + 1) {
            let dir = URL(filePath: args[i + 1], directoryHint: .isDirectory)
            Task { await UISnapshot.run(into: dir) }
            return
        }

        let settings = AppSettings.shared
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
        NSApp.mainMenu = MainMenu.build(target: self)
        applyMenuBarItem()
        bindShortcuts()

        ToolbarPanelController.shared.show()
        if !settings.hasCompletedOnboarding || PermissionsModel.shared.state(.screen) != .granted {
            OnboardingWindow.shared.show(reason: nil)
        }

        // Re-apply settings that need side effects.
        Task { @MainActor in
            for await _ in settings.objectWillChange.values {
                try? await Task.sleep(for: .milliseconds(50))
                self.applyLiveSettings()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ToolbarPanelController.shared.show()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if RecordingController.shared.isRecording {
            let a = NSAlert()
            a.messageText = "A recording is in progress"
            a.informativeText = "Quit and discard it, or keep recording."
            a.addButton(withTitle: "Keep Recording")
            a.addButton(withTitle: "Discard and Quit")
            if a.runModal() == .alertFirstButtonReturn { return .terminateCancel }
            RecordingController.shared.cancel()
        }
        return .terminateNow
    }

    // MARK: Shortcuts / settings side effects

    private var boundCombos: (KeyCombo, KeyCombo)?

    private func bindShortcuts() {
        let s = AppSettings.shared
        boundCombos = (s.startStopShortcut, s.pauseShortcut)
        if !startStopKey.register(s.startStopShortcut, action: { RecordingController.shared.toggleStartStop() }) {
            Probe.log("could not register start/stop shortcut \(s.startStopShortcut.display)")
        }
        if !pauseKey.register(s.pauseShortcut, action: { RecordingController.shared.togglePause() }) {
            Probe.log("could not register pause shortcut \(s.pauseShortcut.display)")
        }
    }

    private func applyLiveSettings() {
        let s = AppSettings.shared
        if let b = boundCombos, b != (s.startStopShortcut, s.pauseShortcut) { bindShortcuts() }
        let wanted: NSApplication.ActivationPolicy = s.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
        applyMenuBarItem()
    }

    // MARK: Menu bar item

    private func applyMenuBarItem() {
        if AppSettings.shared.showMenuBarItem {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Yapcam")
                item.menu = MainMenu.statusMenu(target: self)
                statusItem = item
            }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item); statusItem = nil
        }
    }

    // MARK: Actions

    @objc func toggleRecording() { RecordingController.shared.toggleStartStop() }
    @objc func togglePause() { RecordingController.shared.togglePause() }
    @objc func toggleToolbar() { ToolbarPanelController.shared.toggle() }
    @objc func showSettings() { SettingsWindow.shared.show() }
    @objc func showPermissions() { OnboardingWindow.shared.show(reason: nil) }
    @objc func openProject() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.treatsFilePackagesAsDirectories = false
        p.directoryURL = AppSettings.shared.storageDirectory
        p.message = "Choose a .yapcam recording"
        if p.runModal() == .OK, let url = p.url, url.pathExtension == "yapcam" {
            RecordingController.shared.engine.openEditor(package: url)
        }
    }
    @objc func showAbout() { AboutWindow.show() }
    @objc func showStorageFolder() { NSWorkspace.shared.open(AppSettings.shared.storageDirectory) }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let r = RecordingController.shared
        switch item.action {
        case #selector(toggleRecording):
            item.title = r.isRecording || r.phase == .countdown(0) ? "Stop Recording" : "Start Recording"
            if case .countdown = r.phase { item.title = "Cancel Countdown" }
            return r.phase != .starting && r.phase != .finishing
        case #selector(togglePause):
            item.title = r.phase == .paused ? "Resume Recording" : "Pause Recording"
            return r.isRecording
        case #selector(toggleToolbar):
            item.title = ToolbarPanelController.shared.isVisible ? "Hide Toolbar" : "Show Toolbar"
            return true
        default: return true
        }
    }
}
