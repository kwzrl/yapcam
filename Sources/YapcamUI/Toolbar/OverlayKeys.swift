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
            // A modal prompt (for example "Set size…") owns the keyboard: Esc/Return belong to it.
            if NSApp.modalWindow != nil { return event }
            let typing = NSApp.keyWindow?.firstResponder is NSText
            // Auto-repeat of a held key must not act twice (a held Return would skip the Get-ready countdown).
            switch action(keyCode: event.keyCode, typing: typing) {
            case .start: if !event.isARepeat { start() }; return nil
            case .cancel: if !event.isARepeat { cancel() }; return nil
            case .pass: return event
            }
        }
    }

    @MainActor static func remove(_ token: Any?) { if let token { NSEvent.removeMonitor(token) } }

    /// A hotkey fires while another app is in front: macOS only honors a request to become the active app
    /// (and so give the overlay the keyboard) with the explicit "ignore other apps" form.
    @MainActor static func takeKeyboard(_ window: NSWindow?) {
        OverlayFocus.remember()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The overlays need the keyboard, so Yapcam becomes the active app while one is up. Whatever app the user was
/// in is remembered and brought back when the overlay goes away, so the recording shows (and keystrokes reach)
/// the user's own app, never Yapcam's editor or Settings windows.
@MainActor enum OverlayFocus {
    static var frontmost: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    static var activate: (NSRunningApplication) -> Void = { $0.activate(options: []) }
    private(set) static var previous: NSRunningApplication?

    static func remember() {
        guard previous == nil, let app = frontmost(), app != NSRunningApplication.current else { return }
        previous = app
    }

    static func restore() {
        guard let app = previous else { return }
        previous = nil
        if !app.isTerminated { activate(app) }
    }
}
