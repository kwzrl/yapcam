import Testing
import SwiftUI
import AppKit
import MetalKit
@testable import YapcamEditor

/// Needs a real window server + GPU. Run with YAPCAM_LIVE_DIR=<dir>; writes a screenshot and prints scrub timings.
@MainActor @Suite(.serialized) struct LiveWindowTests {
    private func findMTK(_ v: NSView) -> MTKView? {
        if let m = v as? MTKView { return m }
        for s in v.subviews { if let m = findMTK(s) { return m } }
        return nil
    }

    @Test func livePreviewRendersAndScrubs() async throws {
        guard let dir = ProcessInfo.processInfo.environment["YAPCAM_LIVE_DIR"] else { return }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: pkg); defer { try? FileManager.default.removeItem(at: pkg) }
        _ = NSApplication.shared
        let doc = try EditorDocument(package: pkg)
        doc.model.seek(toNs: 1_000_000_000); doc.model.addZoomAtPlayhead()
        let host = NSHostingView(rootView: EditorView(document: doc))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .seconds(1))
        let mtk = try #require(findMTK(host), "preview MTKView not found")
        // scrub latency: model seek + MTKView draw (CPU side incl. frame evaluation and GPU submit)
        var samples: [Double] = []
        for i in 0..<120 {
            let t0 = ContinuousClock.now
            doc.model.seek(toNs: Int64(i % 60) * doc.model.durationNs / 60, precise: false)
            mtk.draw()
            let d = ContinuousClock.now - t0
            samples.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        samples.sort()
        print("LIVE scrub ms: median \(samples[60]) p95 \(samples[113]) max \(samples.last!)")
        try await Task.sleep(for: .milliseconds(500))
        doc.model.seek(toNs: 2_000_000_000)
        try await Task.sleep(for: .milliseconds(500))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { Issue.record("no rep"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appending(path: "live-editor.png"))
        doc.player.pause(); window.orderOut(nil)
    }
}
