import Testing
import SwiftUI
import AppKit
import Foundation
import Darwin
@testable import YapcamEditor
import YapcamCore

/// M3 long-timeline measurements. Run: YAPCAM_PERF=1 swift test --filter PerformanceTests (prints PERF lines).
@MainActor @Suite(.serialized) struct PerformanceTests {
    static func residentMB() -> Double {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: 1) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    /// Fixture whose session declares a 60-minute recording (frames are never decoded by these measurements).
    static func longPackage() throws -> URL {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d)
        let url = d.appendingPathComponent("recording/session.json")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"duration_ns\": 2000000000", with: "\"duration_ns\": 3597000000000")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return d
    }

    @Test func sixtyMinuteProjectWithManyClipsAndZooms() async throws {
        guard ProcessInfo.processInfo.environment["YAPCAM_PERF"] != nil else { return }
        let d = try Self.longPackage(); defer { try? FileManager.default.removeItem(at: d) }
        let memStart = Self.residentMB()
        let doc = try EditorDocument(package: d); let m = doc.model
        #expect(m.durationNs == 3_600_000_000_000)
        // Build: 499 splits + 200 zooms through the real edit path (each = core apply + model refresh).
        var t0 = ContinuousClock.now
        for i in 1..<500 { m.seek(toNs: Int64(i) * 7_200_000_000); m.splitAtPlayhead() }
        let splitMs = Self.ms(ContinuousClock.now - t0)
        #expect(m.clips.count == 500, "clips \(m.clips.count) \(m.lastError ?? "")")
        t0 = ContinuousClock.now
        for i in 0..<200 { m.seek(toNs: Int64(i) * 17_000_000_000 + 1_000_000_000); m.addZoomAtPlayhead() }
        let zoomMs = Self.ms(ContinuousClock.now - t0)
        #expect(m.zooms.count == 200, "zooms \(m.zooms.count) \(m.lastError ?? "")")
        print("PERF build: 499 splits \(Int(splitMs)) ms (\(Int(splitMs / 499)) ms/edit), 200 zooms \(Int(zoomMs)) ms (\(Int(zoomMs / 200)) ms/edit)")
        // Single edit latency at this size.
        t0 = ContinuousClock.now
        m.set("canvas.padding", number: 33)
        print("PERF single settings edit: \(String(format: "%.1f", Self.ms(ContinuousClock.now - t0))) ms")
        t0 = ContinuousClock.now; m.undo()
        print("PERF undo: \(String(format: "%.1f", Self.ms(ContinuousClock.now - t0))) ms")

        // Scrub: model seek + core geometry evaluation across the whole hour.
        var samples: [Double] = []
        for i in 0..<2000 {
            let s = ContinuousClock.now
            m.seek(toNs: Int64(i) * 1_800_000_000, precise: false)
            _ = m.project.frameGeometry(atNs: m.playheadNs)
            _ = m.snapped(m.playheadNs + 5_000_000, includePlayhead: false)
            samples.append(Self.ms(ContinuousClock.now - s))
        }
        samples.sort()
        print("PERF scrub step (seek+core frame+snap) median \(String(format: "%.3f", samples[1000])) ms p95 \(String(format: "%.3f", samples[1900])) ms max \(String(format: "%.3f", samples.last!)) ms")

        // Timeline redraw: host the real TimelineView in a window and time layout+draw passes.
        _ = NSApplication.shared
        m.geometry = TimelineGeometry(pixelsPerSecond: 4)
        let host = NSHostingView(rootView: TimelineView(model: m).frame(width: 1400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderBack(nil)
        t0 = ContinuousClock.now
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        let first = Self.ms(ContinuousClock.now - t0)
        var redraws: [Double] = []
        for i in 0..<30 {
            m.seek(toNs: Int64(i) * 100_000_000_000)           // playhead move invalidates the view
            let s = ContinuousClock.now
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep) }
            redraws.append(Self.ms(ContinuousClock.now - s))
        }
        redraws.sort()
        print("PERF timeline first layout \(Int(first)) ms; redraw after playhead move median \(String(format: "%.1f", redraws[15])) ms p95 \(String(format: "%.1f", redraws[28])) ms")
        window.orderOut(nil)
        print("PERF memory: start \(Int(memStart)) MB, after build \(Int(Self.residentMB())) MB")
        // Save/reopen at this size.
        t0 = ContinuousClock.now; m.saveNow()
        let saveMs = Self.ms(ContinuousClock.now - t0)
        t0 = ContinuousClock.now; let reopened = try EditorDocument(package: d)
        print("PERF save \(Int(saveMs)) ms, reopen \(Int(Self.ms(ContinuousClock.now - t0))) ms, clips \(reopened.model.clips.count) zooms \(reopened.model.zooms.count)")
    }
}

@MainActor @Suite(.serialized) struct MemoryAttributionTests {
    @Test func whereDoesMemoryGo() async throws {
        guard ProcessInfo.processInfo.environment["YAPCAM_PERF"] != nil else { return }
        let d = try PerformanceTests.longPackage(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let m = doc.model
        for i in 1..<500 { try doc.project.apply(.split(atNs: Int64(i) * 7_200_000_000)) }    // core only, no editor refresh
        let afterCoreOnly = PerformanceTests.residentMB()
        print("PERF mem core-only 499 splits (no editor refresh): \(Int(afterCoreOnly)) MB")
        for i in 0..<200 { try doc.project.apply(.set(path: "canvas.padding", value: .number(Double(20 + i % 50)))) }
        print("PERF mem after 200 core-only settings edits (journal+undo): \(Int(PerformanceTests.residentMB())) MB")
        for _ in 0..<200 { doc.player.invalidate() }
        try await Task.sleep(for: .seconds(2))
        print("PERF mem after 200 player.invalidate(): \(Int(PerformanceTests.residentMB())) MB")
        for i in 0..<200 { m.set("canvas.padding", number: Double(20 + i % 50)) }            // 200 editor edits on a 500-clip project
        print("PERF mem after 200 more editor edits (refresh each): \(Int(PerformanceTests.residentMB())) MB")
        for _ in 0..<100 { _ = try? doc.project.query("{\"q\":\"project\"}", as: JSONValue.self) }
        print("PERF mem after 100 extra project queries: \(Int(PerformanceTests.residentMB())) MB")
    }
}

@MainActor @Suite(.serialized) struct EditCostBreakdownTests {
    @Test func breakdown() async throws {
        guard ProcessInfo.processInfo.environment["YAPCAM_PERF"] != nil else { return }
        let d = try PerformanceTests.longPackage(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let p = doc.project
        for i in 1..<500 { try p.apply(.split(atNs: Int64(i) * 7_200_000_000)) }
        for i in 0..<200 { try p.apply(.addZoom(ZoomSpec(startNs: Int64(i) * 17_000_000_000 + 1_000_000_000, endNs: Int64(i) * 17_000_000_000 + 3_000_000_000))) }
        func time(_ label: String, n: Int = 20, _ body: () throws -> Void) rethrows {
            var xs: [Double] = []
            for _ in 0..<n { let s = ContinuousClock.now; try body(); xs.append(PerformanceTests.ms(ContinuousClock.now - s)) }
            xs.sort(); print("PERF cost \(label): median \(String(format: "%.2f", xs[n / 2])) ms")
        }
        var v = 20.0
        try time("core apply (set padding)") { v += 1; try p.apply(.set(path: "canvas.padding", value: .number(v))) }
        try time("query clips") { _ = try p.query("{\"q\":\"clips\"}", as: [ClipInfo].self) }
        try time("query zooms") { _ = try p.query("{\"q\":\"zooms\"}", as: JSONValue.self) }
        try time("query project -> JSONValue") { _ = try p.query("{\"q\":\"project\"}", as: JSONValue.self) }
        try time("player.invalidate") { doc.player.invalidate() }
        try time("save (journal clear)") { try p.save() }
    }
}

@MainActor @Suite(.serialized) struct InvalidateGrowthTests {
    @Test func growth() async throws {
        guard ProcessInfo.processInfo.environment["YAPCAM_PERF"] != nil else { return }
        let d = try PerformanceTests.longPackage(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d)
        for i in 1..<500 { try doc.project.apply(.split(atNs: Int64(i) * 7_200_000_000)) }
        print("PERF grow start \(Int(PerformanceTests.residentMB())) MB")
        for batch in 1...4 {
            for _ in 0..<200 { doc.player.invalidate() }
            try await Task.sleep(for: .seconds(3))
            print("PERF grow after \(batch * 200) invalidates (+3 s idle): \(Int(PerformanceTests.residentMB())) MB")
        }
    }
}
