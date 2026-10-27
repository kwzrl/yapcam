import Testing
import SwiftUI
import AppKit
import Combine
@testable import YapcamEditor

/// Opt-in timeline smoothness measurement in a real (off-screen) window.
/// YAPCAM_TIMELINE_PERF=1 YAPCAM_TIMELINE_PERF_PKG=<package> (copied first, never written).
@MainActor @Suite(.serialized) struct TimelinePerfTests {
    private func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    private func stats(_ v: [Double]) -> String {
        guard !v.isEmpty else { return "n=0" }
        let s = v.sorted()
        func p(_ q: Double) -> Double { s[min(s.count - 1, Int(Double(s.count - 1) * q))] }
        return String(format: "n=%d median %.1f p95 %.1f max %.1f", s.count, p(0.5), p(0.95), s.last!)
    }
    private func pump(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    @Test func timelineSmoothness() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["YAPCAM_TIMELINE_PERF"] == "1", let path = env["YAPCAM_TIMELINE_PERF_PKG"] else { return }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: work); defer { try? FileManager.default.removeItem(at: work) }
        try? FileManager.default.removeItem(at: work.appendingPathComponent("recording/.capture.lock"))
        _ = NSApplication.shared
        let doc = try EditorDocument(package: work)
        let m = doc.model
        let host = NSHostingView(rootView: EditorView(document: doc))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1440, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderBack(nil)
        defer { doc.player.pause(); window.orderOut(nil) }
        await pump(2.0)
        let dur = m.durationNs
        if env["YAPCAM_TIMELINE_PERF_SAMPLE"] == "1" {
            print("PERF SAMPLE pid \(getpid())")
            for i in 0..<600 { m.playhead.ns = Int64(i % 100) * 100_000_000; host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(5)) }
            return
        }

        // (A) playback: playhead updates as the timeline sees them.
        var ticks: [(t: ContinuousClock.Instant, ns: Int64)] = []
        let sub = m.playhead.$ns.sink { ticks.append((ContinuousClock.now, $0)) }
        m.seek(toNs: 0); await pump(0.5); ticks.removeAll()
        m.togglePlay(); await pump(5.0); m.pause(); sub.cancel()
        let pps = m.geometry.pixelsPerSecond
        var intervals: [Double] = [], jumps: [Double] = []
        let moving = ticks.enumerated().filter { $0.offset > 0 && $0.element.ns != ticks[$0.offset - 1].ns }.map(\.element)
        for i in 1..<max(moving.count, 1) where moving.count > 1 {
            intervals.append(ms(moving[i].t - moving[i - 1].t))
            jumps.append(Double(moving[i].ns - moving[i - 1].ns) / 1e9 * pps)
        }
        print("PERF A play interval ms \(stats(intervals)) >25ms \(intervals.filter { $0 > 25 }.count) | jump px \(stats(jumps)) @\(pps)px/s")

        // (B) scrub: 120 imprecise seeks at 60 Hz, latency until the preview drew that time.
        var requested: [Int64: ContinuousClock.Instant] = [:]
        var latency: [Double] = []
        doc.player.onFrameDrawn = { ns in
            if let t = requested.removeValue(forKey: ns) { latency.append(ms(ContinuousClock.now - t)) }
        }
        let span = min(dur, 18_000_000_000)
        for i in 0..<120 {
            let ns = Int64(i) * span / 120 + 1_000_000
            m.seek(toNs: ns, precise: false)
            requested[min(max(ns, 0), dur)] = ContinuousClock.now
            try? await Task.sleep(for: .microseconds(16_667))
        }
        await pump(1.0)
        doc.player.onFrameDrawn = nil
        print("PERF B scrub latency ms \(stats(latency)) never drawn \(requested.count)/120")

        // (C) scroll/zoom: geometry + scroll change at 60 Hz for 2 s.
        var steps: [Double] = []
        let base = m.geometry.pixelsPerSecond
        for i in 0..<120 {
            let t0 = ContinuousClock.now
            let phase = Double(i) / 120
            m.geometry.pixelsPerSecond = base * (1 + 2 * sin(phase * .pi))
            m.timelineScroller?.scroll(toX: phase * 400)
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            steps.append(ms(ContinuousClock.now - t0))
            try? await Task.sleep(for: .microseconds(16_667))
        }
        print("PERF C scroll/zoom step ms \(stats(steps)) scroller \(m.timelineScroller != nil)")
        // Breakdown: scroll only, zoom only, playhead only (main-thread layout+display per step).
        func run(_ body: (Int) -> Void) async -> [Double] {
            var out: [Double] = []
            for i in 0..<60 {
                let t0 = ContinuousClock.now
                body(i); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                out.append(ms(ContinuousClock.now - t0)); try? await Task.sleep(for: .microseconds(16_667))
            }
            return out
        }
        let sc = await run { i in m.timelineScroller?.scroll(toX: Double(i) * 5) }
        let zo = await run { i in m.geometry.pixelsPerSecond = base * (1 + Double(i) / 30) }
        m.geometry.pixelsPerSecond = base
        let ph = await run { i in m.seek(toNs: Int64(i) * 100_000_000, precise: false) }
        let phOnly = await run { i in m.playhead.ns = Int64(i) * 100_000_000 }
        var seekOnly: [Double] = []
        for i in 0..<60 { let t0 = ContinuousClock.now; doc.player.seek(toNs: Int64(i) * 100_000_000, precise: false); seekOnly.append(ms(ContinuousClock.now - t0)); try? await Task.sleep(for: .microseconds(16_667)) }
        print("PERF C'' playhead.ns-only \(stats(phOnly)) | player.seek call only \(stats(seekOnly))")
        print("PERF C' scroll-only \(stats(sc)) | zoom-only \(stats(zo)) | playhead-only \(stats(ph))")
    }
}
