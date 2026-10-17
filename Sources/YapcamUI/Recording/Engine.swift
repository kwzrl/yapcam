import AppKit
import YapcamCapture

/// What the UI asks the capture layer to record. Mirrors `RecordingOptions` /
/// `CaptureTarget` from docs/SWIFT_API.md; `LiveEngine` converts 1:1.
enum UITarget: Equatable, Codable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case area(display: CGDirectDisplayID, rect: CGRect)
    case device(String)                     // USB iPhone/iPad screen, by capture's device id
}

struct UIRecordingOptions {
    var target: UITarget
    var systemAudio: Bool
    /// With `systemAudio` on: nil records all apps, otherwise only these bundle ids.
    var systemAudioApps: [String]? = nil
    var microphoneID: String?
    var cameraID: String?
    var cameraMaxResolution: CameraMaxResolution = .hd1080
    var recordKeystrokes: Bool
    var maxFPS: Int
    /// Exclude Finder's desktop-icon surfaces from display/area capture without changing Finder preferences.
    var hideDesktopIcons: Bool = false
    var outputDirectory: URL
}

enum EngineError: LocalizedError {
    case unavailable(String)
    case permissionDenied(String)
    case diskFull(availableBytes: Int64)
    case failed(String)

    var errorDescription: String? { UserMessage.describe(self) }
}

/// One recording in flight. The only place the app talks to the capture layer.
@MainActor protocol EngineSession: AnyObject {
    var elapsed: TimeInterval { get }
    var micLevel: Float { get }
    var warnings: [String] { get }
    /// True when the session ended on its own (stream failure, disk full, device loss).
    var failure: EngineError? { get }
    /// The recording folder once capture has created it.
    var packageURL: URL? { get }
    func start() async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws -> URL
    func cancel() async
}

@MainActor protocol RecordingEngine {
    func makeSession(_ options: UIRecordingOptions) -> EngineSession
    func registerExcluded(_ window: NSWindow)
    func unregisterExcluded(_ window: NSWindow)
    func openEditor(package: URL)
    func interruptedPackages(in directory: URL) -> [URL]
    func recover(_ package: URL) throws -> URL
    /// Read-only checks before a recording starts (GAP-CAP-6). `options` carries the devices the user chose,
    /// even ones that are gone, so a missing device can be reported.
    func preflight(_ options: UIRecordingOptions) async -> [PreflightIssue]
}

extension RecordingEngine { func preflight(_ options: UIRecordingOptions) async -> [PreflightIssue] { [] } }

extension EngineSession { var packageURL: URL? { nil } }
