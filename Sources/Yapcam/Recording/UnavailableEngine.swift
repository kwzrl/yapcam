import AppKit

/// Used until `YapcamCapture` / `YapcamEditor` are integrated on this branch
/// (see docs/status/ui.md → Requests). Every call fails loudly; nothing is simulated.
@MainActor struct UnavailableEngine: RecordingEngine {
    static let reason = "The capture engine is not integrated in this build yet."

    @MainActor final class Session: EngineSession {
        var elapsed: TimeInterval { 0 }
        var micLevel: Float { 0 }
        var warnings: [String] { [] }
        var failure: EngineError? { nil }
        func start() async throws { throw EngineError.unavailable(UnavailableEngine.reason) }
        func pause() async throws { throw EngineError.unavailable(UnavailableEngine.reason) }
        func resume() async throws { throw EngineError.unavailable(UnavailableEngine.reason) }
        func stop() async throws -> URL { throw EngineError.unavailable(UnavailableEngine.reason) }
        func cancel() async {}
    }

    func makeSession(_ options: UIRecordingOptions) -> EngineSession { Session() }
    func registerExcluded(_ window: NSWindow) {}
    func unregisterExcluded(_ window: NSWindow) {}
    func openEditor(package: URL) { NSWorkspace.shared.activateFileViewerSelecting([package]) }
    func interruptedPackages(in directory: URL) -> [URL] { [] }
    func recover(_ package: URL) throws -> URL { throw EngineError.unavailable(Self.reason) }
}
