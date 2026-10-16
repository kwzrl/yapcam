import AppKit
import SwiftUI
import YapcamCore

enum RecordingPhase: Equatable {
    case idle
    case countdown(Int)
    case starting
    case recording
    case paused
    case finishing
}

/// Owns the recording lifecycle for the UI: countdown → start → pause/resume → stop → editor.
@MainActor final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    @Published private(set) var phase: RecordingPhase = .idle {
        didSet {
            phaseChanged(from: oldValue)
            switch (oldValue, phase) {
            case (_, .recording) where oldValue != .paused: Announcer.say("Recording started")
            case (_, .paused): Announcer.say("Recording paused")
            case (.paused, .recording): Announcer.say("Recording resumed")
            case (_, .idle) where oldValue == .finishing: Announcer.say("Recording stopped")
            default: break
            }
        }
    }
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var warnings: [String] = []
    @Published private(set) var lowDisk = false
    /// Fills 0…1 over the countdown (the ring on the Get-ready card).
    @Published private(set) var countdownProgress = 0.0
    /// True when starting/finishing takes longer than 3 s: the widget then says "Working…".
    @Published private(set) var workingLong = false
    /// Markers added with the flag button or shortcut, in recording time (pauses excluded).
    @Published private(set) var markers: [Int64] = []
    @Published var prompterPlaying = true
    /// The package of the last finished recording (quick export and "open last").
    private(set) var lastPackage: URL?
    private var skipRequested = false
    private var hidToolbarForRecording = false
    /// Speaker notes typed before or during a recording; saved into the project on stop.
    @Published var notes = ""
    @Published var alert: AppAlert?

    /// Self-tests only (`--auto-confirm`): answer confirmation dialogs with the destructive choice instead of blocking.
    nonisolated(unsafe) static var autoConfirm = false

    var engine: RecordingEngine = LiveEngine()
    var cuePlayer: CuePlayer = ChimePlayer()
    /// After-recording delivery (editor, quick export). Replaceable in tests.
    lazy var deliver: (URL) async -> Void = { [unowned self] url in
        await PostRecording.deliver(package: url, controller: self)
    }

    /// Waits until the start in progress and every queued capture operation (including stop's finalization)
    /// have finished; used by Quit.
    func settle() async {
        await startTask?.value
        await opChain?.value
    }
    private let settings = AppSettings.shared
    private var session: EngineSession?
    private var countdownTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var ticker: Timer?
    private let countdownWindow = CountdownWindow()
    private var lastOptions: UIRecordingOptions?
    private var tickCount = 0

    var isBusy: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording || phase == .paused }

    private func phaseChanged(from old: RecordingPhase) {
        // Dock badge while recording, like the reference.
        NSApp?.dockTile.badgeLabel = (phase == .recording || phase == .paused) ? "●" : nil
        workingLong = false
        if phase == .starting || phase == .finishing {
            let marker = phase
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if let self, self.phase == marker { self.workingLong = true }
            }
        }
        // "Show recording widget" off: the toolbar steps aside while recording and returns afterwards.
        if phase == .recording, old != .paused, !settings.showRecordingWidget, ToolbarPanelController.shared.isVisible {
            ToolbarPanelController.shared.hide(); hidToolbarForRecording = true
        }
        if phase == .idle, hidToolbarForRecording { hidToolbarForRecording = false; ToolbarPanelController.shared.show() }
    }

    /// UI snapshot tooling only: forces a phase without a session.
    func debugSetCountdownProgress(_ v: Double) { countdownProgress = v }
    func debugSetPhase(_ p: RecordingPhase) { phase = p; if p == .recording || p == .paused { elapsed = 754 } }

    // MARK: Entry points (toolbar button, menu, global shortcut)

    func toggleStartStop() {
        switch phase {
        case .idle: begin()
        case .countdown: cancelCountdown()
        case .recording, .paused: stop()
        case .starting, .finishing: break
        }
    }

    func togglePause() {
        switch phase {
        case .recording: pause()
        case .paused: resume()
        default: break
        }
    }

    func begin() {
        guard phase == .idle, !preflighting else { return }
        // A source overlay is open: Start means "record what the overlay shows", not the previously saved source.
        if SourceOverlay.shared.isActive { SourceOverlay.shared.commit(); return }
        if AreaSelector.shared.isActive { AreaSelector.shared.commit(); return }
        let perms = PermissionsModel.shared
        perms.refresh()
        if settings.sourceMode != .device, perms.state(.screen) != .granted {
            OnboardingWindow.shared.show(reason: "Screen recording permission is required to record.")
            return
        }
        // Clicks need Input Monitoring: ask the first time instead of up front.
        if perms.state(.inputMonitoring) != .granted, !perms.hasRequested(.inputMonitoring) { perms.request(.inputMonitoring) }
        let options: UIRecordingOptions
        do { options = try makeOptions() } catch {
            alert = AppAlert(title: "Can't start recording", error: error)
            return
        }
        preflightThenStart(options)
    }

    // MARK: Pre-flight (GAP-CAP-6)

    /// Asks one question per condition; the answer is the user's, never a silent default. Test hook.
    var askPreflight: @MainActor (PreflightIssue, [PreflightChoice]) -> PreflightChoice = PreflightFlow.askWithAlert
    /// "Choose device…" / "Open System Settings": where the answer leads. Test hook.
    var routePreflight: (PreflightOutcome) -> Void = { outcome in
        switch outcome {
        case .chooseDevice: SettingsWindow.shared.show()
        case .openSettings(let p): PermissionsModel.shared.open(p)
        default: break
        }
    }
    private(set) var preflighting = false

    func preflightThenStart(_ options: UIRecordingOptions) {
        preflighting = true
        // The checks look at what the user chose, including devices that are gone.
        var chosen = options
        chosen.microphoneID = settings.microphoneID
        chosen.cameraID = settings.cameraID
        Task { [weak self] in
            guard let self else { return }
            let issues = await self.engine.preflight(chosen)
            self.preflighting = false
            guard self.phase == .idle else { return }
            let outcome = PreflightFlow.resolve(issues, systemAudioApps: options.systemAudioApps, ask: self.askPreflight)
            switch outcome {
            case .start(let apps):
                var o = options
                o.systemAudioApps = apps
                self.lastOptions = o
                self.runCountdown(then: o)
            case .cancel: break
            case .chooseDevice, .openSettings: self.routePreflight(outcome)
            }
        }
    }

    // MARK: Options

    func makeOptions() throws -> UIRecordingOptions {
        let target: UITarget
        switch settings.sourceMode {
        case .display:
            guard let d = Displays.resolve(settings.displayID) else { throw EngineError.failed("No display found.") }
            // A display that was chosen and is gone must not silently turn into the main display.
            if settings.displayID != 0, Displays.info(for: settings.displayID) == nil {
                throw EngineError.failed("The display you chose is not connected any more. Choose the display again with the Display button.")
            }
            target = .display(d.id)
        case .window:
            guard settings.windowID != 0 else { throw EngineError.failed("Choose a window to record first.") }
            let alive = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(settings.windowID)) as? [[String: Any]])?.isEmpty == false
            guard alive else { throw EngineError.failed("The selected window is no longer available. Choose another window.") }
            target = .window(settings.windowID)
        case .device:
            // A fresh look: the phone may have been unplugged since the popover last polled.
            let list = (try? DeviceScreensModel.currentDevices()) ?? []
            guard !list.isEmpty else { throw EngineError.failed(DeviceScreensModel.notFoundMessage) }
            guard let device = list.first(where: { $0.id == settings.deviceID }) ?? (list.count == 1 ? list[0] : nil) else {
                throw EngineError.failed("More than one iPhone or iPad is connected. Choose which one to record in the Device source.")
            }
            target = .device(device.id)
        case .area:
            guard let saved = settings.areaRect, let display = Displays.info(for: settings.areaDisplayID) else {
                throw EngineError.failed("Select an area to record first, or pick Display instead.")
            }
            guard AreaGeometry.canRecord(saved) else { throw EngineError.failed("The area must be at least \(Int(AreaGeometry.recordMin)) × \(Int(AreaGeometry.recordMin)) points. Choose it again.") }
            // The display may have changed resolution or arrangement since the area was chosen.
            guard let rect = AreaGeometry.fit(saved, in: display.frame.size) else {
                throw EngineError.failed("The saved area no longer fits on “\(display.name)”. Choose the area again.")
            }
            // Clipping to a smaller display can shrink it below the minimum.
            guard AreaGeometry.canRecord(rect) else {
                throw EngineError.failed("The saved area no longer fits on “\(display.name)” at the minimum size of \(Int(AreaGeometry.recordMin)) × \(Int(AreaGeometry.recordMin)) points. Choose the area again.")
            }
            target = .area(display: display.id, rect: rect)
        }
        try FileManager.default.createDirectory(at: settings.storageDirectory, withIntermediateDirectories: true)
        if let free = try? settings.storageDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < 1_000_000_000 {
            throw EngineError.diskFull(availableBytes: free)
        }
        return UIRecordingOptions(
            target: target,
            systemAudio: settings.systemAudio,
            systemAudioApps: settings.systemAudioAppsForRecording,
            microphoneID: PermissionsModel.shared.state(.microphone) == .granted && DeviceModel.shared.isAvailable(microphone: settings.microphoneID) ? settings.microphoneID : nil,
            cameraID: PermissionsModel.shared.state(.camera) == .granted && DeviceModel.shared.isAvailable(camera: settings.cameraID) ? settings.cameraID : nil,
            cameraMaxResolution: settings.cameraMaxResolution,
            recordKeystrokes: settings.recordKeystrokes && PermissionsModel.shared.state(.inputMonitoring) == .granted,
            maxFPS: settings.maxFPS,
            outputDirectory: settings.storageDirectory)
    }

    private func screenForCountdown(_ o: UIRecordingOptions) -> NSScreen? {
        switch o.target {
        case .display(let id), .area(let id, _): return Displays.screen(for: id)
        case .window, .device: return NSScreen.main
        }
    }

    // MARK: Countdown

    private func runCountdown(then options: UIRecordingOptions) {
        let n = settings.countdown
        guard n > 0 else { startSession(options); return }
        skipRequested = false
        countdownProgress = 0
        phase = .countdown(n)
        countdownTask = Task { [weak self] in
            guard let self else { return }
            self.countdownWindow.show(on: self.screenForCountdown(options), engine: self.engine)
            let total = Double(n), started = Date()
            while true {
                let elapsed = Date().timeIntervalSince(started)
                self.countdownProgress = min(1, elapsed / total)
                let remaining = max(1, Int((total - elapsed).rounded(.up)))
                if case .countdown(let r) = self.phase, r != remaining { self.phase = .countdown(remaining) }
                if self.skipRequested || elapsed >= total { break }
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            self.countdownWindow.hide()
            self.startSession(options)
        }
    }

    /// "Continue" on the Get-ready card (or Return): start now.
    func skipCountdown() { if case .countdown = phase { skipRequested = true } }

    func cancelCountdown() {
        countdownTask?.cancel(); countdownTask = nil
        countdownWindow.hide()
        phase = .idle
    }

    // MARK: Session

    func startSession(_ options: UIRecordingOptions) {
        phase = .starting
        // Order: countdown (if any) → start sound (≤ 540 ms) → capture. The sound is finished or
        // cut off before capture starts, and Yapcam's own audio is excluded from system-audio capture.
        let playSound = settings.playSounds
        let player = cuePlayer
        if settings.hideDesktopIcons { DesktopIcons.hide() }
        let s = engine.makeSession(options)
        session = s
        elapsed = 0
        startTask = Task {
            if playSound { await StartSoundGate.run(player: player) }
            do {
                try await s.start()
                phase = .recording
                startTicker()
            } catch {
                session = nil
                phase = .idle
                DesktopIcons.restoreIfNeeded()
                alert = AppAlert(title: "Recording could not start", error: error)
            }
        }
    }

    // Capture operations run strictly one after another. UI state changes immediately
    // (optimistic), so a quick Pause → Stop can never run two capture calls at once.
    private var opChain: Task<Void, Never>?
    private func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let prev = opChain
        opChain = Task { await prev?.value; await op() }
    }

    func pause() {
        guard phase == .recording, let s = session else { return }
        phase = .paused
        enqueue { [weak self] in
            do { try await s.pause() } catch { self?.revert(to: .recording, error) }
        }
    }

    func resume() {
        guard phase == .paused, let s = session else { return }
        phase = .recording
        enqueue { [weak self] in
            do { try await s.resume() } catch { self?.revert(to: .paused, error) }
        }
    }

    private func revert(to p: RecordingPhase, _ error: Error) {
        if phase == .recording || phase == .paused { phase = p }
        fail(error)
    }

    func stop() {
        guard isRecording, let s = session else { return }
        phase = .finishing
        stopTicker()
        enqueue { [weak self] in
            guard let self else { return }
            do {
                let url = try await s.stop()
                let (notesText, marks) = (notes, markers)
                lastPackage = url
                // Markers/notes/auto zooms are stored while still "finishing" so Quit waits for them.
                if settings.openEditorAfterRecording { PostRecording.prepare(package: url, notes: notesText, markers: marks, controller: self) }
                finish()
                if settings.openEditorAfterRecording {
                    // Not part of the capture queue: a long export or a save panel must never delay
                    // pause/stop/cancel of the next recording.
                    Task { [weak self] in
                        guard let self else { return }
                        await self.deliver(url)
                    }
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])      // self-tests only (isolated settings)
                }
            } catch {
                finish()
                alert = AppAlert(title: "Recording could not be saved", error: error)
            }
        }
    }

    func clearNotes() { notes = "" }

    // MARK: Recording widget actions: markers, restart and cancel with confirmation

    func addMarker() {
        guard phase == .recording else { return }
        markers.append(Int64(elapsed * 1_000_000_000))
        Announcer.say("Marker added")
    }

    /// Confirmation dialogs are Yapcam windows: keep them out of the recording.
    private func confirm(_ title: String, _ message: String, ok: String) -> Bool {
        if Self.autoConfirm { Probe.log("auto-confirmed: \(title)"); return true }
        let a = NSAlert()
        a.messageText = title; a.informativeText = message
        a.addButton(withTitle: ok); a.addButton(withTitle: "Keep Recording")
        a.layout()
        engine.registerExcluded(a.window)
        defer { engine.unregisterExcluded(a.window) }
        return a.runModal() == .alertFirstButtonReturn
    }

    func confirmRestart() {
        guard isRecording else { return }
        if confirm("Restart entire recording?", "Everything recorded so far is discarded and a new recording starts right away.", ok: "Restart") { restart() }
    }

    func confirmCancel() {
        guard isRecording else { cancel(); return }
        if confirm("Are you sure you want to cancel recording?", "The recording is deleted. This can't be undone.", ok: "Cancel Recording") { cancel() }
    }

    /// Dock click or Finish from the menu while recording.
    func confirmFinish() {
        guard isRecording else { return }
        if Self.autoConfirm { Probe.log("auto-confirmed: Finish recording?"); stop(); return }
        let a = NSAlert()
        a.messageText = "Finish recording?"; a.informativeText = "The recording is saved and opens in the editor."
        a.addButton(withTitle: "Finish"); a.addButton(withTitle: "Keep Recording")
        a.layout(); engine.registerExcluded(a.window); defer { engine.unregisterExcluded(a.window) }
        if a.runModal() == .alertFirstButtonReturn { stop() }
    }

    /// Discards the recording in progress (or countdown).
    func cancel() {
        if case .countdown = phase { cancelCountdown(); return }
        Task { await cancelAndWait() }
    }

    /// Discards the recording and returns only after the capture layer is done deleting it.
    func cancelAndWait() async {
        if case .countdown = phase { cancelCountdown(); return }
        guard isRecording, let s = session else { return }
        phase = .finishing
        stopTicker()
        let prev = opChain
        let task = Task { await prev?.value; await s.cancel(); finish() }
        opChain = task
        await task.value
    }

    /// Discards the current take and starts a new one with the same options, no countdown.
    func restart() {
        guard isRecording, let s = session, let options = lastOptions else { return }
        phase = .finishing
        stopTicker()
        enqueue { [weak self] in
            await s.cancel()
            self?.finish()
            self?.startSession(options)
        }
    }

    private func finish() {
        markers = []
        TeleprompterController.shared.hide()
        DesktopIcons.restoreIfNeeded()
        if settings.playSounds, session != nil {
            let player = cuePlayer
            Task.detached { try? await player.play(.stop, gain: StartSoundGate.gain) }
        }
        session = nil; phase = .idle; elapsed = 0; micLevel = 0; warnings = []; lowDisk = false
    }

    private func fail(_ error: Error) {
        alert = AppAlert(title: "Recording problem", error: error)
    }

    // MARK: Ticker

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    private func tick() {
        guard let s = session else { return }
        elapsed = s.elapsed
        micLevel = s.micLevel
        if s.warnings != warnings { warnings = s.warnings }
        tickCount += 1
        if tickCount % 50 == 0 {
            let free = (try? settings.storageDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage) ?? Int64.max
            lowDisk = free < 2_000_000_000
        }
        if let f = s.failure, isRecording {
            // The engine ended the recording itself. The package stays on disk as an
            // interrupted recording; never cancel() it (that deletes the package).
            stopTicker()
            if let pkg = s.packageURL { PostRecording.salvage(package: pkg, notes: notes, markers: markers) }
            finish()
            alert = AppAlert(title: "Recording stopped", message: UserMessage.describe(f) + " What was written to disk can be recovered from the Recordings window.")
            RecentProjectsWindow.shared.show()
        }
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    /// When set, the alert offers a button that opens this permission's System Settings pane.
    var permission: AppPermission?
}

// MARK: - Get-ready card

@MainActor final class CountdownWindow {
    private var window: ReadyPanel?

    func show(on screen: NSScreen?, engine: RecordingEngine) {
        guard let screen = screen ?? NSScreen.main else { return }
        if window == nil {
            let p = ReadyPanel()
            p.contentView = NSHostingView(rootView: GetReadyCard(cancel: { RecordingController.shared.cancelCountdown() },
                                                                  skip: { RecordingController.shared.skipCountdown() })
                .environmentObject(RecordingController.shared))
            p.onEscape = { RecordingController.shared.cancelCountdown() }
            p.onReturn = { RecordingController.shared.skipCountdown() }
            engine.registerExcluded(p)
            window = p
        }
        let size = CGSize(width: 340, height: 120)
        window?.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height - 90,
                                width: size.width, height: size.height), display: true)
        window?.orderFrontRegardless()
        window?.makeKey()
    }

    func hide() { window?.orderOut(nil) }
}

final class ReadyPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = .screenSaver; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    }
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: if !event.isARepeat { onEscape?() }
        case 36, 76: if !event.isARepeat { onReturn?() }   // a held Return must not skip the countdown
        default: super.keyDown(with: event)
        }
    }
}

/// "Get ready. Recording will start soon." with a ring that fills over the countdown and a Continue button.
struct GetReadyCard: View {
    let cancel: () -> Void
    let skip: () -> Void
    @EnvironmentObject var rec: RecordingController

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 5)
                Circle().trim(from: 0, to: rec.countdownProgress).stroke(Color.red, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if case .countdown(let n) = rec.phase, n < 9 {
                    Text("\(n)").font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                }
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Get ready").font(.system(size: 15, weight: .semibold))
                Text("Recording will start soon.").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Continue", action: skip).keyboardShortcut(.defaultAction)
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                }.controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 340, height: 120)
        .panelSurface(cornerRadius: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(countdownLabel)
    }

    private var countdownLabel: String {
        if case .countdown(let n) = rec.phase { return "Recording starts in \(n) seconds" }
        return "Recording starts soon"
    }
}
