import AppKit

/// Keyboard rules shared by the display, window and area overlays: Return starts recording, Esc cancels.
/// They are applied by a local key monitor, so they hold no matter which control inside the overlay has focus
/// (a SwiftUI menu or text field would otherwise swallow Return) and whether or not the overlay is key yet.
enum OverlayKeys {
    enum Action: Equatable { case start, cancel, mode(SourceMode), pass }

    /// `typing` is true while a text field is being edited: Return then belongs to the field (it commits the
    /// value); the next Return starts.
    static func action(keyCode: UInt16, typing: Bool, plain: Bool = true) -> Action {
        switch keyCode {
        case 18 where !typing && plain: return .mode(.display)     // 1 / 2 / 3 pick Display / Window / Area while the picker is open
        case 19 where !typing && plain: return .mode(.window)
        case 20 where !typing && plain: return .mode(.area)
        case 53: return .cancel                       // Esc always cancels
        case 36, 76: return typing ? .pass : .start   // Return / keypad Enter
        default: return .pass
        }
    }

    /// Installs the monitors; returns a token for `remove`. Events are consumed when they trigger an action.
    /// With a `window`, the overlay also keeps claiming the keyboard until it really is key (see `KeyClaim`),
    /// and a global monitor stands in for the local one while another app still holds the keyboard.
    @MainActor static func install(window: NSWindow? = nil, start: @escaping () -> Void, cancel: @escaping () -> Void,
                                   mode: ((SourceMode) -> Void)? = nil) -> Any? {
        let token = Token()
        func perform(_ event: NSEvent, typing: Bool, allowMode: Bool = true) -> Bool {
            let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            switch action(keyCode: event.keyCode, typing: typing, plain: plain) {
            case .mode(let m): if allowMode, let mode { if !event.isARepeat { mode(m) }; return true }; return false
            case .start: if !event.isARepeat { start() }; return true
            case .cancel: if !event.isARepeat { cancel() }; return true
            case .pass: return false
            }
        }
        token.local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // A modal prompt (for example "Set size…") owns the keyboard: Esc/Return belong to it.
            if NSApp.modalWindow != nil { return event }
            let typing = NSApp.keyWindow?.firstResponder is NSText
            // Auto-repeat of a held key must not act twice (a held Return would skip the Get-ready countdown).
            return perform(event, typing: typing) ? nil : event
        }
        if let window {
            // Global monitors only see keys that go to OTHER apps, i.e. exactly the case where the activation
            // request has not (yet) taken effect: Return/Esc must still act on the overlay that is on screen.
            token.global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { _ = perform(event, typing: false, allowMode: false) }
            }
            let claim = KeyClaim(isReady: { NSApp.isActive && window.isKeyWindow }, claim: { [weak window] in
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            })
            token.claim = claim
            claim.start()
        }
        return token
    }

    @MainActor final class Token {
        var local: Any?, global: Any?
        var claim: KeyClaim?
    }

    @MainActor static func remove(_ token: Any?) {
        guard let token else { return }
        if let t = token as? Token {
            t.claim?.cancel()
            if let m = t.local { NSEvent.removeMonitor(m) }
            if let m = t.global { NSEvent.removeMonitor(m) }
        } else { NSEvent.removeMonitor(token) }
    }

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

/// One request to become the active app is not a guarantee: when another app is mid-activation (for example a
/// picker overlay of a screen recorder), it is dropped and the first Return goes to that app. So the claim is
/// repeated until the overlay window is key, then stops.
@MainActor final class KeyClaim {
    private let isReady: () -> Bool
    private let claim: () -> Void
    private let interval: Duration
    private let maxAttempts: Int
    private var task: Task<Void, Never>?
    private(set) var attempts = 0
    private(set) var gaveUp = false

    init(isReady: @escaping () -> Bool, claim: @escaping () -> Void, interval: Duration = .milliseconds(50), maxAttempts: Int = 60) {
        self.isReady = isReady; self.claim = claim; self.interval = interval; self.maxAttempts = maxAttempts
    }

    func start() { task = Task { [weak self] in await self?.run() } }
    func cancel() { task?.cancel(); task = nil }

    /// Claims immediately, then again every `interval` until ready, cancelled, or `maxAttempts` claims were made.
    func run() async {
        while !Task.isCancelled {
            if isReady() { return }
            if attempts >= maxAttempts { gaveUp = true; return }
            attempts += 1
            claim()
            try? await Task.sleep(for: interval)
        }
    }
}
