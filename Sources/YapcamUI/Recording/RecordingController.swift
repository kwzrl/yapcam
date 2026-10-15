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

    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var warnings: [String] = []
    @Published private(set) var lowDisk = false
    /// Speaker notes typed before or during a recording; saved into the project on stop.
    @Published var notes = ""
    @Published var alert: AppAlert?

    var engine: RecordingEngine = LiveEngine()
    private let settings = AppSettings.shared
    private var session: EngineSession?
    private var countdownTask: Task<Void, Never>?
    private var ticker: Timer?
    private let countdownWindow = CountdownWindow()
    private var lastOptions: UIRecordingOptions?
    private var tickCount = 0

    var isBusy: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording || phase == .paused }

    /// UI snapshot tooling only: forces a phase without a session.
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
        guard phase == .idle else { return }
        let perms = PermissionsModel.shared
        perms.refresh()
        if perms.state(.screen) != .granted {
            OnboardingWindow.shared.show(reason: "Screen recording permission is required to record.")
            return
        }
        let options: UIRecordingOptions
        do { options = try makeOptions() } catch {
            alert = AppAlert(title: "Can't start recording", error: error)
            return
        }
        lastOptions = options
        runCountdown(then: options)
    }

    // MARK: Options

    private func makeOptions() throws -> UIRecordingOptions {
        let target: UITarget
        switch settings.sourceMode {
        case .display:
            guard let d = Displays.resolve(settings.displayID) else { throw EngineError.failed("No display found.") }
            target = .display(d.id)
        case .window:
            guard settings.windowID != 0 else { throw EngineError.failed("Choose a window to record first.") }
            let alive = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(settings.windowID)) as? [[String: Any]])?.isEmpty == false
            guard alive else { throw EngineError.failed("The selected window is no longer available. Choose another window.") }
            target = .window(settings.windowID)
        case .area:
            guard let saved = settings.areaRect, let display = Displays.info(for: settings.areaDisplayID) else {
                throw EngineError.failed("Select an area to record first, or pick Display instead.")
            }
            // The display may have changed resolution or arrangement since the area was chosen.
            guard let rect = AreaGeometry.fit(saved, in: display.frame.size) else {
                throw EngineError.failed("The saved area no longer fits on “\(display.name)”. Choose the area again.")
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
            microphoneID: PermissionsModel.shared.state(.microphone) == .granted && DeviceModel.shared.isAvailable(microphone: settings.microphoneID) ? settings.microphoneID : nil,
            cameraID: PermissionsModel.shared.state(.camera) == .granted && DeviceModel.shared.isAvailable(camera: settings.cameraID) ? settings.cameraID : nil,
            recordKeystrokes: settings.recordKeystrokes && PermissionsModel.shared.state(.inputMonitoring) == .granted,
            maxFPS: settings.maxFPS,
            outputDirectory: settings.storageDirectory)
    }

    private func screenForCountdown(_ o: UIRecordingOptions) -> NSScreen? {
        switch o.target {
        case .display(let id), .area(let id, _): return Displays.screen(for: id)
        case .window: return NSScreen.main
        }
    }

    // MARK: Countdown

    private func runCountdown(then options: UIRecordingOptions) {
        let n = settings.countdown
        guard n > 0 else { startSession(options); return }
        phase = .countdown(n)
        countdownTask = Task { [weak self] in
            guard let self else { return }
            for i in stride(from: n, through: 1, by: -1) {
                self.phase = .countdown(i)
                self.countdownWindow.show(i, on: self.screenForCountdown(options), engine: self.engine)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self.countdownWindow.hide()
            self.startSession(options)
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel(); countdownTask = nil
        countdownWindow.hide()
        phase = .idle
    }

    // MARK: Session

    private func startSession(_ options: UIRecordingOptions) {
        phase = .starting
        // Sound first: it must be finished before capture starts so it never reaches the recording.
        let lead: Duration = settings.playSounds ? .milliseconds(450) : .zero
        if settings.playSounds { NSSound(named: "Tink")?.play() }
        if settings.hideDesktopIcons { DesktopIcons.hide() }
        let s = engine.makeSession(options)
        session = s
        elapsed = 0
        Task {
            try? await Task.sleep(for: lead)
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
                finish()
                if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do { try ProjectActions.attachNotes(notes, to: url); notes = "" }
                    catch { alert = AppAlert(title: "Notes were not saved", message: "The recording is fine, but its speaker notes could not be stored: \(UserMessage.describe(error))") }
                }
                if settings.openEditorAfterRecording { engine.openEditor(package: url) }
                else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                finish()
                alert = AppAlert(title: "Recording could not be saved", error: error)
            }
        }
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
        TeleprompterController.shared.hide()
        DesktopIcons.restoreIfNeeded()
        if settings.playSounds, session != nil { NSSound(named: "Pop")?.play() }
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

// MARK: - Countdown overlay

@MainActor final class CountdownWindow {
    private var window: NSPanel?
    private var model = CountdownModel()

    final class CountdownModel: ObservableObject { @Published var value = 0 }

    func show(_ n: Int, on screen: NSScreen?, engine: RecordingEngine) {
        model.value = n
        guard let screen = screen ?? NSScreen.main else { return }
        if window == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = .screenSaver; p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: CountdownView(model: model))
            p.isReleasedWhenClosed = false
            engine.registerExcluded(p)
            window = p
        }
        let size = CGSize(width: 160, height: 160)
        window?.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                                width: size.width, height: size.height), display: true)
        window?.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownWindow.CountdownModel
    var body: some View {
        Text("\(model.value)")
            .font(.system(size: 84, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.primary)
            .frame(width: 148, height: 148)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.separator))
            .frame(width: 160, height: 160)
    }
}
