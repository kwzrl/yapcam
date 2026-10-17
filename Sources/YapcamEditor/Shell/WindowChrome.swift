import AppKit
import SwiftUI
import YapcamDesign

/// Gives the hosting editor window the docked look once the view is in it: content under a transparent title bar,
/// opaque dark ground, no title text, and the window buttons centred in the 52-pt title row.
///
/// The lab uses an empty `.unified` toolbar for its 52-pt title bar; on macOS 26 SwiftUI then hides content under
/// the toolbar's trailing area (Undo, Redo, Export vanished). An empty `.unifiedCompact` toolbar (40 pt) keeps the
/// content visible; its window buttons are moved down to the row's centre and kept there across title bar layouts.
struct EditorWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let w = window, w.styleMask.contains(.titled) else { return }
            EditorWindowChrome.apply(to: w)
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                              NSWindow.didExitFullScreenNotification, NSWindow.didEndLiveResizeNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak w] _ in
                    MainActor.assumeIsolated { if let w { EditorWindowChrome.placeButtons(in: w) } }
                }
            }
        }

        override func layout() {
            super.layout()
            if let w = window { EditorWindowChrome.placeButtons(in: w) }
        }
    }

    @MainActor static func apply(to w: NSWindow) {
        w.styleMask.insert(.fullSizeContentView)
        w.titleVisibility = .hidden
        if w.toolbar == nil {
            w.toolbar = NSToolbar(identifier: "yapcam-editor")
            w.toolbarStyle = .unifiedCompact
        }
        w.applyYapChrome()
        placeButtons(in: w)
        // The title bar lays its buttons out again after this pass; place them once more after it.
        DispatchQueue.main.async { placeButtons(in: w) }
    }

    /// Centres the close, minimise and zoom buttons on the title row (`EditorTitleRow.height`).
    @MainActor static func placeButtons(in w: NSWindow) {
        guard !w.styleMask.contains(.fullScreen) else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let b = w.standardWindowButton(kind), let bar = b.superview else { continue }
            let top = EditorTitleRow.height / 2 - b.frame.height / 2
            let y = bar.isFlipped ? top : bar.bounds.height - top - b.frame.height
            guard y >= 0, abs(b.frame.minY - y) > 0.5 else { continue }
            b.setFrameOrigin(NSPoint(x: b.frame.minX, y: y))
        }
    }
}
