import Testing
import SwiftUI
import AppKit
@testable import YapcamEditor

@MainActor @Suite struct SnapshotTests {
    /// Renders the editor in light and dark into $YAPCAM_SNAPSHOT_DIR (skipped when unset).
    @Test func renderEditorLightAndDark() throws {
        guard let dir = ProcessInfo.processInfo.environment["YAPCAM_SNAPSHOT_DIR"] else { return }
        let p = FakeProject(durationNs: 30_000_000_000), pl = FakePlayer()
        let m = EditorModel(project: p, player: pl)
        m.geometry = TimelineGeometry(pixelsPerSecond: 40)
        m.seek(toNs: 8_000_000_000); m.splitAtPlayhead()
        m.seek(toNs: 3_000_000_000); m.addZoomAtPlayhead()
        m.seek(toNs: 15_000_000_000); m.addZoomAtPlayhead()
        m.seek(toNs: 12_000_000_000)
        m.selection = .clip(m.clips[1].id)
        let export = ExportModel(engine: FakeExporter())
        for scheme in [ColorScheme.light, .dark] {
            let view = EditorContent(model: m, export: export, title: "Demo") {
                LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .frame(width: 1100, height: 700)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            _ = NSApplication.shared
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            window.contentView = host
            window.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { Issue.record("no rep"); return }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { Issue.record("png"); return }
            window.orderOut(nil)
            try png.write(to: URL(fileURLWithPath: dir).appending(path: "editor-\(scheme == .light ? "light" : "dark").png"))
        }
    }
}
