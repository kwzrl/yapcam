import AppKit
import YapcamCapture

/// Real engine: YapcamCapture for recording. The editor hook is isolated in `openEditor`.
@MainActor struct LiveEngine: RecordingEngine {
    @MainActor final class Session: EngineSession {
        private let inner: RecordingSession
        init(_ options: UIRecordingOptions) {
            let target: CaptureTarget
            switch options.target {
            case .display(let d): target = .display(d)
            case .window(let w): target = .window(w)
            case .area(let d, let r): target = .area(display: d, rect: r)
            }
            inner = RecordingSession(options: RecordingOptions(
                target: target, systemAudio: options.systemAudio, microphoneID: options.microphoneID,
                cameraID: options.cameraID, recordKeystrokes: options.recordKeystrokes, maxFPS: options.maxFPS,
                excludeYapcamWindows: true, outputDirectory: options.outputDirectory))
        }
        var elapsed: TimeInterval { inner.elapsed }
        var micLevel: Float { inner.micLevel }
        var warnings: [String] { inner.warnings }
        var failure: EngineError? {
            if case .failed(let e) = inner.state { return LiveEngine.map(e) }
            return nil
        }
        func start() async throws { do { try await inner.start() } catch { throw LiveEngine.map(error) } }
        func pause() async throws { do { try await inner.pause() } catch { throw LiveEngine.map(error) } }
        func resume() async throws { do { try await inner.resume() } catch { throw LiveEngine.map(error) } }
        func stop() async throws -> URL { do { return try await inner.stop() } catch { throw LiveEngine.map(error) } }
        func cancel() async { await inner.cancel() }
    }

    static func map(_ error: Error) -> EngineError {
        guard let e = error as? CaptureError else { return .failed(error.localizedDescription) }
        switch e {
        case .permissionDenied(let p): return .permissionDenied(p.rawValue)
        case .diskFull(let b): return .diskFull(availableBytes: b)
        default: return .failed(e.localizedDescription)
        }
    }

    func makeSession(_ options: UIRecordingOptions) -> EngineSession { Session(options) }

    func registerExcluded(_ window: NSWindow) {
        CaptureExclusions.register(window)
        // The window number only exists once the window server knows the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { CaptureExclusions.register(window) } }
    }
    func unregisterExcluded(_ window: NSWindow) { CaptureExclusions.unregister(window) }

    func openEditor(package: URL) {
        // EditorWindows is not on main yet (docs/status/editor.md); reveal the package until it is.
        NSWorkspace.shared.activateFileViewerSelecting([package])
    }

    func interruptedPackages(in directory: URL) -> [URL] { RecordingSession.interruptedPackages(in: directory) }
    func recover(_ package: URL) throws -> URL { try RecordingSession.recover(package) }
}
