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
        m.seek(toNs: 20_000_000_000); m.addLayoutAtPlayhead(mode: "overlay")
        m.seek(toNs: 5_000_000_000); m.addCursorHideAtPlayhead()
        m.seek(toNs: 3_000_000_000); m.addZoomAtPlayhead()
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

@MainActor @Suite struct OverlaySnapshotTests {
    @Test func renderOverlayInspector() throws {
        guard let dir = ProcessInfo.processInfo.environment["YAPCAM_SNAPSHOT_DIR"] else { return }
        let m = EditorModel(project: FakeProject(durationNs: 20_000_000_000), player: FakePlayer())
        m.addHighlightAtPlayhead(kind: .highlight)
        m.set("canvas.animation.entrance", string: "fade")
        _ = NSApplication.shared
        let host = NSHostingView(rootView: InspectorView(model: m, initialTab: .overlays).frame(width: 300, height: 700).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderBack(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4)); host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appending(path: "overlays-inspector.png"))
        window.orderOut(nil)
    }
}
