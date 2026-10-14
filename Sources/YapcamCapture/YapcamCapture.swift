import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

public struct DisplaySource: Identifiable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let frame: CGRect
    public let scale: CGFloat
    public let pixelSize: CGSize
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
}

public struct CaptureSources: Sendable {
    public var displays: [DisplaySource]
    public var windows: [WindowSource]
    public var cameras: [CaptureDevice]
    public var microphones: [CaptureDevice]

    public static func load() async throws -> CaptureSources {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let names = await MainActor.run {
            Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (UInt32, String)? in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
                return (id, screen.localizedName)
            })
        }
        let displays = content.displays.map { display in
            let bounds = CGDisplayBounds(display.displayID)
            let scale = CGFloat(SCContentFilter(display: display, excludingWindows: []).pointPixelScale)
            let pixels = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
            return DisplaySource(id: display.displayID, name: names[display.displayID] ?? "Display", frame: bounds,
                                 scale: scale, pixelSize: pixels)
        }
        let windows = content.windows.filter { $0.frame.width > 1 && $0.frame.height > 1 }.map {
            WindowSource(id: $0.windowID, title: $0.title ?? "", appName: $0.owningApplication?.applicationName ?? "",
                         bundleID: $0.owningApplication?.bundleIdentifier, frame: $0.frame, thumbnail: nil)
        }
        return CaptureSources(displays: displays, windows: windows,
                              cameras: devices(.video), microphones: devices(.audio))
    }

    static func devices(_ media: AVMediaType) -> [CaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = media == .video
            ? [.builtInWideAngleCamera, .external, .continuityCamera] : [.microphone, .external]
        let defaultID = AVCaptureDevice.default(for: media)?.uniqueID
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: media, position: .unspecified).devices.map {
            CaptureDevice(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultID)
        }
    }
}

public enum CaptureTarget: Sendable, Codable, Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case area(display: CGDirectDisplayID, rect: CGRect)
}

public struct RecordingOptions: Sendable, Codable {
    public var target: CaptureTarget
    public var systemAudio: Bool
    public var microphoneID: String?
    public var cameraID: String?
    public var recordKeystrokes: Bool
    public var maxFPS: Int
    public var excludeYapcamWindows: Bool
    public var outputDirectory: URL

    public init(target: CaptureTarget, systemAudio: Bool = true, microphoneID: String? = nil,
                cameraID: String? = nil, recordKeystrokes: Bool = false, maxFPS: Int = 60,
                excludeYapcamWindows: Bool = true, outputDirectory: URL) {
        self.target = target; self.systemAudio = systemAudio; self.microphoneID = microphoneID
        self.cameraID = cameraID; self.recordKeystrokes = recordKeystrokes; self.maxFPS = maxFPS
        self.excludeYapcamWindows = excludeYapcamWindows; self.outputDirectory = outputDirectory
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
