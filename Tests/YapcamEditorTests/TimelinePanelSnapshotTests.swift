import AppKit
import SwiftUI
import Testing
import YapcamCore
@testable import YapcamEditor

/// Visual check of the docked bottom panel, both modes, 2x dark:
/// YAPCAM_TIMELINE_DIR=<dir outside the repo> swift test --filter TimelinePanelSnapshotTests
@MainActor @Suite(.serialized) struct TimelinePanelSnapshotTests {
    @Test func renderBottomPanel() async throws {
        guard let d = ProcessInfo.processInfo.environment["YAPCAM_TIMELINE_DIR"] else { return }
        let dir = URL(fileURLWithPath: d); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = EditorModel(project: FakeProject(durationNs: 24_000_000_000), player: FakePlayer())
        let words = ["Hello", "um", "and", "welcome", "to", "the", "uh", "demo.", "Today", "we", "look", "at", "the", "new", "editor",
                     "and", "how", "the", "agent", "edits", "it", "live."]
        let json = "{\"schema_version\":1,\"engine\":\"x\",\"locale\":\"en\",\"words\":[" + words.enumerated().map {
            let start = Int64($0) * 600_000_000 + ($0 >= 8 ? 1_500_000_000 : 0)
            return "{\"text\":\"\($1)\",\"src_start_ns\":\(start),\"src_end_ns\":\(start + 450_000_000)}" }.joined(separator: ",") + "]}"
        m.captionSource = { Data(json.utf8) }
        m.generateCaptions(); await m.waitForCaptions()
        m.seek(toNs: 2_000_000_000); m.addZoomAtPlayhead()
        m.seek(toNs: 9_000_000_000); m.addZoomAtPlayhead()
        m.seek(toNs: 6_000_000_000); m.splitAtPlayhead(); m.seek(toNs: 14_000_000_000); m.splitAtPlayhead()
        m.seek(toNs: 3_000_000_000); m.addLayoutAtPlayhead()
        m.seek(toNs: 11_000_000_000); m.addHighlightAtPlayhead(kind: .blur)
        m.seek(toNs: 16_000_000_000); m.addText(.annotation, text: "Click Deploy")
        m.seek(toNs: 7_340_000_000)
        if let z = m.zooms.first { m.selection = .zoom(z.id) }
        let size = CGSize(width: 1180, height: BottomPanelView.preferredHeight(model: m, windowHeight: 1000))
        try await shoot("timeline", dir, size) { BottomPanelView(model: m) }
        m.bottomPanel = .transcript
        try await shoot("transcript", dir, size) { BottomPanelView(model: m) }
        let empty = EditorModel(project: FakeProject(durationNs: 10_000_000_000), player: FakePlayer())
        empty.bottomPanel = .transcript
        try await shoot("transcript-empty", dir, CGSize(width: 1180, height: 260)) { BottomPanelView(model: empty) }
        let narrow = EditorModel(project: FakeProject(durationNs: 10_000_000_000), player: FakePlayer())
        try await shoot("narrow", dir, CGSize(width: 760, height: 260)) { BottomPanelView(model: narrow) }
    }

    private func shoot<V: View>(_ name: String, _ dir: URL, _ size: CGSize, _ make: () -> V) async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: make().frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host; window.orderBack(nil); defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(600)); host.layoutSubtreeIfNeeded()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appending(path: "\(name).png"))
    }
}
