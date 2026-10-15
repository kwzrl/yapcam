import AppKit
import SwiftUI

/// `Yapcam --snapshot-ui <dir>` renders the app's own windows to PNGs in light and dark
/// appearance and exits. Works without Screen Recording permission (draws our own views).
@MainActor enum UISnapshot {
    static let expectedNames: [String] = {
        var n = ["welcome-to-yapcam", "yapcam-settings", "popover-audio", "popover-mic", "popover-camera",
                 "popover-notes", "teleprompter", "popover-source-display", "popover-source-window", "popover-source-area",
                 "recordings", "area-overlay", "settings-general", "settings-recording", "settings-shortcuts",
                 "settings-storage", "settings-advanced"]
        n += ["idle", "countdown", "recording", "paused"].map { "toolbar-\($0)" }
        return n
    }()

    static func run(into dir: URL) async {
        await render(into: dir)
        NSApp.terminate(nil)
    }

    /// Renders every window in light and dark into `dir` as `<name>-<light|dark>.png`.
    static func render(into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let toolbar = ToolbarPanelController.shared
        toolbar.show()
        SettingsWindow.shared.show()
        OnboardingWindow.shared.show(reason: nil)
        if let screen = NSScreen.main {
            AreaSelector.shared.begin(on: screen, initial: CGRect(x: 300, y: 200, width: 640, height: 360)) { _ in }
        }
        try? await Task.sleep(for: .milliseconds(600))

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for phase in [RecordingPhase.idle, .countdown(3), .recording, .paused] {
                RecordingController.shared.debugSetPhase(phase)
                try? await Task.sleep(for: .milliseconds(400))
                write(toolbar.panel, "toolbar-\(label(phase))-\(name)", dir, dark: name == "dark")
            }
            RecordingController.shared.debugSetPhase(.idle)
            for w in NSApp.windows where w !== toolbar.panel && w.isVisible && !w.title.isEmpty {
                write(w, "\(w.title.replacingOccurrences(of: " ", with: "-").lowercased())-\(name)", dir, dark: name == "dark")
            }
            // Each view is built right before it is written, so per-view state (source mode…) holds.
            for (title, make) in extraViews() { write(make(), "\(title)-\(name)", dir, size: nil, dark: name == "dark") }
        }
        NSApp.appearance = nil
        AreaSelector.shared.cancelForTesting()
    }

    private static func label(_ p: RecordingPhase) -> String {
        switch p { case .idle: "idle"; case .countdown: "countdown"; case .recording: "recording"; case .paused: "paused"; default: "other" }
    }

    private static func host<V: View>(_ v: V, width: CGFloat) -> NSView {
        let h = NSHostingView(rootView: v.environmentObject(AppSettings.shared).environmentObject(PermissionsModel.shared)
            .frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
        h.frame = CGRect(origin: .zero, size: h.fittingSize)
        return h
    }

    private static func extraViews() -> [(String, () -> NSView)] {
        let s = AppSettings.shared
        var out: [(String, () -> NSView)] = []
        for m in SourceMode.allCases {
            out.append(("popover-source-\(m.rawValue)", {
                s.sourceMode = m
                return host(SourcePopover(dismiss: {}), width: m == .window ? 400 : 280)
            }))
        }
        out.append(("popover-audio", { s.sourceMode = .display; return host(SystemAudioPopover(), width: 260) }))
        out.append(("popover-mic", { host(MicrophonePopover(), width: 280) }))
        out.append(("popover-camera", { host(CameraPopover(), width: 280) }))
        out.append(("teleprompter", { host(TeleprompterView(close: {}).environmentObject(RecordingController.shared).frame(height: 240), width: 520) }))
        out.append(("popover-notes", { host(NotesPopover().environmentObject(RecordingController.shared), width: 300) }))
        out.append(("recordings", { host(RecentProjectsView(model: RecentProjectsWindow.shared.model).frame(height: 300), width: 560) }))
        out.append(("settings-general", { host(GeneralSettings().frame(height: 380), width: 520) }))
        out.append(("settings-recording", { host(RecordingSettings().frame(height: 380), width: 520) }))
        out.append(("settings-shortcuts", { host(ShortcutSettings().frame(height: 380), width: 520) }))
        out.append(("settings-storage", { host(StorageSettings().frame(height: 380), width: 520) }))
        out.append(("settings-advanced", { host(AdvancedSettings().frame(height: 380), width: 520) }))
        if let v = AreaSelector.shared.debugContentView { out.append(("area-overlay", { v })) }
        return out
    }

    private static func write(_ window: NSWindow, _ name: String, _ dir: URL, dark: Bool) {
        if let v = window.contentView { write(v, name, dir, size: nil, dark: dark) }
    }

    /// Writes `<name>.png` (1×) and `<name>@2x.png` (2× backing) for a view.
    private static func write(_ view: NSView, _ name: String, _ dir: URL, size: CGSize?, dark: Bool) {
        view.layoutSubtreeIfNeeded()
        for scale in [1, 2] as [CGFloat] {
            let w = max(1, Int(view.bounds.width * scale)), h = max(1, Int(view.bounds.height * scale))
            func makeRep() -> NSBitmapImageRep? {
                let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                r?.size = view.bounds.size
                return r
            }
            guard let out = makeRep() else { continue }
            // Pre-fill the neutral backdrop, then let AppKit draw the view over it.
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: out) {
                NSGraphicsContext.current = ctx
                (dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.85, alpha: 1)).setFill()
                NSRect(origin: .zero, size: view.bounds.size).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            view.cacheDisplay(in: view.bounds, to: out)
            guard let png = out.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: dir.appending(path: "\(name)\(scale == 2 ? "@2x" : "").png"))
        }
    }
}
