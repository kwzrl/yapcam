import Foundation

/// What a click on the menu-bar icon does (REC-10).
enum MenuBarClick {
    enum Action: Equatable { case showPicker, showMenu, toggleRecording }
    static func action(phase: RecordingPhase, rightClick: Bool, optionHeld: Bool) -> Action {
        switch phase {
        case .idle: return (rightClick || optionHeld) ? .showMenu : .showPicker
        default: return .toggleRecording       // while a take runs (or counts down) the icon stays click-to-stop
        }
    }
}
