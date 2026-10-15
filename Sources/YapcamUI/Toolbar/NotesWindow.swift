import AppKit
import SwiftUI

/// Speaker notes live outside the toolbar now: this small window opens from the toolbar's Settings menu
/// and the Recording menu. The teleprompter button inside it shows the notes large while recording.
@MainActor final class NotesWindow {
    static let shared = NotesWindow()
    private var window: NSPanel?

    func toggle() { if window?.isVisible == true { window?.orderOut(nil) } else { show() } }

    func show() {
        if window == nil {
            let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 340),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            p.title = "Speaker Notes"
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.level = .floating
            p.contentView = NSHostingView(rootView: NotesPopover().environmentObject(RecordingController.shared))
            p.center()
            RecordingController.shared.engine.registerExcluded(p)
            window = p
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
