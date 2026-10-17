import AppKit
import SwiftUI

/// Speaker notes and the prompter: one floating, capture-excluded panel (opens from the gear menu, the Recording menu
/// and the global shortcut).
@MainActor final class NotesWindow {
    static let shared = NotesWindow()
    private var window: NSPanel?

    var isVisible: Bool { window?.isVisible == true }
    func toggle() { if window?.isVisible == true { window?.orderOut(nil) } else { show() } }

    func show() {
        if window == nil {
            let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 360),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
            p.title = "Speaker Notes"
            p.titlebarAppearsTransparent = true; p.titleVisibility = .hidden
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: SpeakerNotesView().environmentObject(RecordingController.shared))
            p.center()
            RecordingController.shared.engine.registerExcluded(p)
            window = p
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() { window?.orderOut(nil) }

    /// ⌘⌥. : play or pause from anywhere; the panel opens first when it is hidden.
    func togglePlay() {
        if !isVisible { show() }
        PrompterModel.shared.togglePlay()
    }
}
