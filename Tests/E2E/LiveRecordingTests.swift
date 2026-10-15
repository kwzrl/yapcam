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
        try comp.encode(f, to: tex, in: cb); cb.commit(); cb.waitUntilCompleted()
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
}
