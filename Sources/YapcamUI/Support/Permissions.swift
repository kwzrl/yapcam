import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

enum AppPermission: String, CaseIterable, Identifiable {
    case screen, microphone, camera, accessibility, inputMonitoring
    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: "Screen & system audio recording"
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input monitoring"
        }
    }
    var reason: String {
        switch self {
        case .screen: "Needed to record your display, windows and system audio."
        case .microphone: "Needed only if you record your voice. Optional."
        case .camera: "Needed only if you add a camera overlay. Optional."
        case .accessibility: "Lets Yapcam follow window focus and the cursor precisely. Optional."
        case .inputMonitoring: "Lets Yapcam record clicks and, if enabled, keystrokes for zoom and effects. Recommended."
        }
    }
    var symbol: String {
        switch self {
        case .screen: "rectangle.inset.filled.on.rectangle"
        case .microphone: "mic"
        case .camera: "video"
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard"
        }
    }
    /// Required permissions block recording; optional ones only block their feature.
    var isRequired: Bool { self == .screen }
    var settingsURL: URL {
        let pane: String
        switch self {
        case .screen: pane = "Privacy_ScreenCapture"
        case .microphone: pane = "Privacy_Microphone"
        case .camera: pane = "Privacy_Camera"
        case .accessibility: pane = "Privacy_Accessibility"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

enum AppPermissionState { case granted, denied, notDetermined }

@MainActor final class PermissionsModel: ObservableObject {
    static let shared = PermissionsModel()
    @Published private(set) var states: [AppPermission: AppPermissionState] = [:]

    private init() {
        refresh()
        // Permissions change in System Settings while we run; re-check on activation.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func state(_ p: AppPermission) -> AppPermissionState { states[p] ?? .notDetermined }

    func refresh() {
        var s: [AppPermission: AppPermissionState] = [:]
        s[.screen] = CGPreflightScreenCaptureAccess() ? .granted : .denied
        s[.microphone] = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        s[.camera] = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        s[.accessibility] = AXIsProcessTrusted() ? .granted : .denied
        s[.inputMonitoring] = CGPreflightListenEventAccess() ? .granted : .denied
        if s != states { states = s }
    }

    private static func map(_ st: AVAuthorizationStatus) -> AppPermissionState {
        switch st { case .authorized: .granted; case .notDetermined: .notDetermined; default: .denied }
    }

    private func requestedKey(_ p: AppPermission) -> String { "permissionRequested.\(p.rawValue)" }
    /// Screen, accessibility and input monitoring report `.denied` both before and after the
    /// first ask, so we remember whether we already asked.
    func hasRequested(_ p: AppPermission) -> Bool { UserDefaults.standard.bool(forKey: requestedKey(p)) }

    /// What the permission button does: the first press asks macOS, later presses open Settings.
    func act(_ p: AppPermission) {
        if state(p) == .notDetermined || !hasRequested(p) { request(p) } else { open(p) }
    }

    /// Triggers the system prompt where macOS has one.
    func request(_ p: AppPermission) {
        UserDefaults.standard.set(true, forKey: requestedKey(p))
        switch p {
        case .screen: _ = CGRequestScreenCaptureAccess()
        case .microphone, .camera:
            let type: AVMediaType = p == .microphone ? .audio : .video
            if AVCaptureDevice.authorizationStatus(for: type) == .notDetermined {
                AVCaptureDevice.requestAccess(for: type) { _ in Task { @MainActor in self.refresh() } }
            } else { open(p) }
        case .accessibility: _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .inputMonitoring: _ = CGRequestListenEventAccess()
        }
        refresh()
    }

    func open(_ p: AppPermission) { NSWorkspace.shared.open(p.settingsURL) }
}
