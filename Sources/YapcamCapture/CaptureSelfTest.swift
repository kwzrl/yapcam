import Foundation

/// Hidden app entry point: invoke from the signed app on --capture-selftest.
/// Optional arguments let QA exercise area/window capture and pause/resume too.
@MainActor public enum CaptureSelfTest {
    public static func run(seconds: Double, outputDirectory: URL? = nil,
                           target: CaptureTarget? = nil, maxFPS: Int = 60,
                           pauseAfter: Double? = nil, systemAudio: Bool = true,
                           microphoneID: String? = nil, cameraID: String? = nil,
                           hideDesktopIcons: Bool = false, captureNotifications: Bool = true,
                           recordKeystrokes: Bool = false) async throws -> URL {
        guard seconds.isFinite, seconds > 0, seconds <= 3600 else { throw CaptureError.writerFailed("Self-test duration must be in (0, 3600]") }
        let sources = try await CaptureSources.load(includeWindowThumbnails: false)
        guard let display = sources.displays.first else { throw CaptureError.sourceUnavailable }
        let output = outputDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Yapcam/QA/capture")
        let session = RecordingSession(options: RecordingOptions(target: target ?? .display(display.id),
            systemAudio: systemAudio, microphoneID: microphoneID, cameraID: cameraID,
            recordKeystrokes: recordKeystrokes, maxFPS: maxFPS, hideDesktopIcons: hideDesktopIcons,
            captureNotifications: captureNotifications, outputDirectory: output))
        try await session.start()
        do {
            if let pause = pauseAfter, pause > 0, pause < seconds {
                try await Task.sleep(for: .seconds(pause))
                try await session.pause()
                try await Task.sleep(for: .seconds(0.5))
                try await session.resume()
                try await Task.sleep(for: .seconds(seconds - pause))
            } else { try await Task.sleep(for: .seconds(seconds)) }
            return try await session.stop()
        } catch {
            if error is CancellationError { await session.cancel() }
            throw error
        }
    }
}
