import AppKit
import Foundation
import YapcamCore

/// Turns errors into messages a person can act on: what happened, and what to do next.
/// Never shows a bare error code or an `NSError` dump.
enum UserMessage {
    /// Display name and System Settings pane for each permission (`Permission.rawValue`).
    static func permissionName(_ raw: String) -> String {
        switch raw {
        case "screen": "Screen & System Audio Recording"
        case "microphone": "Microphone"
        case "camera": "Camera"
        case "accessibility": "Accessibility"
        case "inputMonitoring": "Input Monitoring"
        default: raw.capitalized
        }
    }

    static func appPermission(_ raw: String) -> AppPermission? { AppPermission(rawValue: raw) }

    static func permissionDenied(_ raw: String) -> String {
        "Yapcam doesn't have \(permissionName(raw)) access. Open System Settings → Privacy & Security → \(permissionName(raw)), turn Yapcam on, then try again. If it is already on, quit and reopen Yapcam."
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? EngineError { return describe(e) }
        if let e = error as? CoreError { return describe(e) }
        let ns = error as NSError
        if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
            if ns.code == -3801 { return permissionDenied("screen") }
            return "Screen capture stopped unexpectedly (macOS code \(ns.code)). Try again; if it keeps happening, quit and reopen Yapcam."
        }
        return clean(error.localizedDescription, fallback: "Something went wrong.")
    }

    static func describe(_ e: EngineError) -> String {
        switch e {
        case .unavailable(let m): return clean(m, fallback: "This feature isn't available in this build.")
        case .permissionDenied(let p): return permissionDenied(p)
        case .diskFull(let b):
            return "There isn't enough free disk space (\(ByteCountFormatter.string(fromByteCount: b, countStyle: .file)) left). Free up space or choose another recordings folder in Settings → Storage."
        case .failed(let m): return clean(m, fallback: "The operation failed.")
        }
    }

    static func describe(_ e: CoreError) -> String {
        switch e {
        case .status(_, let m): return clean(m, fallback: "The project could not be read or changed.")
        case .missingMedia(let paths): return "Some recording files are missing (\(paths.count)). Use Locate… to find them, or restore them from a backup."
        case .unsupportedVersion: return "This recording was made with a newer version of Yapcam. Update Yapcam to open it."
        }
    }

    /// Strips technical suffixes and refuses to show an NSError dump or a lone code.
    static func clean(_ raw: String, fallback: String) -> String {
        var m = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        m = m.replacingOccurrences(of: #"\s*\(os error \d+\)"#, with: "", options: .regularExpression)
        let lower = m.lowercased()
        if m.isEmpty || lower.contains("error domain=") || lower.hasPrefix("the operation couldn’t be completed")
            || lower.hasPrefix("the operation couldn't be completed") || m.range(of: #"^[-\d\s.:]+$"#, options: .regularExpression) != nil {
            return "\(fallback) If it keeps happening, use Yapcam → Export Diagnostics… and send the report."
        }
        if let last = m.last, !".!?”\")".contains(last) { m += "." }
        return m
    }
}

extension AppAlert {
    init(title: String, error: Error) {
        self.init(title: title, message: UserMessage.describe(error))
        if case EngineError.permissionDenied(let p) = error { permission = UserMessage.appPermission(p) }
        if (error as NSError).code == -3801, (error as NSError).domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" { permission = .screen }
    }
}
