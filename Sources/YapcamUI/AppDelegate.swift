import AppKit
import Speech
import Combine
import YapcamCapture
import YapcamEditor

/// Entry point used by the thin `Yapcam` executable.
@MainActor public enum YapcamAppMain {
    private static let delegate = AppDelegate()
    public static func run() -> Never {
        AppDefaults.isolateIfSelfTest(CommandLine.arguments)   // before anything reads a preference
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var recordingObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)   // Yapcam is dark-only (glass design)
        DispatchQueue.global(qos: .utility).async { QuickExport.pruneCache() }
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

        if args.contains("--capture-selftest") {
            Task { await SelfTests.runCapture(args); NSApp.terminate(nil) }
            return
        }
        if args.contains("--editor-selftest") { Task { await EditorSelfTests.run(args); NSApp.terminate(nil) }; return }
        if args.contains("--editor-reopen-check") { Task { await EditorSelfTests.reopenCheck(args); NSApp.terminate(nil) }; return }
        if args.contains("--editor-export-selftest") { Task { await EditorSelfTests.export(args); NSApp.terminate(nil) }; return }
        for (flag, drive) in [("--ui-record-selftest", false), ("--drive-input-selftest", true)] {
            if let i = args.firstIndex(of: flag) {
                let seconds = args.indices.contains(i + 1) ? Double(args[i + 1]) ?? 5 : 5
                let source = EditorSelfTests.argument(after: "--source", in: args)
                var options = SelfTestOptions()
                options.afterRecording = EditorSelfTests.argument(after: "--after-recording", in: args)
                options.saveTo = EditorSelfTests.argument(after: "--save-to", in: args)
                options.autoConfirm = args.contains("--auto-confirm")
                options.watchdog = EditorSelfTests.argument(after: "--watchdog", in: args).flatMap(Double.init)
                if let text = EditorSelfTests.argument(after: "--hotkey-script", in: args) {
                    var error: String?
                    guard let steps = HotkeyStep.parse(text, error: &error) else {
                        Probe.log("\(drive ? "drive-input" : "ui-record")-selftest failed bad --hotkey-script: \(error ?? "?")")
                        NSApp.terminate(nil); return
                    }
                    options.hotkeyScript = steps
                }
                Task { await SelfTests.runUIRecord(seconds: seconds, driveInput: drive, source: source, options: options); NSApp.terminate(nil) }
                return
            }
        }

        if let i = args.firstIndex(of: "--live-e2e"), args.indices.contains(i + 1) {
            let dir = URL(filePath: args[i + 1], directoryHint: .isDirectory)
            let kind = args.indices.contains(i + 2) ? args[i + 2] : "full"
            Task { if kind == "full" { await LiveE2E.run(into: dir) } else { await LiveE2E.scenario(kind, into: dir) } }
            return
        }

        if let i = args.firstIndex(of: "--design-lab-snapshot"), args.indices.contains(i + 1) {
            DesignLab.snapshot(into: URL(filePath: args[i + 1], directoryHint: .isDirectory)); return
        }
        if args.contains("--design-lab") { DesignLab.show(); return }

        if let i = args.firstIndex(of: "--snapshot-ui"), args.indices.contains(i + 1) {
            let dir = URL(filePath: args[i + 1], directoryHint: .isDirectory)
            Task { await UISnapshot.run(into: dir) }
            return
        }

        let settings = AppSettings.shared
        NSApp.setActivationPolicy(settings.activationPolicy)
        phaseObserver = RecordingController.shared.$phase.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.applyLiveSettings() }
        NSApp.mainMenu = MainMenu.build(target: self)
        applyMenuBarItem()
        bindShortcuts()

        ToolbarPanelController.shared.show()
        ToolbarEditorCoordinator.shared.start()
        DesktopIcons.restoreIfNeeded()
        installTranscriber()
        PresetsFolder.apply(AppSettings.shared.presetsDirectory)
        EditorHooks.install(AppSettings.shared)
        EditorWindows.appearance = AppSettings.shared.editorAppearance
        EditorWindows.hardwareEncodingEnabled = { AppSettings.hardwareEncodingEnabledInStore() }   // Settings → Advanced reaches editor exports
        AreaOutline.shared.start()
        offerRecovery()
        if !settings.hasCompletedOnboarding || PermissionsModel.shared.state(.screen) != .granted {
            OnboardingWindow.shared.show(reason: nil)
        }

        // Re-apply settings that need side effects.
        // A sink, not `objectWillChange.values`: AsyncPublisher traps when two settings change back to back
        // (e.g. Start on the display overlay sets displayID and sourceMode) while the loop is still sleeping.
        settingsObserver = settings.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.applyLiveSettings() } }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { ProjectActions.open(u) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        EditorWindows.saveAll()
        DesktopIcons.restoreIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if RecordingController.shared.isRecording { RecordingController.shared.confirmFinish(); return false }
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
            // Wait until the capture layer has deleted the package before exiting.
            Task { @MainActor in
                await RecordingController.shared.cancelAndWait()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        // Stop pressed (or recording still starting) and then Quit: let the capture layer finish writing and the
        // markers/notes be stored; give up after a few seconds so Quit can never hang.
        let phase = RecordingController.shared.phase
        if phase == .starting || phase == .finishing {
            let replied = OnceFlag()
            Task { @MainActor in
                await RecordingController.shared.settle()
                if replied.take() { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                if replied.take() { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            return .terminateLater
        }
        return .terminateNow
    }

    /// Editor's "Generate captions from speech" runs capture's on-device transcription.
    func installTranscriber() {
        EditorWindows.transcriber = { package in
            try await TranscriptionWiring.transcribe(package: package, options: TranscriptionOptions(), using: TranscriptionWiring.live)
        }
        EditorWindows.transcriberWithOptions = { package, options in
            try await TranscriptionWiring.transcribe(package: package, options: options, using: TranscriptionWiring.live)
        }
        EditorWindows.languageProvider = { TranscriptionWiring.languages(from: Array(SFSpeechRecognizer.supportedLocales())) }
    }

    /// Interrupted recordings from a previous run: offer recovery instead of silently ignoring them.
    private func offerRecovery() { RecoveryFlow.run(silentWhenNone: true) }

    // MARK: Shortcuts / settings side effects

    private var boundShortcuts: [String: KeyCombo] = [:]

    private func bindShortcuts() {
        boundShortcuts = AppSettings.shared.shortcuts
        HotkeyManager.shared.rebind()
    }

    private func applyLiveSettings() {
        let s = AppSettings.shared
        if boundShortcuts != s.shortcuts {
            bindShortcuts()
            NSApp.mainMenu = MainMenu.build(target: self)      // menu shortcuts follow the settings
        }
        let wanted = s.activationPolicy
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
                observeRecordingForTray()
            }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item); statusItem = nil
        }
    }

    private var trayObserver: AnyCancellable?
    private var settingsObserver: AnyCancellable?
    private var phaseObserver: AnyCancellable?

    /// While recording the menu bar icon becomes a stop button; idle it is the app glyph with its menu.
    private func observeRecordingForTray() {
        trayObserver = RecordingController.shared.$phase.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] phase in
            guard let item = self?.statusItem, let button = item.button else { return }
            if phase == .recording || phase == .paused {
                item.menu = nil
                button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
                button.contentTintColor = .systemRed
                button.target = self; button.action = #selector(AppDelegate.toggleRecording)
            } else {
                button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Yapcam")
                button.contentTintColor = nil
                button.action = nil
                item.menu = MainMenu.statusMenu(target: self!)
            }
        }
    }

    // MARK: Actions

    @objc func toggleRecording() { RecordingController.shared.toggleStartStop() }
    @objc func togglePause() { RecordingController.shared.togglePause() }
    @objc func toggleToolbar() { ToolbarEditorCoordinator.shared.userToggled(); ToolbarPanelController.shared.toggle() }
    @objc func addMarker() { RecordingController.shared.addMarker() }
    @objc func restartRecording() { RecordingController.shared.confirmRestart() }
    @objc func cancelRecording() { RecordingController.shared.confirmCancel() }
    @objc func openLastRecording() { ProjectActions.openLast() }
    @objc func quickExportCopy() { QuickExport.shared.runOnLast(.copy) }
    @objc func quickExportSave() { QuickExport.shared.runOnLast(.save) }
    @objc func showNotes() { NotesWindow.shared.show() }
    @objc func showSettings() { SettingsWindow.shared.show() }

    // MARK: Dock menu (right-click on the Dock icon)
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for it in DockMenu.items(phase: RecordingController.shared.phase, showInDock: AppSettings.shared.showInDock) {
            if it.kind == .separator { menu.addItem(.separator()); continue }
            let sel: Selector
            switch it.kind {
            case .finish: sel = #selector(dockFinish)
            case .pauseResume: sel = #selector(dockPauseResume)
            case .restart: sel = #selector(dockRestart)
            case .cancel: sel = #selector(dockCancel)
            case .cancelCountdown: sel = #selector(dockCancelCountdown)
            case .settings: sel = #selector(showSettings)
            case .newRecording: sel = #selector(dockNewRecording)
            case .openLast: sel = #selector(openLastRecording)
            case .keepInDock: sel = #selector(dockToggleKeep)
            case .separator: continue
            }
            let mi = NSMenuItem(title: it.title, action: sel, keyEquivalent: "")
            mi.target = self; mi.isEnabled = it.enabled; mi.state = it.checked ? .on : .off
            menu.addItem(mi)
        }
        return menu
    }
    @objc func dockFinish() { RecordingController.shared.stop() }          // an explicit menu click: no confirmation
    @objc func dockPauseResume() { RecordingController.shared.togglePause() }
    @objc func dockRestart() { RecordingController.shared.confirmRestart() }
    @objc func dockCancel() { RecordingController.shared.confirmCancel() }
    @objc func dockCancelCountdown() { RecordingController.shared.cancelCountdown() }
    @objc func dockNewRecording() { ToolbarPanelController.shared.show() }
    @objc func dockToggleKeep() { AppSettings.shared.showInDock.toggle() }
    @objc func showPermissions() { OnboardingWindow.shared.show(reason: nil, all: true) }
    @objc func openProject() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.treatsFilePackagesAsDirectories = false
        p.directoryURL = AppSettings.shared.storageDirectory
        p.allowsMultipleSelection = true
        p.message = "Choose one or more .yapcam recordings"
        guard p.runModal() == .OK else { return }
        for url in p.urls { ProjectActions.open(url) }       // each one reports on its own when it can't be opened
    }
    @objc func recoverRecording() { RecoveryFlow.run(silentWhenNone: false) }
    @objc func saveProjectAs() { if let u = EditorBridge.keyDocument()?.project.packageURL { ProjectActions.saveAs(u) } }
    @objc func copyAndZipProject() { if let u = EditorBridge.keyDocument()?.project.packageURL { ProjectActions.copyAndZip(u) } }
    @objc func moveProjectToTrash() { _ = EditorWindows.requestTrashOfKeyEditor() }
    @objc func renameProject() {
        guard let u = EditorBridge.keyDocument()?.project.packageURL else { return }
        let name = u.deletingPathExtension().lastPathComponent
        guard let typed = Prompt.text(title: "Rename Project", message: "New name for “\(name)”", initial: name) else { return }
        do {
            let dest = try ProjectActions.rename(u, to: typed)      // closes (and so saves) the editor first
            if dest != u { RecordingController.shared.engine.openEditor(package: dest) }
        } catch { RecordingController.shared.alert = AppAlert(title: "Could not rename", error: error) }
    }
    @objc func showProjectInFinder() { if let u = EditorBridge.keyDocument()?.project.packageURL { FinderReveal.show(u) } }
    @objc func showRecordings() { RecentProjectsWindow.shared.show() }
    @objc func importVideo() { ProjectActions.importVideo() }
    @objc func exportDiagnostics() { ProjectActions.exportDiagnostics() }
    @objc func editUndo() {
        if EditorBridge.isEditingText { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { EditorBridge.keyEditor()?.undo() }
    }
    @objc func editRedo() {
        if EditorBridge.isEditingText { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { EditorBridge.keyEditor()?.redo() }
    }
    @objc func editSplit() { EditorBridge.keyEditor()?.splitAtPlayhead() }
    @objc func editAddZoom() { EditorBridge.keyEditor()?.addZoomAtPlayhead() }
    @objc func editPalette() { EditorBridge.keyEditor()?.paletteVisible = true }
    @objc func showAbout() { AboutWindow.show() }
    @objc func showThirdPartyNotices() { ThirdPartyNotices.open() }
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
        case #selector(saveProjectAs), #selector(copyAndZipProject), #selector(showProjectInFinder), #selector(moveProjectToTrash), #selector(renameProject): return EditorBridge.keyDocument() != nil
        case #selector(addMarker): return r.phase == .recording
        case #selector(restartRecording), #selector(cancelRecording): return r.isRecording
        case #selector(togglePause):
            item.title = r.phase == .paused ? "Resume Recording" : "Pause Recording"
            return r.isRecording
        case #selector(editUndo): return EditorBridge.isEditingText || (EditorBridge.keyEditor()?.canUndo ?? false)
        case #selector(editRedo): return EditorBridge.isEditingText || (EditorBridge.keyEditor()?.canRedo ?? false)
        case #selector(editSplit), #selector(editAddZoom), #selector(editPalette): return EditorBridge.keyEditor() != nil
        case #selector(toggleToolbar):
            item.title = ToolbarPanelController.shared.isVisible ? "Hide Toolbar" : "Show Toolbar"
            return true
        default: return true
        }
    }
}

/// First caller wins; used to answer the terminate request exactly once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if taken { return false }; taken = true; return true }
}
