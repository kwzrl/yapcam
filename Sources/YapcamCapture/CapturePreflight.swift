import Foundation
import IOKit

public struct CapturePreflightIssue: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case cameraWithoutMicrophone, cameraMissing, microphoneMissing, microphoneLidClosed
        case permissionRequired, applicationAudioUnavailable, windowResizePermission
    }
    public let kind: Kind
    public let message: String
    public let permission: Permission?
    public var id: String { kind.rawValue + (permission?.rawValue ?? "") }
}

/// Read-only checks for the picker. UI owns confirmation/permission presentation;
/// RecordingSession still validates source permissions at start and during capture.
@MainActor public enum CapturePreflight {
    public static func check(options: RecordingOptions, sources: CaptureSources) -> [CapturePreflightIssue] {
        issues(options: options, sources: sources, lidClosed: laptopLidClosed(), permission: CapturePermissions.state)
    }

    /// Call when offering an actual window resize, not for ordinary window capture.
    public static func windowResizeIssue() -> CapturePreflightIssue? {
        resizeIssue(accessibility: CapturePermissions.state(.accessibility))
    }

    static func resizeIssue(accessibility: PermissionState) -> CapturePreflightIssue? {
        guard accessibility != .granted else { return nil }
        return CapturePreflightIssue(kind: .windowResizePermission,
            message: "Enable Accessibility to change another application's window size.", permission: .accessibility)
    }

    static func issues(options: RecordingOptions, sources: CaptureSources, lidClosed: Bool?,
                       permission: (Permission) -> PermissionState) -> [CapturePreflightIssue] {
        var result: [CapturePreflightIssue] = []
        func append(_ kind: CapturePreflightIssue.Kind, _ message: String, _ p: Permission? = nil) {
            result.append(CapturePreflightIssue(kind: kind, message: message, permission: p))
        }
        let device: Bool
        if case .device = options.target { device = true } else { device = false }
        let hasMic = options.microphoneID.map { id in sources.microphones.contains { $0.id == id } } ?? false
        let hasCamera = options.cameraID.map { id in sources.cameras.contains { $0.id == id } } ?? false
        if options.cameraID != nil && !hasCamera { append(.cameraMissing, "The chosen camera is disconnected. Choose another camera or continue without it.") }
        if options.microphoneID != nil && !hasMic { append(.microphoneMissing, "The chosen microphone is disconnected. Choose another microphone or continue without it.") }
        if hasCamera && !hasMic && !(device && options.systemAudio) {
            append(.cameraWithoutMicrophone, "The camera will be recorded without a microphone. Continue with a silent camera?")
        }
        if lidClosed == true, let id = options.microphoneID,
           sources.microphones.contains(where: { $0.id == id && $0.isBuiltIn }) {
            append(.microphoneLidClosed, "The laptop lid is closed. Its internal microphone may be muted or obstructed.")
        }
        var required: [Permission] = device ? [.camera] : [.screen]
        if options.cameraID != nil && !required.contains(.camera) { required.append(.camera) }
        if options.microphoneID != nil || (device && options.systemAudio) { required.append(.microphone) }
        for p in required where permission(p) != .granted {
            append(.permissionRequired, "Allow \(p.rawValue) access before recording with this input.", p)
        }
        if case .applications = options.systemAudioSelection {
            if device {
                append(.applicationAudioUnavailable, "Select all device audio or turn audio off for a USB screen.")
            } else {
                do { _ = try SystemAudioPolicy.selectedBundleIDs(options.systemAudioSelection, available: Set(sources.applications.map(\.bundleID))) }
                catch { append(.applicationAudioUnavailable, error.localizedDescription) }
            }
        }
        return result
    }

    private static func laptopLidClosed() -> Bool? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOPMrootDomain")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return (IORegistryEntryCreateCFProperty(entry, "AppleClamshellState" as CFString,
                    kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.boolValue
    }
}
