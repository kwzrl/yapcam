import Foundation

/// Hidden app entry point: invoke from the signed app on --capture-selftest.
/// Optional arguments let QA exercise area/window capture and pause/resume too.
@MainActor public enum CaptureSelfTest {
    public static func run(seconds: Double, outputDirectory: URL? = nil,
                           target: CaptureTarget? = nil, maxFPS: Int = 60,
                           pauseAfter: Double? = nil, systemAudio: Bool = true,
                           microphoneID: String? = nil, cameraID: String? = nil,
                           hideDesktopIcons: Bool = false, captureNotifications: Bool = true,
                           recordKeystrokes: Bool = false, systemAudioSelection: SystemAudioSelection? = nil,
                           cameraMaxResolution: CameraMaxResolution = .hd1080,
                           addMarkers: Bool = false) async throws -> URL {
        guard seconds.isFinite, seconds > 0, seconds <= 3600 else { throw CaptureError.writerFailed("Self-test duration must be in (0, 3600]") }
        let environment = ProcessInfo.processInfo.environment
        let deviceRequested: Bool
        if case .device = target { deviceRequested = true }
        else { deviceRequested = target == nil && environment["YAPCAM_CAPTURE_SELFTEST_TARGET"]?.hasPrefix("device:") == true }
        let sources: CaptureSources
        if deviceRequested {
            sources = CaptureSources(displays: [], windows: [], cameras: [], microphones: [],
                                     deviceScreens: try CaptureSources.loadDeviceScreens())
        } else { sources = try await CaptureSources.load(includeWindowThumbnails: false) }
        let overrides = try CaptureSelfTestOverrides(environment: environment,
                                                    sources: sources, seconds: seconds)
        guard let selectedTarget = target ?? overrides.target ?? sources.displays.first.map({ .display($0.id) }) else {
            throw CaptureError.sourceUnavailable
        }
        let pauseAfter = overrides.pauseAfter ?? pauseAfter
        let output = outputDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Yapcam/QA/capture")
        let session = RecordingSession(options: RecordingOptions(target: selectedTarget,
            systemAudio: systemAudio, microphoneID: overrides.microphoneID ?? microphoneID, cameraID: overrides.cameraID ?? cameraID,
            recordKeystrokes: recordKeystrokes, maxFPS: overrides.maxFPS ?? maxFPS, hideDesktopIcons: hideDesktopIcons,
            captureNotifications: captureNotifications,
            systemAudioSelection: overrides.systemAudioSelection ?? systemAudioSelection,
            cameraMaxResolution: overrides.cameraMaxResolution ?? cameraMaxResolution, outputDirectory: output))
        try await session.start()
        do {
            if overrides.addMarkers ?? addMarkers { try session.addMarker() }
            if let pause = pauseAfter, pause > 0, pause < seconds {
                try await Task.sleep(for: .seconds(pause))
                try await session.pause()
                try await Task.sleep(for: .seconds(0.5))
                try await session.resume()
                if overrides.addMarkers ?? addMarkers { try session.addMarker() }
                try await Task.sleep(for: .seconds(seconds - pause))
            } else { try await Task.sleep(for: .seconds(seconds)) }
            return try await session.stop()
        } catch {
            if error is CancellationError { await session.cancel() }
            throw error
        }
    }
}

/// Environment switches apply only to this explicit self-test, never normal capture.
/// They let the existing signed-app entry point exercise variants without UI wiring.
struct CaptureSelfTestOverrides {
    var target: CaptureTarget?
    var maxFPS: Int?
    var pauseAfter: Double?
    var systemAudioSelection: SystemAudioSelection?
    var cameraMaxResolution: CameraMaxResolution?
    var cameraID: String?
    var microphoneID: String?
    var addMarkers: Bool?

    init(environment: [String: String], sources: CaptureSources, seconds: Double) throws {
        func invalid(_ key: String) -> CaptureError { .writerFailed("Invalid self-test environment: \(key)") }
        if let value = environment["YAPCAM_CAPTURE_SELFTEST_AUDIO"] {
            switch value {
            case "off": systemAudioSelection = .off
            case "all": systemAudioSelection = .allApplications
            default:
                guard value.hasPrefix("apps:") else { throw invalid("AUDIO (off, all, apps:bundleID,...)" ) }
                let ids = value.dropFirst(5).components(separatedBy: ",")
                guard ids.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }) else { throw invalid("AUDIO application IDs") }
                systemAudioSelection = .applications(bundleIDs: ids)
            }
        }
        if let value = environment["YAPCAM_CAPTURE_SELFTEST_CAMERA_MAX"] {
            guard let number = Int(value), let cap = CameraMaxResolution(rawValue: number) else { throw invalid("CAMERA_MAX (720, 1080, 2160)") }
            cameraMaxResolution = cap
        }
        for key in ["CAMERA_ID", "MICROPHONE_ID"] {
            if let value = environment["YAPCAM_CAPTURE_SELFTEST_" + key] {
                guard !value.isEmpty else { throw invalid(key) }
                if key == "CAMERA_ID" { cameraID = value } else { microphoneID = value }
            }
        }
        if let value = environment["YAPCAM_CAPTURE_SELFTEST_MARKERS"] {
            guard value == "0" || value == "1" else { throw invalid("MARKERS (0 or 1)") }
            addMarkers = value == "1"
        }
        if let value = environment["YAPCAM_CAPTURE_SELFTEST_FPS"] {
            guard let fps = Int(value), fps == 30 || fps == 60 else { throw invalid("FPS (30 or 60)") }
            maxFPS = fps
        }
        if let value = environment["YAPCAM_CAPTURE_SELFTEST_PAUSE_AFTER"] {
            guard let pause = Double(value), pause.isFinite, pause > 0, pause < seconds else {
                throw invalid("PAUSE_AFTER (between zero and duration)")
            }
            pauseAfter = pause
        }
        guard let value = environment["YAPCAM_CAPTURE_SELFTEST_TARGET"] else { return }
        if value.hasPrefix("device:") {
            let id = String(value.dropFirst(7))
            guard sources.deviceScreens.contains(where: { $0.id == id }) else { throw CaptureError.deviceLost(id) }
            target = .device(id); return
        }
        guard let display = sources.displays.first else { throw CaptureError.sourceUnavailable }
        if value == "display" { target = .display(display.id); return }
        if value.hasPrefix("window:") {
            let selector = String(value.dropFirst(7))
            if let id = UInt32(selector), sources.windows.contains(where: { $0.id == id }) {
                target = .window(id); return
            }
            if let window = sources.windows.first(where: { $0.bundleID == selector }) {
                target = .window(window.id); return
            }
            throw CaptureError.sourceUnavailable
        }
        if value.hasPrefix("area:") {
            let fields = value.dropFirst(5).split(separator: ",", omittingEmptySubsequences: false)
            let numbers = fields.compactMap { Double($0) }
            guard fields.count == 4, numbers.count == 4, numbers.allSatisfy(\.isFinite) else { throw invalid("TARGET area:x,y,width,height") }
            let rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            _ = try CaptureGeometry.area(displayBounds: display.frame, localRect: rect, scale: display.scale)
            target = .area(display: display.id, rect: rect); return
        }
        throw invalid("TARGET (display, window:id/bundleID, area:x,y,width,height)")
    }
}
