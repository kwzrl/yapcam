import AppKit

/// What the Dock icon's right-click menu offers in each recording phase (REC-46). Pure, so the lists are testable.
enum DockMenu {
    enum Kind: Equatable {
        case finish, pauseResume, restart, cancel, cancelCountdown, settings, newRecording, openLast, keepInDock, separator
    }
    struct Item: Equatable {
        var kind: Kind
        var title: String
        var enabled = true
        var checked = false
    }

    static func items(phase: RecordingPhase, showInDock: Bool) -> [Item] {
        switch phase {
        case .idle:
            return [Item(kind: .newRecording, title: "New Recording"), Item(kind: .openLast, title: "Open Last Recording"),
                    Item(kind: .separator, title: ""), Item(kind: .settings, title: "Settings…"),
                    Item(kind: .keepInDock, title: "Keep in Dock", checked: showInDock)]
        case .countdown:
            return [Item(kind: .cancelCountdown, title: "Cancel Countdown")]
        case .starting, .finishing:
            return [Item(kind: .finish, title: "Finish Recording", enabled: false), Item(kind: .separator, title: ""),
                    Item(kind: .settings, title: "Settings…")]
        case .recording, .paused:
            return [Item(kind: .finish, title: "Finish Recording"),
                    Item(kind: .pauseResume, title: phase == .paused ? "Resume Recording" : "Pause Recording"),
                    Item(kind: .restart, title: "Restart Recording…"), Item(kind: .cancel, title: "Cancel Recording…"),
                    Item(kind: .separator, title: ""), Item(kind: .settings, title: "Settings…")]
        }
    }
}

/// What ⌘⌃↩ (Start / finish) does in each state (REC-09): when idle the first press opens the picker.
enum StartStopRule {
    enum Action: Equatable { case showPicker, begin, stop, cancelCountdown, none }
    static func action(phase: RecordingPhase, pickerVisible: Bool, overlayActive: Bool) -> Action {
        switch phase {
        case .idle: return (!pickerVisible && !overlayActive) ? .showPicker : .begin   // an open overlay or the bar: record
        case .countdown: return .cancelCountdown
        case .recording, .paused: return .stop
        case .starting, .finishing: return .none
        }
    }
}
