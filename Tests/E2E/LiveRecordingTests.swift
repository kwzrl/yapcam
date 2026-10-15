import XCTest
import Metal
import AVFoundation
import YapcamCore
@testable import YapcamRender

/// Tests on a REAL recording made by the signed app (e.g. `--capture-selftest N`).
/// Set YAPCAM_LIVE_PACKAGE=/path/to/Recording.yapcam ; the package is copied first, never modified.
final class LiveRecordingTests: XCTestCase {
    var work: URL!
    var pkg: URL!
    override func setUpWithError() throws {
        guard let p = ProcessInfo.processInfo.environment["YAPCAM_LIVE_PACKAGE"] else { throw XCTSkip("YAPCAM_LIVE_PACKAGE not set") }
        work = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-e2e-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        pkg = work.appendingPathComponent("live.yapcam")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: p), to: pkg)
    }
    override func tearDownWithError() throws { if let work { try? FileManager.default.removeItem(at: work) } }

    func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = pipe; p.standardError = Pipe(); try p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return String(decoding: d, as: UTF8.self)
    }
    func num(_ s: String, _ k: String) -> Double? { s.split(separator: "\n").first { $0.hasPrefix(k + "=") }.flatMap { Double($0.dropFirst(k.count + 1)) } }

    func testOpenRealRecording() throws {
        let p = try Project.create(package: pkg)
        let sessionNs = p.session.segments.reduce(Int64(0)) { $0 + Int64($1.durationNs) }
        XCTAssertEqual(Double(p.durationNs), Double(sessionNs), accuracy: 50_000_000, "timeline = recorded duration")
        XCTAssertEqual(p.session.tracks.screen.pixelSize.count, 2)
        let clicks = try p.clicks()
        print("LIVE open: duration_s=\(Double(p.durationNs)/1e9) segments=\(p.session.segments.count) clicks=\(clicks.count)")
    }

    func testEditExportRealRecording() async throws {
        let p = try Project.create(package: pkg)
        let d = p.durationNs
        try p.apply(.set(path: "canvas.padding", value: .number(48)))
        try p.apply(.addZoom(ZoomSpec(startNs: d / 4, endNs: d / 4 + 2_000_000_000, target: [0.3, 0.3], scale: 2)))
        let cutStart = d / 2, cutEnd = min(d / 2 + 1_000_000_000, d - 100_000_000)
        try p.apply(.deleteRange(startNs: cutStart, endNs: cutEnd))
        let expected = Double(p.durationNs) / 1e9
        try p.apply(.set(path: "canvas.padding", value: .number(60)))
        try p.undo(); try p.redo()
        try p.save()
        let out = work.appendingPathComponent("live.mp4")
        let e = try Exporter(project: CoreSource(p), settings: .init(outputHeight: 1080, fps: 30), destination: out)
        _ = try await e.run { _ in }
        let r = try run("/opt/homebrew/bin/ffprobe", ["-v", "error", "-show_entries", "stream=codec_type,height:format=duration", "-of", "default=nw=1", out.path])
        XCTAssertEqual(num(r, "duration") ?? 0, expected, accuracy: 0.15, r)
        XCTAssertTrue(r.contains("height=1080"), r)
        XCTAssertTrue(r.contains("codec_type=audio"), "system audio must reach the export: \(r)")
        print("LIVE export: expected_s=\(expected) probe=\(r.replacingOccurrences(of: "\n", with: " "))  realtime=\(e.metrics?.realtimeMultiplier ?? 0)")
        // reopen after save: edits persisted
        let q = try Project.open(package: pkg)
        XCTAssertEqual(Double(q.durationNs) / 1e9, expected, accuracy: 0.01)
    }

    /// Exported frame vs the compositor's own frame (the preview path): mean abs luma diff.
    func testExportMatchesPreviewFrame() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let p = try Project.create(package: pkg)
        try p.apply(.set(path: "canvas.padding", value: .number(48)))
        let src = CoreSource(p)
        let out = work.appendingPathComponent("m.mp4")
        _ = try await Exporter(project: src, settings: .init(outputHeight: 720, fps: 30, quality: 1, includeAudio: false), destination: out).run { _ in }
        let t: Int64 = min(p.durationNs / 2, 2_000_000_000)
        let f = try p.frame(atNs: t)
        let w = try ExportSettings(outputHeight: 720).outputWidth(canvasWidth: f.canvas_w, canvasHeight: f.canvas_h), h = 720
        let comp = try FrameCompositor(device: device, project: src)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))
        let cb = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        try comp.encode(f, to: tex, in: cb); cb.commit(); await cb.completed()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // exported frame at t as raw gray
        let raw = work.appendingPathComponent("f.gray")
        _ = try run("/opt/homebrew/bin/ffmpeg", ["-v", "error", "-ss", String(Double(t) / 1e9), "-i", out.path, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "gray", "-y", raw.path])
        let g = try Data(contentsOf: raw); XCTAssertEqual(g.count, w * h)
        var sum = 0.0
        for i in 0..<(w * h) {
            let b = Double(px[i*4]), gg = Double(px[i*4+1]), r = Double(px[i*4+2])
            let y = 0.2126 * r + 0.7152 * gg + 0.0722 * b   // sRGB-encoded bytes -> gamma luma
            sum += abs(y - Double(g[i]))
        }
        let mad = sum / Double(w * h)
        print("LIVE preview-vs-export mean abs luma diff = \(mad) / 255 at t=\(Double(t)/1e9)s")
        XCTAssertLessThan(mad, 6.0)
    }

    /// Isolates a decode failure at the end of real recordings: export only the last 15 s in 3 variants.
    func testTailExportDiagnostics() async throws {
        let p = try Project.create(package: pkg)
        let d = p.durationNs, start = d - 15_000_000_000
        var report: [String] = []
        for (name, end, audio) in [("full-tail+audio", d, true), ("tail-100ms+audio", d - 100_000_000, true), ("full-tail,no-audio", d, false)] {
            let out = work.appendingPathComponent("tail-\(name.count)-\(audio).mp4")
            do {
                _ = try await Exporter(project: CoreSource(p), settings: .init(outputHeight: 720, fps: 30, includeAudio: audio, rangeStartNs: start, rangeEndNs: end), destination: out).run { _ in }
                report.append("\(name): OK")
            } catch { report.append("\(name): FAIL \(error)") }
        }
        print("LIVE tail diagnostics: " + report.joined(separator: " | "))
    }

    /// Real clicks (scripted by --drive-input-selftest at a fixed point) -> auto zoom -> frame + export.
    func testAutoZoomFromRealClicks() async throws {
        let p = try Project.create(package: pkg)
        let clicks = try p.clicks()
        print("LIVE auto-zoom: clicks=\(clicks.count)")
        try XCTSkipIf(clicks.isEmpty, "recording has no clicks (use --drive-input-selftest)")
        try p.apply(.autoZooms)
        struct Z: Decodable { var tlStartNs: Int64; var tlEndNs: Int64; var mode: String; var target: [Double]; var scale: Double }
        let zooms = try p.query("{\"q\":\"zooms\"}", as: [Z].self)
        print("LIVE auto-zoom: zooms=\(zooms.map { "[\(Double($0.tlStartNs)/1e9)-\(Double($0.tlEndNs)/1e9)s \($0.mode) t=\($0.target) x\($0.scale)]" })")
        XCTAssertGreaterThanOrEqual(zooms.count, 1)
        let first = clicks[0].tlNs
        let z = try XCTUnwrap(zooms.first { $0.tlStartNs <= first && $0.tlEndNs >= first }, "a zoom must cover the first click")
        XCTAssertLessThanOrEqual(z.tlStartNs, first, "zoom starts at or before the click")
        XCTAssertEqual(z.mode, "auto")
        // Target should be near the click (display points -> normalized).
        let sx = Double(p.session.tracks.screen.pixelSize[0]) / p.session.source.scale, sy = Double(p.session.tracks.screen.pixelSize[1]) / p.session.source.scale
        let ev = try String(contentsOf: pkg.appendingPathComponent("recording/seg-000/events.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let down = try XCTUnwrap(ev.first { ($0["type"] as? String) == "down" })
        let nx = (down["x"] as! Double) / sx, ny = (down["y"] as! Double) / sy
        print("LIVE auto-zoom: first click at normalized (\(nx), \(ny)), zoom target \(z.target)")
        XCTAssertEqual(z.target[0], nx, accuracy: 0.08); XCTAssertEqual(z.target[1], ny, accuracy: 0.08)
        let mid = (max(z.tlStartNs, first) + z.tlEndNs) / 2
        let fz = try p.frame(atNs: mid), f0 = try p.frame(atNs: 0)
        XCTAssertLessThan(fz.screen_crop.w, f0.screen_crop.w, "mid-zoom crop must be narrower than full frame")
        let out = work.appendingPathComponent("az.mp4")
        _ = try await Exporter(project: CoreSource(p), settings: .init(outputHeight: 720, fps: 30), destination: out).run { _ in }
        let r = try run("/opt/homebrew/bin/ffprobe", ["-v", "error", "-show_entries", "stream=codec_type:format=duration", "-of", "default=nw=1", out.path])
        XCTAssertEqual(num(r, "duration") ?? 0, Double(p.durationNs) / 1e9, accuracy: 0.2, r)
        print("LIVE auto-zoom: export ok \(r.replacingOccurrences(of: "\n", with: " "))")
    }
}
