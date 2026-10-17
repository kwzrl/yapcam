import Foundation
import AppKit

@MainActor
public final class ExportModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case running(Double)
        case done(URL)
        case failed(String)
        case cancelled
    }
    /// What happened, for the app's notification and Dock-progress consumers (R5-U02).
    public struct Outcome: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case started, completed(URL), cancelled, failed(String) }
        public var kind: Kind
        public var target: ExportTarget
    }
    /// Called on the main actor when an export starts, finishes, is cancelled or fails (clipboard copies included).
    public var onOutcome: (@MainActor (Outcome) -> Void)?
    /// Seconds since the running export began and the fraction done, for elapsed/remaining readouts (nil when idle).
    @Published public private(set) var startedAt: Date?
    @Published public var target: ExportTarget = .file { didSet { if oldValue != target { normalize(); persist() } } }
    /// Formats offered for the current target (the paired H.264 + HEVC export needs a folder, so not the clipboard).
    public var availableFormats: [ExportFormat] { ExportFormat.allCases.filter { target == .file || !$0.fileTargetOnly } }
    /// Shows a file in Finder (the sheet reveals a finished export). Replaceable so tests and snapshots never open Finder.
    public var revealHandler: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    public func reveal(_ url: URL) { revealHandler(url) }
    /// Files the clipboard export kept, newest first.
    @Published public private(set) var history: [URL] = []
    public func refreshHistory() { history = engine.clipboardHistory() }
    public func copyAgain(_ url: URL) { do { try engine.copyToClipboard(url) } catch { state = .failed(error.localizedDescription) } }
    /// Render warns that a 1080p GIF can become very large.
    public var showsLargeGIFWarning: Bool { format == .gif && height >= 1080 }
    @Published public private(set) var state: State = .idle
    /// Queue phase of the running export (waiting for another export / preparing / rendering); nil when not running.
    @Published public private(set) var queueStatus: ExportQueueStatus?
    @Published public var height = 720 { didSet { normalize(); persist() } }
    @Published public var fps = 60 { didSet { normalize(); persist() } }
    @Published public var includeAudio = true { didSet { persist() } }
    @Published public var format: ExportFormat = .mp4h264 {
        didSet {
            if oldValue == format { return }
            if !format.supportsAudio { includeAudio = false }
            // A different format has its own defaults when the current choice does not exist there.
            if !format.options.fps.contains(fps) { fps = format.options.defaultFPS }
            if !format.options.heights.contains(height) { height = format.options.defaultHeight }
            normalize(); persist()
        }
    }
    @Published public var preset: CompressionPreset = .social { didSet { normalize(); persist() } }
    /// GIF only: global-palette high quality pass (default on) and playing once instead of looping.
    @Published public var gifHighQuality = true { didSet { persist() } }
    @Published public var gifDisableLoop = false { didSet { persist() } }
    /// Quality (0…1) taken from the compression preset; GIF has none.
    public var quality: Double { preset.quality }
    /// True when the app's experimental variable-frame-rate setting applies to the current format.
    public var usesVariableFrameRate: Bool { format != .gif && variableFrameRateProvider() }
    /// Defaults to the app-wide experimental setting (`EditorWindows.variableFrameRate`).
    public var variableFrameRateProvider: () -> Bool = { EditorWindows.variableFrameRate() }
    /// Defaults to the app-wide switch (`EditorWindows.hardwareEncodingEnabled`).
    public var hardwareEncodingProvider: () -> Bool = { EditorWindows.hardwareEncodingEnabled() }
    public var options: ExportOptionSet { format.options }
    public var availablePresets: [CompressionPreset] { format.options.presets(atHeight: height) }

    /// Keeps the choices inside what the format offers (fps, height, preset available at that height).
    private func normalize() {
        if target == .clipboard && format.fileTargetOnly { format = .mp4h264; return }
        let o = format.options
        if !o.fps.contains(fps) { fps = o.defaultFPS }
        if !o.heights.contains(height) { height = o.defaultHeight; return }
        if let first = o.presets(atHeight: height).first, !o.presets(atHeight: height).contains(preset) { preset = o.defaultPreset.flatMap { o.presets(atHeight: height).contains($0) ? $0 : nil } ?? first }
    }

    private let engine: ExportEngine
    var rememberTarget: (context: ExportRememberedSettings.Context, defaults: UserDefaults)?
    private func persist() { if let t = rememberTarget { rememberedSettings.save(t.context, to: t.defaults) } }
    /// Current microphone clean-up settings (nil = off); read when an export starts.
    public var speechProvider: () -> SpeechEnhancement? = { nil }
    private var task: Task<Void, Never>?
    public private(set) var lastDestination: URL?
    /// True when the failed export included audio, so retrying without audio can help (e.g. an audio decode problem).
    public private(set) var failedWithAudio = false

    public init(engine: ExportEngine) { self.engine = engine }

    public var isRunning: Bool { if case .running = state { return true }; return false }

    /// Exports to the clipboard: a local file kept in the history is rendered and copied as a file.
    /// The remembered target (the dialog's File/Clipboard choice) is left exactly as it was: only this run goes to the clipboard.
    public func copyToClipboard() {
        guard !isRunning else { return }
        begin(to: ClipboardPlaceholder.url, target: .clipboard)
    }

    public func start(to destination: URL) { begin(to: destination, target: target) }

    /// Target of the export that is running or finished last (what the progress and result screens describe).
    @Published public private(set) var runningTarget: ExportTarget = .file

    private func begin(to destination: URL, target: ExportTarget) {
        guard !isRunning else { return }
        runningTarget = target
        lastDestination = destination
        failedWithAudio = false
        state = .running(0)
        queueStatus = .waiting
        startedAt = Date()
        onOutcome?(Outcome(kind: .started, target: target))
        let req = makeRequest(destination: destination, target: target)
        let engine = engine
        task = Task { [weak self] in
            do {
                let url = try await engine.run(req, progress: { p in
                    Task { @MainActor in self?.progressed(p) }
                }, status: { s in
                    Task { @MainActor in self?.queueProgressed(s) }
                })
                self?.queueStatus = nil; self?.startedAt = nil
                self?.state = .done(url)
                if target == .clipboard { self?.refreshHistory() }
                self?.onOutcome?(Outcome(kind: .completed(url), target: target))
            } catch is CancellationError {
                self?.queueStatus = nil; self?.startedAt = nil
                self?.state = .cancelled
                self?.onOutcome?(Outcome(kind: .cancelled, target: target))
            } catch {
                self?.queueStatus = nil; self?.startedAt = nil
                self?.failedWithAudio = req.includeAudio
                self?.state = .failed(error.localizedDescription)
                self?.onOutcome?(Outcome(kind: .failed(error.localizedDescription), target: target))
            }
        }
    }

    func makeRequest(destination: URL, target: ExportTarget? = nil) -> ExportRequest {
        ExportRequest(height: height, fps: fps, destination: destination, includeAudio: includeAudio && format.supportsAudio,
                      speech: includeAudio && format.supportsAudio ? speechProvider() : nil, format: format, quality: quality,
                      compression: format == .gif ? nil : preset, gifHighQuality: gifHighQuality, gifDisableLoop: gifDisableLoop,
                      variableFrameRate: variableFrameRateProvider() && format != .gif, target: target ?? self.target,
                      hardwareEncoding: hardwareEncodingProvider())
    }
    /// Size and time readout for the current choices (nil when the engine cannot plan them).
    public var estimate: ExportEstimateInfo? { engine.estimate(for: makeRequest(destination: URL(fileURLWithPath: "/dev/null"))) }

    private func queueProgressed(_ s: ExportQueueStatus) { if isRunning, queueStatus != nil { queueStatus = s } }
    private func progressed(_ p: Double) { if case .running = state { state = .running(p) } }

    /// After a failed export that included audio: run the same export again without audio to the same file.
    public func retryWithoutAudio() {
        guard case .failed = state, failedWithAudio, let dest = lastDestination, !isRunning else { return }
        includeAudio = false
        state = .idle
        start(to: dest)
    }

    public func cancel() { task?.cancel() }
    /// Suspends until the current export reached a terminal state (returns immediately when idle).
    public func waitUntilFinished() async { await task?.value }
    public func reset() { if !isRunning { state = .idle } }
}

/// The clipboard export chooses its own file in render's history folder; this URL only fills the request.
enum ClipboardPlaceholder { static let url = URL(fileURLWithPath: "/dev/null") }
