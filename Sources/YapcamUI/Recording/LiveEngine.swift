import AppKit
import YapcamCapture
import YapcamEditor

/// Real engine: YapcamCapture for recording, YapcamEditor for opening results.
@MainActor struct LiveEngine: RecordingEngine {
    @MainActor final class Session: EngineSession {
        private let inner: RecordingSession
        init(_ options: UIRecordingOptions) {
            let target: CaptureTarget
            switch options.target {
            case .display(let d): target = .display(d)
            case .window(let w): target = .window(w)
            case .area(let d, let r): target = .area(display: d, rect: r)
            case .device(let id): target = .device(id)
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
        guard let e = error as? CaptureError else {
            let ns = error as NSError
            if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && ns.code == -3801 { return .permissionDenied("screen") }
            return .failed(UserMessage.describe(error))
        }
        switch e {
        case .permissionDenied(let p): return .permissionDenied(p.rawValue)
        case .diskFull(let b): return .diskFull(availableBytes: b)
        case .sourceUnavailable: return .failed("The display or window you chose isn't available any more. Pick the source again in the toolbar.")
        case .deviceLost(let name): return .failed("The device “\(name)” was disconnected. Recording continues without it.")
        case .writerFailed(let d): return .failed("Recording could not be written to disk (\(UserMessage.clean(d, fallback: "unknown problem"))). Check free space and the recordings folder in Settings → Storage.")
        }
    }

    func makeSession(_ options: UIRecordingOptions) -> EngineSession { Session(options) }

    func registerExcluded(_ window: NSWindow) {
        CaptureExclusions.register(window)
        // The window number only exists once the window server knows the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { CaptureExclusions.register(window) } }
    }
    func unregisterExcluded(_ window: NSWindow) { CaptureExclusions.unregister(window) }

    func openEditor(package: URL) { EditorWindows.open(package: package) }

    func interruptedPackages(in directory: URL) -> [URL] { RecordingSession.interruptedPackages(in: directory) }
    func recover(_ package: URL) throws -> URL { try RecordingSession.recover(package) }
}
