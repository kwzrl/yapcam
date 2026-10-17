import Testing
import SwiftUI
import AppKit
import YapcamCore
@testable import YapcamEditor

/// Visual review snapshots (2x, light + dark, 1280×800) with identical file names before/after a polish pass:
/// YAPCAM_POLISH_DIR=<dir outside the repo> swift test --filter PolishSnapshotTests
@MainActor @Suite(.serialized) struct PolishSnapshotTests {
    static let size = CGSize(width: 1280, height: 800)

    /// Renders any view in a real window at 2x into `<dir>/<name>-<light|dark>.png`; returns the hosting view for assertions.
    @discardableResult
    static func shoot<V: View>(_ name: String, in dir: URL, size: CGSize = PolishSnapshotTests.size, _ make: () -> V) async throws -> [NSView] {
        _ = NSApplication.shared
        var hosts: [NSView] = []
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: make().frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            window.contentView = host; window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(600)); host.layoutSubtreeIfNeeded()
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: dir.appending(path: "\(name)-\(scheme == .light ? "light" : "dark").png"))
            hosts.append(host); window.orderOut(nil)
        }
        return hosts
    }

    @Test func renderPolishSnapshots() async throws {
        guard let d = ProcessInfo.processInfo.environment["YAPCAM_POLISH_DIR"] else { return }
        let dir = URL(fileURLWithPath: d); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("polish-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: work); defer { try? FileManager.default.removeItem(at: work) }
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let doc = try EditorDocument(package: work, presets: iso.store); defer { doc.model.close() }
        let m = doc.model, title = "Product demo"
        let source = ProjectRenderSource(doc.project)
        let preview = {
            let png = (try? FrameSnapshot.png(source: source, atNs: m.playheadNs)) ?? Data()
            return Image(nsImage: NSImage(data: png) ?? NSImage()).resizable().aspectRatio(contentMode: .fit)
        }
        func window(_ section: InspectorSection) -> some View {
            EditorContent(model: m, export: ExportModel(engine: FakeExporter()), title: title, initialSection: section) { preview() }
        }

        // 0) empty / fresh project
        let empty = EditorModel(project: FakeProject(durationNs: 0), player: FakePlayer())
        try await Self.shoot("01-empty-project", in: dir) {
            EditorContent(model: empty, export: ExportModel(engine: FakeExporter()), title: "Recording 2026-10-17") { Color.clear }
        }

        // Content: zoom, cut, blur mask, annotation, caption.
        m.seek(toNs: 800_000_000); m.addZoomAtPlayhead()
        m.seek(toNs: 2_000_000_000); m.splitAtPlayhead(); m.seek(toNs: 2_500_000_000); m.splitAtPlayhead()
        m.selection = .none
        m.seek(toNs: 1_000_000_000); m.addHighlightAtPlayhead(kind: .blur)
        m.addText(.annotation, text: "Click the button"); m.addText(.caption, text: "Hello and welcome")
        m.seek(toNs: 1_200_000_000); m.selection = .none
        try await Self.shoot("02-window-loaded", in: dir) { window(.background) }
        m.selection = .zoom(m.zooms[0].id)
        try await Self.shoot("03-window-zoom-selected", in: dir) { window(.animations) }
        m.selection = .none
        // The real fixture has no camera, microphone or keystrokes; sections that need them are rendered from a fake project that
        // does (with a short transcript, a camera layout and a recorded-keys flag), so every 04-* file shows its own section.
        let fake = EditorModel(project: FakeProject(durationNs: 12_000_000_000), player: FakePlayer())
        let words = ["Hello", "um", "and", "welcome", "to", "the", "uh", "demo", "today", "we", "look", "at", "the", "new", "editor"]
        let json = "{\"schema_version\":1,\"engine\":\"x\",\"locale\":\"en\",\"words\":[" + words.enumerated().map {
            "{\"text\":\"\($1)\",\"src_start_ns\":\(Int64($0) * 600_000_000),\"src_end_ns\":\(Int64($0) * 600_000_000 + 450_000_000)}" }.joined(separator: ",") + "]}"
        fake.captionSource = { Data(json.utf8) }
        fake.generateCaptions(); await fake.waitForCaptions()
        fake.seek(toNs: 2_000_000_000); fake.addLayoutAtPlayhead(); fake.seek(toNs: 1_200_000_000)
        let gradient = LinearGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.5), Color(red: 0.5, green: 0.3, blue: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
        for s in InspectorSection.allCases {
            if s.isAvailable(in: m) {
                try await Self.shoot("04-inspector-\(s.rawValue)", in: dir) { window(s) }
            } else {
                try await Self.shoot("04-inspector-\(s.rawValue)", in: dir) {
                    EditorContent(model: fake, export: ExportModel(engine: FakeExporter()), title: title, initialSection: s) { gradient }
                }
            }
        }
        if let h = m.highlights.first { m.selection = .highlight(h.id) }
        try await Self.shoot("05-inspector-blur-mask", in: dir) { window(.extras) }
        m.selection = .none

        // Timeline alone, export sheet in each state, error state.
        try await Self.shoot("06-timeline", in: dir, size: CGSize(width: 1280, height: 260)) { TimelineView(model: m) }
        let exp = ExportModel(engine: FakeExporter())
        try await Self.shoot("07-export-sheet-settings", in: dir, size: CGSize(width: 440, height: 520)) { ExportSheet(export: exp, suggestedName: title) }
        let failing = ExportModel(engine: FakeExporter(failure: NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "The disk is full."])))
        failing.start(to: URL(fileURLWithPath: "/tmp/x.mp4")); await failing.waitUntilFinished()
        try await Self.shoot("08-export-sheet-failed", in: dir, size: CGSize(width: 440, height: 300)) { ExportSheet(export: failing, suggestedName: title) }
        let done = ExportModel(engine: FakeExporter())
        done.revealHandler = { _ in }       // never open Finder from a snapshot run
        done.start(to: URL(fileURLWithPath: "/tmp/x.mp4")); await done.waitUntilFinished()
        try await Self.shoot("09-export-sheet-done", in: dir, size: CGSize(width: 440, height: 240)) { ExportSheet(export: done, suggestedName: title) }
    }
}
