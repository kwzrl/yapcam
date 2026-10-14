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
    @Published public var height = 1080
    @Published public var fps = 30
    @Published public var includeAudio = true
    public static let heights = [720, 1080]
    public static let fpsOptions = [30, 60]

    private let engine: ExportEngine
    private var task: Task<Void, Never>?

    public init(engine: ExportEngine) { self.engine = engine }

    public var isRunning: Bool { if case .running = state { return true }; return false }

    public func start(to destination: URL) {
        guard !isRunning else { return }
        state = .running(0)
        let req = ExportRequest(height: height, fps: fps, destination: destination, includeAudio: includeAudio)
        let engine = engine
        task = Task { [weak self] in
            do {
                let url = try await engine.run(req) { p in
                    Task { @MainActor in self?.progressed(p) }
                }
                self?.state = .done(url)
            } catch is CancellationError {
                self?.state = .cancelled
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    private func progressed(_ p: Double) { if case .running = state { state = .running(p) } }

    public func cancel() { task?.cancel() }
    /// Suspends until the current export reached a terminal state (returns immediately when idle).
    public func waitUntilFinished() async { await task?.value }
    public func reset() { if !isRunning { state = .idle } }
}
