import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import IOKit.audio

public struct DisplaySource: Identifiable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let frame: CGRect
    public let scale: CGFloat
    public let pixelSize: CGSize
    public let refreshRate: Double

    public init(id: CGDirectDisplayID, name: String, frame: CGRect, scale: CGFloat, pixelSize: CGSize, refreshRate: Double = 60) {
        self.id = id; self.name = name; self.frame = frame; self.scale = scale
        self.pixelSize = pixelSize; self.refreshRate = refreshRate
    }
}

public struct WindowSource: Identifiable, Sendable {
    public let id: CGWindowID
    public let title: String
    public let appName: String
    public let bundleID: String?
    public let frame: CGRect
    public let thumbnail: CGImage?
}

public struct CaptureDevice: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool
    public let isBuiltIn: Bool
    public init(id: String, name: String, isDefault: Bool, isBuiltIn: Bool = false) {
        self.id = id; self.name = name; self.isDefault = isDefault; self.isBuiltIn = isBuiltIn
    }
}

/// A retained camera sample from the recording's existing AVCaptureSession.
/// Consumers can enqueue it on an AVSampleBufferDisplayLayer without opening
/// the camera a second time. Delivery is coalesced and never blocks recording.
public struct CameraPreviewFrame: @unchecked Sendable {
    public let sampleBuffer: CMSampleBuffer

    init(sampleBuffer: CMSampleBuffer) { self.sampleBuffer = sampleBuffer }
}

public enum CameraPreviewUpdate: Sendable {
    case frame(CameraPreviewFrame)
    case unavailable(String)
}

public struct CaptureSources: Sendable {
    public var displays: [DisplaySource]
    public var windows: [WindowSource]
    public var cameras: [CaptureDevice]
    public var microphones: [CaptureDevice]
    public var applications: [CaptureApplication] = []
    public var deviceScreens: [CaptureDevice] = []
    public var deviceScreenDiscoveryError: String? = nil

    /// USB iOS screen devices, independent of Mac Screen Recording permission.
    public static func loadDeviceScreens() throws -> [CaptureDevice] {
        try DeviceScreenDiscovery.load().enumerated().map { index, device in
            CaptureDevice(id: device.id, name: device.name, isDefault: index == 0)
        }
    }

    public static func load() async throws -> CaptureSources {
        try await load(includeWindowThumbnails: true)
    }

    /// Device polling and noninteractive self-tests can skip window screenshots.
    public static func load(includeWindowThumbnails: Bool) async throws -> CaptureSources {
        let deviceScreens = Result { try loadDeviceScreens() }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let names = await MainActor.run {
            Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (UInt32, String)? in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
                return (id, screen.localizedName)
            })
        }
        let displayIDs = content.displays.map(\.displayID)
        let refreshRates = await MainActor.run {
            Dictionary(uniqueKeysWithValues: displayIDs.map { ($0, CaptureFrameRatePolicy.refreshRate(for: $0)) })
        }
        let displays = content.displays.map { display in
            let bounds = CGDisplayBounds(display.displayID)
            let scale = CGFloat(SCContentFilter(display: display, excludingWindows: []).pointPixelScale)
            let pixels = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
            return DisplaySource(id: display.displayID, name: names[display.displayID] ?? "Display", frame: bounds,
                                 scale: scale, pixelSize: pixels, refreshRate: refreshRates[display.displayID] ?? 60)
        }
        let candidates = content.windows.filter {
            CaptureWindowPolicy.isPickable(pid: $0.owningApplication?.processID,
                bundleID: $0.owningApplication?.bundleIdentifier, layer: $0.windowLayer, frame: $0.frame)
        }
        let windows = try await CaptureThumbnails.sources(candidates, includeImages: includeWindowThumbnails)
        var result = CaptureSources(displays: displays, windows: windows,
                                    cameras: devices(.video), microphones: devices(.audio))
        result.applications = SystemAudioPolicy.applications(content.applications.map {
            CaptureApplication(bundleID: $0.bundleIdentifier, name: $0.applicationName)
        })
        do { result.deviceScreens = try deviceScreens.get() }
        catch { result.deviceScreenDiscoveryError = error.localizedDescription }
        return result
    }

    static func devices(_ media: AVMediaType) -> [CaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = media == .video
            ? [.builtInWideAngleCamera, .external, .continuityCamera] : [.microphone, .external]
        let defaultID = AVCaptureDevice.default(for: media)?.uniqueID
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: media, position: .unspecified).devices.filter {
            media != .video || !DeviceScreenDiscovery.isScreenDevice($0)
        }.map {
            CaptureDevice(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultID,
                          isBuiltIn: $0.transportType == Int32(kIOAudioDeviceTransportTypeBuiltIn))
        }
    }
}

public enum CaptureTarget: Sendable, Codable, Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case area(display: CGDirectDisplayID, rect: CGRect)
    case device(String)
}

public struct RecordingOptions: Sendable, Codable {
    public var target: CaptureTarget
    public var systemAudioSelection: SystemAudioSelection
    /// Compatibility switch. Enabling from off selects all applications.
    public var systemAudio: Bool {
        get { systemAudioSelection != .off }
        set { if !newValue { systemAudioSelection = .off }
              else if systemAudioSelection == .off { systemAudioSelection = .allApplications } }
    }
    public var microphoneID: String?
    /// Snapshot of the record-time clean-voice choice. The raw microphone stays
    /// untouched; the finished mic track carries this into project processing.
    public var cleanVoiceOnRecord: Bool
    /// Requests two-channel microphone capture when the selected device exposes it.
    public var recordStereoMicrophone: Bool
    public var cameraID: String?
    public var cameraMaxResolution: CameraMaxResolution
    public var cameraFrameRate: CameraFrameRate
    public var recordKeystrokes: Bool
    /// 0 follows the initial display refresh rate (default). Positive values are explicit caps.
    public var maxFPS: Int
    public var excludeYapcamWindows: Bool
    public var hideDesktopIcons: Bool
    public var captureNotifications: Bool
    public var outputDirectory: URL

    public init(target: CaptureTarget, systemAudio: Bool = false, microphoneID: String? = nil,
                cleanVoiceOnRecord: Bool = false, recordStereoMicrophone: Bool = false,
                cameraID: String? = nil, recordKeystrokes: Bool = true, maxFPS: Int = 0,
                excludeYapcamWindows: Bool = true, hideDesktopIcons: Bool = false,
                captureNotifications: Bool = true, systemAudioSelection: SystemAudioSelection? = nil,
                cameraMaxResolution: CameraMaxResolution = .hd1080,
                cameraFrameRate: CameraFrameRate = .fps30, outputDirectory: URL) {
        self.target = target; self.systemAudioSelection = systemAudioSelection ?? (systemAudio ? .allApplications : .off); self.microphoneID = microphoneID
        self.cleanVoiceOnRecord = cleanVoiceOnRecord
        self.recordStereoMicrophone = recordStereoMicrophone
        self.cameraID = cameraID; self.cameraMaxResolution = cameraMaxResolution; self.cameraFrameRate = cameraFrameRate
        self.recordKeystrokes = recordKeystrokes; self.maxFPS = maxFPS
        self.excludeYapcamWindows = excludeYapcamWindows; self.outputDirectory = outputDirectory
        self.hideDesktopIcons = hideDesktopIcons; self.captureNotifications = captureNotifications
    }

    enum CodingKeys: String, CodingKey {
        case target, systemAudio, systemAudioSelection, microphoneID, cleanVoiceOnRecord, recordStereoMicrophone
        case cameraID, cameraMaxResolution, cameraFrameRate, recordKeystrokes, maxFPS
        case excludeYapcamWindows, hideDesktopIcons, captureNotifications, outputDirectory
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(target: try values.decode(CaptureTarget.self, forKey: .target),
            systemAudio: try values.decodeIfPresent(Bool.self, forKey: .systemAudio) ?? false,
            microphoneID: try values.decodeIfPresent(String.self, forKey: .microphoneID),
            cleanVoiceOnRecord: try values.decodeIfPresent(Bool.self, forKey: .cleanVoiceOnRecord) ?? false,
            recordStereoMicrophone: try values.decodeIfPresent(Bool.self, forKey: .recordStereoMicrophone) ?? false,
            cameraID: try values.decodeIfPresent(String.self, forKey: .cameraID),
            recordKeystrokes: try values.decodeIfPresent(Bool.self, forKey: .recordKeystrokes) ?? true,
            maxFPS: try values.decodeIfPresent(Int.self, forKey: .maxFPS) ?? 0,
            excludeYapcamWindows: try values.decodeIfPresent(Bool.self, forKey: .excludeYapcamWindows) ?? true,
            hideDesktopIcons: try values.decodeIfPresent(Bool.self, forKey: .hideDesktopIcons) ?? false,
            captureNotifications: try values.decodeIfPresent(Bool.self, forKey: .captureNotifications) ?? true,
            systemAudioSelection: try values.decodeIfPresent(SystemAudioSelection.self, forKey: .systemAudioSelection),
            cameraMaxResolution: try values.decodeIfPresent(CameraMaxResolution.self, forKey: .cameraMaxResolution) ?? .hd1080,
            cameraFrameRate: try values.decodeIfPresent(CameraFrameRate.self, forKey: .cameraFrameRate) ?? .fps30,
            outputDirectory: try values.decode(URL.self, forKey: .outputDirectory))
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(target, forKey: .target)
        try values.encode(systemAudio, forKey: .systemAudio)
        try values.encode(systemAudioSelection, forKey: .systemAudioSelection)
        try values.encodeIfPresent(microphoneID, forKey: .microphoneID)
        try values.encode(cleanVoiceOnRecord, forKey: .cleanVoiceOnRecord)
        try values.encode(recordStereoMicrophone, forKey: .recordStereoMicrophone)
        try values.encodeIfPresent(cameraID, forKey: .cameraID)
        try values.encode(cameraMaxResolution, forKey: .cameraMaxResolution)
        try values.encode(cameraFrameRate, forKey: .cameraFrameRate)
        try values.encode(recordKeystrokes, forKey: .recordKeystrokes)
        try values.encode(maxFPS, forKey: .maxFPS)
        try values.encode(excludeYapcamWindows, forKey: .excludeYapcamWindows)
        try values.encode(hideDesktopIcons, forKey: .hideDesktopIcons)
        try values.encode(captureNotifications, forKey: .captureNotifications)
        try values.encode(outputDirectory, forKey: .outputDirectory)
    }

}

public enum Permission: String, Sendable, Equatable { case screen, microphone, camera, inputMonitoring, accessibility }
public enum PermissionState: Sendable, Equatable { case granted, denied, notDetermined }

public enum CapturePermissions {
    public static func state(_ p: Permission) -> PermissionState {
        switch p {
        case .screen: return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .inputMonitoring: return CGPreflightListenEventAccess() ? .granted : .denied
        case .accessibility: return AXIsProcessTrusted() ? .granted : .denied
        case .microphone, .camera:
            switch AVCaptureDevice.authorizationStatus(for: p == .camera ? .video : .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        }
    }

    public static func request(_ p: Permission) async -> PermissionState {
        switch p {
        case .screen: _ = CGRequestScreenCaptureAccess()
        case .inputMonitoring: _ = CGRequestListenEventAccess()
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .microphone, .camera:
            _ = await AVCaptureDevice.requestAccess(for: p == .camera ? .video : .audio)
        }
        return state(p)
    }

    public static func openSettings(_ p: Permission) {
        let pane: String
        switch p {
        case .screen: pane = "ScreenCapture"
        case .microphone: pane = "Microphone"
        case .camera: pane = "Camera"
        case .inputMonitoring: pane = "ListenEvent"
        case .accessibility: pane = "Accessibility"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") else { return }
        Task { @MainActor in NSWorkspace.shared.open(url) }
    }
}

public enum RecordingState: Sendable, Equatable {
    case idle, preparing, recording, paused, finishing, finished(URL), failed(CaptureError), cancelled
}

public enum CaptureError: LocalizedError, Sendable, Equatable {
    case permissionDenied(Permission), sourceUnavailable, deviceLost(String), diskFull(availableBytes: Int64), writerFailed(String)
    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let permission): return "Access to \(permission.rawValue) is required. Enable it in System Settings."
        case .sourceUnavailable: return "The selected capture source is unavailable."
        case .deviceLost(let name): return "The capture device \(name) is unavailable."
        case .diskFull: return "Recording stopped because less than 1 GB of disk space remains."
        case .writerFailed(let detail): return "Recording failed: \(detail)"
        }
    }
}

extension CaptureError {
    static func from(_ error: Error) -> CaptureError {
        if let error = error as? CaptureError { return error }
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain {
            switch ns.code {
            case SCStreamError.Code.userDeclined.rawValue: return .permissionDenied(.screen)
            case SCStreamError.Code.noCaptureSource.rawValue,
                 SCStreamError.Code.noWindowList.rawValue,
                 SCStreamError.Code.noDisplayList.rawValue: return .sourceUnavailable
            default: break
            }
        }
        return .writerFailed(error.localizedDescription)
    }
}

public enum CaptureExclusions {
    @MainActor static var windowNumbers: Set<Int> = []
    @MainActor public static func register(_ window: NSWindow) { windowNumbers.insert(window.windowNumber) }
    @MainActor public static func unregister(_ window: NSWindow) { windowNumbers.remove(window.windowNumber) }
}
