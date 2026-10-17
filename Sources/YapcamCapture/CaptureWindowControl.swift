import AppKit
import ApplicationServices

public enum CaptureWindowControlError: LocalizedError, Sendable, Equatable {
    case invalidSize, ambiguousWindow, notResizable, accessibilityFailure(Int32)
    case sizeNotApplied(requested: CGSize, actual: CGSize)

    public var errorDescription: String? {
        switch self {
        case .invalidSize: "Choose a finite window size between 2 and 32768 points."
        case .ambiguousWindow: "The selected window cannot be identified uniquely. Select it again."
        case .notResizable: "This window does not allow resizing."
        case .accessibilityFailure(let code): "The window did not respond to Accessibility (\(code))."
        case .sizeNotApplied(let requested, let actual):
            "The app used \(Int(actual.width)) × \(Int(actual.height)) instead of \(Int(requested.width)) × \(Int(requested.height)) points."
        }
    }
}

/// Operations on the actual source window, rather than a crop of the recording.
/// Coordinates and sizes are global top-left logical points, including Retina.
@MainActor public enum CaptureWindowControl {
    /// Returns refreshed bounds only after the owning app applies the exact size.
    /// Apps may impose minimum sizes or aspect ratios; those produce sizeNotApplied.
    @discardableResult public static func resize(windowID: CGWindowID, to size: CGSize) async throws -> CGRect {
        try await resize(windowID: windowID, to: size, services: .live)
    }

    public static func raise(windowID: CGWindowID) throws {
        let window = try select(windowID: windowID, services: .live)
        try window.raise()
    }

    static func select(windowID: CGWindowID, services: WindowControlServices) throws -> WindowControlHandle {
        guard services.permission() == .granted else { throw CaptureError.permissionDenied(.accessibility) }
        let target = try services.target(windowID)
        let windows = try services.windows(target.pid)
        let indices = windows.indices.filter { WindowControlPolicy.matches(target, frame: windows[$0].frame) }
        let matches = indices.filter { target.title.isEmpty || windows[$0].title.isEmpty || windows[$0].title == target.title }
        guard matches.count == 1, let index = matches.first else {
            if matches.isEmpty { throw CaptureError.sourceUnavailable }
            throw CaptureWindowControlError.ambiguousWindow
        }
        return windows[index]
    }

    static func resize(windowID: CGWindowID, to size: CGSize, services: WindowControlServices) async throws -> CGRect {
        guard WindowControlPolicy.valid(size) else { throw CaptureWindowControlError.invalidSize }
        try Task.checkCancellation()
        let window = try select(windowID: windowID, services: services)
        guard window.resizable else { throw CaptureWindowControlError.notResizable }
        try window.setSize(size)
        var actual = try window.readFrame()
        // AX writes can return before the target's layout pass completes.
        for _ in 0..<10 {
            try Task.checkCancellation()
            if WindowControlPolicy.applied(size, actual: actual.size) { return actual }
            try await services.wait()
            actual = try window.readFrame()
        }
        throw CaptureWindowControlError.sizeNotApplied(requested: size, actual: actual.size)
    }
}

struct WindowControlIdentity {
    let pid: Int32
    let frame: CGRect
    let title: String
}

enum WindowControlPolicy {
    static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && (2...32768).contains(size.width) && (2...32768).contains(size.height)
    }
    static func matches(_ target: WindowControlIdentity, frame: CGRect) -> Bool {
        abs(target.frame.minX - frame.minX) < 2 && abs(target.frame.minY - frame.minY) < 2
        && abs(target.frame.width - frame.width) < 2 && abs(target.frame.height - frame.height) < 2
    }
    static func applied(_ requested: CGSize, actual: CGSize) -> Bool {
        abs(requested.width - actual.width) < 0.5 && abs(requested.height - actual.height) < 0.5
    }
}

@MainActor struct WindowControlHandle {
    let frame: CGRect
    let title: String
    let resizable: Bool
    let readFrame: () throws -> CGRect
    let setSize: (CGSize) throws -> Void
    let raise: () throws -> Void
}

@MainActor struct WindowControlServices {
    var permission: () -> PermissionState
    var target: (CGWindowID) throws -> WindowControlIdentity
    var windows: (Int32) throws -> [WindowControlHandle]
    var wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(30)) }

    static var live: Self {
        Self(permission: { CapturePermissions.state(.accessibility) }, target: { id in
            guard let values = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
                  let info = values.first, let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { throw CaptureError.sourceUnavailable }
            return WindowControlIdentity(pid: pid, frame: frame, title: info[kCGWindowName as String] as? String ?? "")
        }, windows: { pid in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            var value: CFTypeRef?
            try check(AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value))
            guard let elements = value as? [AXUIElement] else { throw CaptureError.sourceUnavailable }
            return elements.compactMap { element in
                AXUIElementSetMessagingTimeout(element, 0.5)
                guard let initial = try? frame(element) else { return nil }
                var title: CFTypeRef?, settable = DarwinBoolean(false)
                _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
                let canSet = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
                return WindowControlHandle(frame: initial, title: title as? String ?? "", resizable: canSet,
                    readFrame: { try frame(element) }, setSize: { size in
                        var size = size
                        guard let value = AXValueCreate(.cgSize, &size) else { throw CaptureWindowControlError.invalidSize }
                        try check(AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value))
                    }, raise: {
                        try check(AXUIElementPerformAction(element, kAXRaiseAction as CFString))
                        NSRunningApplication(processIdentifier: pid)?.activate()
                    })
            }
        })
    }

    private static func check(_ result: AXError) throws {
        guard result == .success else { throw CaptureWindowControlError.accessibilityFailure(result.rawValue) }
    }

    private static func frame(_ window: AXUIElement) throws -> CGRect {
        var position: CFTypeRef?, size: CFTypeRef?
        try check(AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position))
        try check(AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size))
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw CaptureError.sourceUnavailable
        }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, WindowControlPolicy.valid(dimensions) else { throw CaptureError.sourceUnavailable }
        return CGRect(origin: point, size: dimensions)
    }
}

enum CaptureWindowPolicy {
    static func isPickable(pid: Int32?, bundleID: String?, layer: Int, frame: CGRect,
                           ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                           ownBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        guard let pid, pid > 0, pid != ownPID, ownBundleID == nil || bundleID != ownBundleID,
              layer == Int(CGWindowLevelForKey(.normalWindow)), frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite, frame.width >= 2, frame.height >= 2 else { return false }
        return !["com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter", "com.apple.systemuiserver",
                 "com.apple.notificationcenterui", "com.apple.WindowServer"].contains(bundleID ?? "")
    }
}
