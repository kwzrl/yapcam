import Foundation

@MainActor
public final class ExportModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case running(Double)
        case done(URL)
        case failed(String)
        case cancelled
    }
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
    public var options: ExportOptionSet { format.options }
    public var availablePresets: [CompressionPreset] { format.options.presets(atHeight: height) }

    /// Keeps the choices inside what the format offers (fps, height, preset available at that height).
    private func normalize() {
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

    public func start(to destination: URL) {
        guard !isRunning else { return }
        lastDestination = destination
        failedWithAudio = false
        state = .running(0)
        queueStatus = .waiting
        let req = makeRequest(destination: destination)
        let engine = engine
        task = Task { [weak self] in
            do {
                let url = try await engine.run(req, progress: { p in
                    Task { @MainActor in self?.progressed(p) }
                }, status: { s in
                    Task { @MainActor in self?.queueProgressed(s) }
                })
                self?.queueStatus = nil
                self?.state = .done(url)
            } catch is CancellationError {
                self?.queueStatus = nil
                self?.state = .cancelled
            } catch {
                self?.queueStatus = nil
                self?.failedWithAudio = req.includeAudio
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func makeRequest(destination: URL) -> ExportRequest {
        ExportRequest(height: height, fps: fps, destination: destination, includeAudio: includeAudio && format.supportsAudio,
                      speech: includeAudio && format.supportsAudio ? speechProvider() : nil, format: format, quality: quality,
                      compression: format == .gif ? nil : preset, gifHighQuality: gifHighQuality, gifDisableLoop: gifDisableLoop)
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
