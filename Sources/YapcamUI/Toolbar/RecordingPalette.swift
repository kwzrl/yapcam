import AppKit
import SwiftUI
import YapcamDesign

/// ⌘K while a take runs: pause, finish, restart, cancel, add a marker, show the speaker notes.
enum RecordingPalette {
    struct Command: Equatable { let id: String; let title: String }

    static func commands(phase: RecordingPhase, filter: String = "") -> [Command] {
        guard phase == .recording || phase == .paused else { return [] }
        var all = [Command(id: "pause", title: phase == .paused ? "Resume recording" : "Pause recording"),
                   Command(id: "finish", title: "Finish recording"),
                   Command(id: "restart", title: "Restart recording…"),
                   Command(id: "cancel", title: "Cancel recording…"),
                   Command(id: "marker", title: "Add marker"),
                   Command(id: "notes", title: "Show speaker notes")]
        if phase == .paused { all.removeAll { $0.id == "marker" } }     // markers are for a running take
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return f.isEmpty ? all : all.filter { $0.title.lowercased().contains(f) }
    }

    @MainActor static func run(_ id: String, on rec: RecordingController = .shared) {
        switch id {
        case "pause": rec.togglePause()
        case "finish": rec.stop()
        case "restart": rec.confirmRestart()
        case "cancel": rec.confirmCancel()
        case "marker": rec.addMarker()
        case "notes": NotesWindow.shared.show()
        default: break
        }
    }
}

@MainActor final class RecordingPaletteWindow {
    static let shared = RecordingPaletteWindow()
    private var panel: NSPanel?

    func show() {
        guard RecordingPalette.commands(phase: RecordingController.shared.phase).isEmpty == false else { return }
        let p = panel ?? NSPanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 280), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        p.title = "Commands"; p.level = .floating; p.isReleasedWhenClosed = false; p.hidesOnDeactivate = false
        p.contentView = NSHostingView(rootView: PaletteView(close: { [weak self] in self?.panel?.orderOut(nil) }).environmentObject(RecordingController.shared))
        RecordingController.shared.engine.registerExcluded(p)
        p.center(); NSApp.activate(); p.makeKeyAndOrderFront(nil)
        panel = p
    }
}

private struct PaletteView: View {
    let close: () -> Void
    @EnvironmentObject var rec: RecordingController
    @State private var filter = ""
    var body: some View {
        let items = RecordingPalette.commands(phase: rec.phase, filter: filter)
        VStack(spacing: 0) {
            TextField("Type a command", text: $filter).textFieldStyle(.plain).padding(12)
                .onSubmit { if let first = items.first { RecordingPalette.run(first.id); close() } }
            Hairline()
            ForEach(items, id: \.id) { c in
                Button { RecordingPalette.run(c.id); close() } label: {
                    Text(c.title).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 7)
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .background(Yap.ground).frame(width: 360, height: 280)
        .onExitCommand(perform: close)
    }
}
