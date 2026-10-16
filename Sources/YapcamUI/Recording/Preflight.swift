import AppKit
import YapcamCapture

/// A condition found before recording starts (GAP-CAP-6). Mirrors capture's `CapturePreflightIssue`.
struct PreflightIssue: Equatable, Identifiable {
    enum Kind: String {
        case cameraWithoutMicrophone, cameraMissing, microphoneMissing, microphoneLidClosed
        case permissionRequired, applicationAudioUnavailable, windowResizePermission
    }
    var kind: Kind
    var message: String
    var permission: AppPermission?
    var id: String { kind.rawValue + (permission?.rawValue ?? "") }

    init(kind: Kind, message: String, permission: AppPermission? = nil) {
        self.kind = kind; self.message = message; self.permission = permission
    }

    init(_ i: CapturePreflightIssue) {
        self.init(kind: Kind(rawValue: i.kind.rawValue) ?? .permissionRequired, message: i.message,
                  permission: i.permission.flatMap { AppPermission(rawValue: $0.rawValue) })
    }
}

/// The choices a prompt can offer. Each issue shows the subset that makes sense for it.
enum PreflightChoice: Equatable {
    case `continue`            // go on as things are (the missing input is simply not recorded)
    case chooseDevice          // stop and open Settings → Recording to pick another device / apps
    case openSettings(AppPermission)
    case recordAllAppAudio     // replace a broken "selected apps" list with all apps
    case cancel
}

/// What the flow decided for the recording.
enum PreflightOutcome: Equatable {
    case start(systemAudioApps: [String]?)
    case cancel
    case chooseDevice
    case openSettings(AppPermission)
}

enum PreflightFlow {
    /// The buttons for an issue, first = default. Pure so every condition is testable.
    static func choices(for issue: PreflightIssue) -> [PreflightChoice] {
        switch issue.kind {
        case .cameraWithoutMicrophone: return [.continue, .chooseDevice, .cancel]
        case .cameraMissing, .microphoneMissing, .microphoneLidClosed: return [.continue, .chooseDevice, .cancel]
        case .permissionRequired:
            guard let p = issue.permission else { return [.cancel] }
            // Without Screen Recording there is nothing to record; camera/mic can be left out.
            return p == .screen ? [.openSettings(p), .cancel] : [.openSettings(p), .continue, .cancel]
        case .applicationAudioUnavailable: return [.chooseDevice, .recordAllAppAudio, .cancel]
        case .windowResizePermission: return [.openSettings(.accessibility), .continue, .cancel]
        }
    }

    static func title(for issue: PreflightIssue) -> String {
        switch issue.kind {
        case .cameraWithoutMicrophone: "Record a camera without sound?"
        case .cameraMissing: "Camera not found"
        case .microphoneMissing: "Microphone not found"
        case .microphoneLidClosed: "Microphone may be covered"
        case .permissionRequired: "Permission needed"
        case .applicationAudioUnavailable: "App audio can't be recorded"
        case .windowResizePermission: "Accessibility needed"
        }
    }

    static func label(_ c: PreflightChoice, for issue: PreflightIssue) -> String {
        switch c {
        case .continue:
            switch issue.kind {
            case .cameraWithoutMicrophone: return "Record Without Sound"
            case .cameraMissing, .microphoneMissing: return "Continue Without It"
            case .permissionRequired: return "Continue Without It"
            default: return "Continue"
            }
        case .chooseDevice: return issue.kind == .applicationAudioUnavailable ? "Choose Apps…" : "Choose Device…"
        case .openSettings: return "Open System Settings"
        case .recordAllAppAudio: return "Record All Apps"
        case .cancel: return "Cancel"
        }
    }

    /// Walks the issues in order; the first non-continuing answer ends the flow. Never asks when there is none.
    @MainActor static func resolve(_ issues: [PreflightIssue], systemAudioApps: [String]?,
                                   ask: @MainActor (PreflightIssue, [PreflightChoice]) -> PreflightChoice) -> PreflightOutcome {
        var apps = systemAudioApps
        for issue in issues {
            let allowed = choices(for: issue)
            let answer = ask(issue, allowed)
            guard allowed.contains(answer) else { return .cancel }
            switch answer {
            case .continue: continue
            case .recordAllAppAudio: apps = nil
            case .chooseDevice: return .chooseDevice
            case .openSettings(let p): return .openSettings(p)
            case .cancel: return .cancel
            }
        }
        return .start(systemAudioApps: apps)
    }

    /// The real prompt: one alert per condition.
    @MainActor static func askWithAlert(_ issue: PreflightIssue, _ choices: [PreflightChoice]) -> PreflightChoice {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title(for: issue)
        a.informativeText = issue.message
        for c in choices { a.addButton(withTitle: label(c, for: issue)) }
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(r) ? choices[r] : .cancel
    }
}
