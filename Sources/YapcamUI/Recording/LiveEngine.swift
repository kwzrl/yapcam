import AppKit
import YapcamCapture
import YapcamEditor

/// Real engine: YapcamCapture for recording, YapcamEditor for opening results.
@MainActor struct LiveEngine: RecordingEngine {
    @MainActor final class Session: EngineSession {
        private let inner: RecordingSession
        init(_ options: UIRecordingOptions) {
            inner = RecordingSession(options: LiveEngine.captureOptions(for: options))
        }
        var elapsed: TimeInterval { inner.elapsed }
        var micLevel: Float { inner.micLevel }
        var warnings: [String] { inner.warnings }
        var failure: EngineError? {
            if case .failed(let e) = inner.state { return LiveEngine.map(e) }
            return nil
        }
        var packageURL: URL? { inner.packageURL }
        func start() async throws { do { try await inner.start() } catch { throw LiveEngine.map(error) } }
        func pause() async throws { do { try await inner.pause() } catch { throw LiveEngine.map(error) } }
        func resume() async throws { do { try await inner.resume() } catch { throw LiveEngine.map(error) } }
        func stop() async throws -> URL { do { return try await inner.stop() } catch { throw LiveEngine.map(error) } }
        func cancel() async { await inner.cancel() }
    }

    static func selection(for o: UIRecordingOptions) -> SystemAudioSelection {
        guard o.systemAudio else { return .off }
        return o.systemAudioApps.map { .applications(bundleIDs: $0) } ?? .allApplications
    }

    static func captureOptions(for o: UIRecordingOptions) -> RecordingOptions {
        let target: CaptureTarget
        switch o.target {
        case .display(let d): target = .display(d)
        case .window(let w): target = .window(w)
        case .area(let d, let r): target = .area(display: d, rect: r)
        case .device(let id): target = .device(id)
        }
        return RecordingOptions(
            target: target, systemAudio: o.systemAudio, microphoneID: o.microphoneID,
            cameraID: o.cameraID, recordKeystrokes: o.recordKeystrokes, maxFPS: o.maxFPS,
            excludeYapcamWindows: true, hideDesktopIcons: o.hideDesktopIcons,
            systemAudioSelection: selection(for: o), cameraMaxResolution: o.cameraMaxResolution,
            outputDirectory: o.outputDirectory)
    }

    func preflight(_ o: UIRecordingOptions) async -> [PreflightIssue] {
        guard let sources = try? await CaptureSources.load(includeWindowThumbnails: false) else { return [] }
        return CapturePreflight.check(options: Self.captureOptions(for: o), sources: sources).map { PreflightIssue($0) }
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

    private static var registered: Set<ObjectIdentifier> = []

    func registerExcluded(_ window: NSWindow) {
        Self.registered.insert(ObjectIdentifier(window))
        CaptureExclusions.register(window)
        // The window number only exists once the window server knows the window.
        // Weak, and only while still registered and on screen: an overlay closed within 0.5 s must not be re-added.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak window] in
            MainActor.assumeIsolated { if let window, window.isVisible, Self.registered.contains(ObjectIdentifier(window)) { CaptureExclusions.register(window) } }
        }
    }
    func unregisterExcluded(_ window: NSWindow) {
        Self.registered.remove(ObjectIdentifier(window))
        CaptureExclusions.unregister(window)
    }

    func openEditor(package: URL) {
        RecentDocuments.noteOpened(package)
        FirstCloseGuard.shared.willOpen(package)
        EditorWindows.open(package: package)
        EditorBridge.bringEditorsToFront()
    }

    func interruptedPackages(in directory: URL) -> [URL] { RecordingSession.interruptedPackages(in: directory) }
    func recover(_ package: URL) throws -> URL { try RecordingSession.recover(package) }
}
