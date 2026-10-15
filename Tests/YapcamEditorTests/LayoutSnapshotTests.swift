import Testing
import SwiftUI
import AppKit
@testable import YapcamEditor

/// Renders the editor layout (light + dark) for review: YAPCAM_SNAPSHOT_DIR=<dir> [YAPCAM_REAL_PKG=<package>] swift test --filter LayoutSnapshotTests
@MainActor @Suite(.serialized) struct LayoutSnapshotTests {
    private func render<P: View>(_ name: String, model: EditorModel, section: InspectorSection, title: String, dir: URL, preview: @escaping () -> P) async throws {
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            let view = EditorContent(model: model, export: ExportModel(engine: FakeExporter()), title: title, initialSection: section) { preview() }
                .frame(width: 1440, height: 900)
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            window.contentView = host; window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(700)); host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: dir.appending(path: "layout-\(name)-\(scheme == .light ? "light" : "dark").png"))
            window.orderOut(nil)
        }
    }

    @Test func renderAllStates() async throws {
        guard let d = ProcessInfo.processInfo.environment["YAPCAM_SNAPSHOT_DIR"] else { return }
        let dir = URL(fileURLWithPath: d)
        let gradient = { LinearGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.5), Color(red: 0.5, green: 0.3, blue: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing) }

        // 1) empty state: a fresh project, nothing added.
        let empty = EditorModel(project: FakeProject(durationNs: 12_000_000_000), player: FakePlayer())
        try await render("1-empty", model: empty, section: .background, title: "Recording 2026-10-15", dir: dir, preview: gradient)

        // Real (or fake) project with content for the remaining states.
        var frame: () -> AnyView = { AnyView(gradient()) }
        var model: EditorModel
        var keep: [Any] = []
        if let path = ProcessInfo.processInfo.environment["YAPCAM_REAL_PKG"] {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("lsnap-\(UUID().uuidString).yapcam")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: work); defer { try? FileManager.default.removeItem(at: work) }
            try? FileManager.default.removeItem(at: work.appendingPathComponent("recording/.capture.lock"))
            let doc = try EditorDocument(package: work); keep.append(doc)
            model = doc.model
            model.applyWallpaper(id: "boreal-glow"); await model.waitForWallpaper()
            model.seek(toNs: 1_500_000_000); model.addZoomAtPlayhead()
            model.seek(toNs: 4_000_000_000); model.addText(.annotation, text: "Click the button"); model.addText(.caption, text: "Hello and welcome")
            model.seek(toNs: 5_000_000_000); model.addHighlightAtPlayhead(); model.addBuiltInMusic(builtInMusic[0])
            model.seek(toNs: 2_000_000_000)
            let source = ProjectRenderSource(doc.project)
            frame = {
                let png = (try? FrameSnapshot.png(source: source, atNs: model.playheadNs)) ?? Data()
                return AnyView(Image(nsImage: NSImage(data: png) ?? NSImage()).resizable())
            }
            try await sections(model: model, dir: dir, frame: frame)
            keep.removeAll()
        } else {
            model = EditorModel(project: FakeProject(durationNs: 12_000_000_000), player: FakePlayer())
            model.seek(toNs: 1_500_000_000); model.addZoomAtPlayhead()
            model.seek(toNs: 4_000_000_000); model.addText(.annotation, text: "Click the button"); model.addText(.caption, text: "Hello and welcome")
            model.addHighlightAtPlayhead(); model.addBuiltInMusic(builtInMusic[0]); model.seek(toNs: 2_000_000_000)
            try await sections(model: model, dir: dir, frame: frame)
        }
    }

    private func sections(model: EditorModel, dir: URL, frame: @escaping () -> AnyView) async throws {
        model.selection = .none
        try await render("2-loaded", model: model, section: .background, title: "Recording 2026-10-15", dir: dir, preview: frame)
        model.selection = .zoom(model.zooms[0].id)
        try await render("3-zoom-selected", model: model, section: .animations, title: "Recording 2026-10-15", dir: dir, preview: frame)
        model.selection = .none
        for (i, s) in InspectorSection.allCases.enumerated() {
            try await render("4\(i)-\(s.rawValue)", model: model, section: s, title: "Recording 2026-10-15", dir: dir, preview: frame)
        }
    }
}
