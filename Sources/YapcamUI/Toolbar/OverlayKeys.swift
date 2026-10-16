import AppKit

/// Keyboard rules shared by the display, window and area overlays: Return starts recording, Esc cancels.
/// They are applied by a local key monitor, so they hold no matter which control inside the overlay has focus
/// (a SwiftUI menu or text field would otherwise swallow Return) and whether or not the overlay is key yet.
enum OverlayKeys {
    enum Action: Equatable { case start, cancel, pass }

    /// `typing` is true while a text field is being edited: Return then belongs to the field (it commits the
    /// value); the next Return starts.
    static func action(keyCode: UInt16, typing: Bool) -> Action {
        switch keyCode {
        case 53: return .cancel                       // Esc always cancels
        case 36, 76: return typing ? .pass : .start   // Return / keypad Enter
        default: return .pass
        }
    }

    /// Installs the monitor; returns a token for `remove`. Events are consumed when they trigger an action.
    @MainActor static func install(start: @escaping () -> Void, cancel: @escaping () -> Void) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let typing = NSApp.keyWindow?.firstResponder is NSText
            switch action(keyCode: event.keyCode, typing: typing) {
            case .start: start(); return nil
            case .cancel: cancel(); return nil
            case .pass: return event
            }
        }
    }

    @MainActor static func remove(_ token: Any?) { if let token { NSEvent.removeMonitor(token) } }

    /// A hotkey fires while another app is in front: macOS only honors a request to become the active app
    /// (and so give the overlay the keyboard) with the explicit "ignore other apps" form.
    @MainActor static func takeKeyboard(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window?.makeKeyAndOrderFront(nil)
    }
}
