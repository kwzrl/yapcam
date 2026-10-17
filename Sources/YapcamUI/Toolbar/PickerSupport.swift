import AppKit
import AVFoundation

/// Which source overlay is open right now (the picker bar highlights that mode; Esc on the bar closes the bar
/// only when no mode is open).
@MainActor final class PickerState: ObservableObject {
    static let shared = PickerState()
    @Published var openMode: SourceMode?
}

/// Opens the overlay of a source mode: the one entry point for the picker buttons, the global shortcuts
/// and the 1 / 2 / 3 keys.
@MainActor enum SourcePicker {
    static func open(_ mode: SourceMode, display: UInt32? = nil) {
        let s = AppSettings.shared
        guard RecordingController.shared.phase == .idle else { return }
        if PickerState.shared.openMode == mode, display == nil { return }
        s.sourceMode = mode
        switch mode {
        case .display: SourceOverlay.shared.show(.display, pinnedDisplay: display)
        case .window: SourceOverlay.shared.show(.window)
        case .area: AreaPicker.begin(onDisplay: display)
        case .device: return
        }
        PickerState.shared.openMode = mode
    }

    /// Esc on the bar: a source is selected → deselect it (close its overlay); none → close the bar.
    @discardableResult static func escape() -> Bool {
        if PickerState.shared.openMode != nil {
            SourceOverlay.shared.hide(); AreaSelector.shared.end(nil)
            PickerState.shared.openMode = nil
            return true
        }
        ToolbarPanelController.shared.hide()
        return true
    }
}

/// What a Start / area confirm / window pick writes into the settings, as one pure function so it is testable
/// without windows. Each case changes several @Published settings back to back (the crash class from 0.10.0).
enum SourceChoice: Equatable {
    case display(UInt32)
    case window(UInt32)
    case area(display: UInt32, rect: CGRect)

    /// An area smaller than the recordable minimum is refused (nil): the confirm button does nothing.
    static func confirmedArea(display: UInt32, rect: CGRect?) -> SourceChoice? {
        guard let rect, AreaGeometry.canRecord(rect) else { return nil }
        return .area(display: display, rect: rect.integral)
    }
    @MainActor func apply(to s: AppSettings) {
        switch self {
        case .display(let id): s.displayID = id; s.sourceMode = .display
        case .window(let id): s.windowID = id; s.sourceMode = .window
        case .area(let id, let rect): s.areaDisplayID = id; s.areaRect = rect; s.sourceMode = .area
        }
    }
}

/// The recording widget's timer: grows with the length (0:00 → 00:00 → 0:00:00 → 00:00:00), like the reference.
enum RecordingTimeFormat {
    static func string(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = (s / 60) % 60, sec = s % 60
        if h >= 10 { return String(format: "%02d:%02d:%02d", h, m, sec) }
        if h >= 1 { return String(format: "%d:%02d:%02d", h, m, sec) }
        if m >= 10 { return String(format: "%02d:%02d", m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

/// Text on the picker bar's device buttons.
enum DeviceLabels {
    static func camera(name: String?) -> String { name ?? "No camera" }
    static func microphone(name: String?) -> String { name ?? "No microphone" }
    /// Menu row text: the system default device carries a "(default)" suffix.
    static func menuName(_ name: String, isDefault: Bool) -> String { isDefault ? "\(name) (default)" : name }
}

extension DeviceModel {
    var defaultCameraID: String? { AVCaptureDevice.default(for: .video)?.uniqueID }
    var defaultMicrophoneID: String? { AVCaptureDevice.default(for: .audio)?.uniqueID }
}
