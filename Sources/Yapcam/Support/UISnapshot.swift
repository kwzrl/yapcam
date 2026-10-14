import AppKit
import SwiftUI

/// `Yapcam --snapshot-ui <dir>` renders the app's own windows to PNGs in light and dark
/// appearance and exits. Works without Screen Recording permission (draws our own views).
@MainActor enum UISnapshot {
    static func run(into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let toolbar = ToolbarPanelController.shared
        toolbar.show()
        SettingsWindow.shared.show()
        OnboardingWindow.shared.show(reason: nil)
        try? await Task.sleep(for: .milliseconds(600))

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for phase in [RecordingPhase.idle, .countdown(3), .recording, .paused] {
                RecordingController.shared.debugSetPhase(phase)
                try? await Task.sleep(for: .milliseconds(400))
                write(toolbar.panel, "toolbar-\(label(phase))-\(name)", dir)
            }
            RecordingController.shared.debugSetPhase(.idle)
            for w in NSApp.windows where w !== toolbar.panel && w.isVisible && !w.title.isEmpty {
                write(w, "\(w.title.replacingOccurrences(of: " ", with: "-").lowercased())-\(name)", dir)
            }
            for (title, view) in extraViews() { write(view, "\(title)-\(name)", dir, size: nil) }
        }
        NSApp.terminate(nil)
    }

    private static func label(_ p: RecordingPhase) -> String {
        switch p { case .idle: "idle"; case .countdown: "countdown"; case .recording: "recording"; case .paused: "paused"; default: "other" }
    }

    private static func extraViews() -> [(String, NSView)] { [] }

    private static func write(_ window: NSWindow, _ name: String, _ dir: URL) {
        if let v = window.contentView { write(v, name, dir, size: nil, backdrop: true) }
    }

    private static func write(_ view: NSView, _ name: String, _ dir: URL, size: CGSize?, backdrop: Bool = true) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let img = NSImage(size: view.bounds.size)
        img.addRepresentation(rep)
        // Composite over a neutral backdrop so translucent materials are visible.
        let out = NSImage(size: view.bounds.size)
        out.lockFocus()
        (view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.85, alpha: 1)).setFill()
        NSRect(origin: .zero, size: view.bounds.size).fill()
        img.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appending(path: "\(name).png"))
    }
}
