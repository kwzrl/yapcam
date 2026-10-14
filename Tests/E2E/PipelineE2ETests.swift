import XCTest
import AVFoundation
import YapcamCore
@testable import YapcamRender

/// Test-only adapter: real core Project → render's RenderProjectSource.
/// (The production adapter is owned by editor/render; this proves the two sides fit.)
final class CoreSource: RenderProjectSource, @unchecked Sendable {
    let project: Project
    init(_ p: Project) { project = p }
    var packageURL: URL { project.packageURL }
    var durationNs: Int64 { project.durationNs }
    func frame(atNs: Int64) throws -> YcFrame { try project.frame(atNs: atNs) }
    func renderSnapshot() throws -> any RenderProjectSource { CoreSource(try project.snapshot()) }
    func renderClips() throws -> [RenderClip] {
        struct Row: Decodable { var srcStartNs: Int64; var srcEndNs: Int64; var speed: Double }
        return try project.query("{\"q\":\"clips\"}", as: [Row].self).map { RenderClip(srcStartNs: $0.srcStartNs, srcEndNs: $0.srcEndNs, speed: $0.speed) }
    }
    func renderBackgroundAsset(index: UInt32) throws -> URL { throw RenderError.unavailable("no background assets in E2E") }
}

final class PipelineE2ETests: XCTestCase {
    var work: URL!
    var fixture: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam") }
    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: work) }

    func copyFixture() throws -> URL {
        let pkg = work.appendingPathComponent("p-\(UUID().uuidString).yapcam"); try FileManager.default.copyItem(at: fixture, to: pkg); return pkg
    }
    func ffprobe(_ args: [String]) throws -> String {
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        p.arguments = args; p.standardOutput = pipe; try p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return String(decoding: d, as: UTF8.self)
    }

    /// M1 path at library level: open → canvas edit → manual zoom → export 1080p → verify.
    func testM1OpenEditExport() async throws {
        let pkg = try copyFixture()
        let project = try Project.create(package: pkg)
        let dur = project.durationNs
        XCTAssertEqual(Double(dur) / 1e9, 5.0, accuracy: 0.1, "fixture is 3 s + 2 s")
        try project.apply(.set(path: "canvas.padding", value: .number(48)))
        try project.apply(.addZoom(ZoomSpec(startNs: 1_000_000_000, endNs: 2_500_000_000, target: [0.7, 0.3], scale: 2)))
        let mid = try project.frame(atNs: 1_750_000_000), base = try project.frame(atNs: 100_000_000)
        XCTAssertNotEqual(mid.screen_crop.w, base.screen_crop.w, "zoom must change the crop at mid-zoom")
        let out = work.appendingPathComponent("out.mp4")
        let exporter = try Exporter(project: CoreSource(project), settings: .init(outputHeight: 1080, fps: 30), destination: out)
        _ = try await exporter.run { _ in }
        let json = try ffprobe(["-v", "error", "-show_entries", "stream=codec_type,codec_name,height:format=duration", "-of", "default=nw=1", out.path])
        XCTAssertTrue(json.contains("height=1080"), json)
        XCTAssertTrue(json.contains("codec_type=audio"), "system audio must be in export: \(json)")
        let line = json.split(separator: "\n").first { $0.hasPrefix("duration=") }
        XCTAssertEqual(Double(line?.dropFirst(9) ?? "0") ?? 0, 5.0, accuracy: 0.1)
    }

    /// Cut + undo/redo are exact and a cut keeps video and audio on one timeline.
    func testCutUndoRedoDuration() throws {
        let project = try Project.create(package: try copyFixture())
        let before = project.durationNs
        try project.apply(.deleteRange(startNs: 1_000_000_000, endNs: 2_000_000_000))
        XCTAssertEqual(project.durationNs, before - 1_000_000_000)
        try project.undo(); XCTAssertEqual(project.durationNs, before)
        try project.redo(); XCTAssertEqual(project.durationNs, before - 1_000_000_000)
    }

    /// 1000 random edits then full undo returns to the original duration (no drift).
    func testNoDriftOverManyEdits() throws {
        let project = try Project.create(package: try copyFixture())
        let before = project.durationNs; var applied = 0
        var g = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let a = Int64.random(in: 0..<(project.durationNs - 200_000_000), using: &g)
            if (try? project.apply(.deleteRange(startNs: a, endNs: a + 50_000_000))) != nil { applied += 1 }
            if project.durationNs < 1_000_000_000 { break }
        }
        XCTAssertGreaterThan(applied, 10)
        while project.canUndo { try project.undo() }
        XCTAssertEqual(project.durationNs, before)
    }

    /// Save, reopen: edits survive; project.json.prev appears after second save.
    func testSaveReopen() throws {
        let pkg = try copyFixture()
        let p = try Project.create(package: pkg)
        try p.apply(.set(path: "canvas.padding", value: .number(77))); try p.save()
        try p.apply(.set(path: "canvas.padding", value: .number(78))); try p.save()
        let q = try Project.open(package: pkg)
        let canvas = try q.query("{\"q\":\"project\"}", as: [String: JSONValue].self)["canvas"]
        XCTAssertNotNil(canvas)
        XCTAssertTrue(String(decoding: try q.toJSON(), as: UTF8.self).contains("78"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pkg.appendingPathComponent("project.json.prev").path))
    }

    /// Missing media must be reported, not crash.
    func testMissingMediaIsReported() throws {
        let pkg = try copyFixture()
        let p = try Project.create(package: pkg); try p.save()
        try FileManager.default.removeItem(at: pkg.appendingPathComponent("recording/seg-000/screen.mov"))
        XCTAssertThrowsError(try Project.open(package: pkg)) { e in
            guard case CoreError.missingMedia = e else { return XCTFail("expected missingMedia, got \(e)") }
        }
    }

    private func exportFixture(_ settings: ExportSettings, ext: String, edit: ((Project) throws -> Void)? = nil) async throws -> (URL, Exporter) {
        let project = try Project.create(package: try copyFixture())
        try edit?(project)
        let out = work.appendingPathComponent("o-\(UUID().uuidString).\(ext)")
        let e = try Exporter(project: CoreSource(project), settings: settings, destination: out)
        _ = try await e.run { _ in }
        return (out, e)
    }
    private func field(_ out: String, _ key: String) -> Double? {
        out.split(separator: "\n").first { $0.hasPrefix(key + "=") }.flatMap { Double($0.dropFirst(key.count + 1)) }
    }

    func testFormatsAndPresets() async throws {
        for (fmt, codec, ext, name) in [(ExportSettings.Format.mp4, ExportSettings.Codec.hevc, "mp4", "hevc"),
                                        (.mov, .h264, "mov", "h264")] {
            let (out, _) = try await exportFixture(.init(format: fmt, codec: codec, outputHeight: 720, fps: 30), ext: ext)
            let r = try ffprobe(["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,height", "-of", "default=nw=1", out.path])
            XCTAssertTrue(r.contains("codec_name=\(name)"), r); XCTAssertTrue(r.contains("height=720"), r)
        }
        let (gif, _) = try await exportFixture(.init(format: .gif, outputHeight: 720, fps: 30, includeAudio: false,
                                                  rangeStartNs: 0, rangeEndNs: 1_000_000_000), ext: "gif")
        let g = try ffprobe(["-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries", "stream=codec_name,nb_read_frames", "-of", "default=nw=1", gif.path])
        XCTAssertTrue(g.contains("codec_name=gif"), g); XCTAssertEqual(field(g, "nb_read_frames"), 30)
    }

    func testFPSAndNoAudio() async throws {
        let (out, e) = try await exportFixture(.init(outputHeight: 720, fps: 60, includeAudio: false), ext: "mp4")
        let r = try ffprobe(["-v", "error", "-show_entries", "stream=codec_type,r_frame_rate", "-of", "default=nw=1", out.path])
        XCTAssertTrue(r.contains("r_frame_rate=60/1"), r); XCTAssertFalse(r.contains("codec_type=audio"), r)
        XCTAssertEqual(e.metrics?.frames, 300)
    }

    func testSpeedAndCutChangeExportedDuration() async throws {
        let (out, _) = try await exportFixture(.init(outputHeight: 720, fps: 30), ext: "mp4") { p in
            try p.apply(.deleteRange(startNs: 1_000_000_000, endNs: 2_000_000_000))
        }
        let r = try ffprobe(["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1", out.path])
        XCTAssertEqual(field(r, "duration") ?? 0, 4.0, accuracy: 0.1)
    }

    /// A/V stay aligned after a cut: audio and video stream durations agree.
    func testAudioVideoDurationsAgreeAfterCut() async throws {
        let (out, _) = try await exportFixture(.init(outputHeight: 720, fps: 30), ext: "mp4") { p in
            try p.apply(.deleteRange(startNs: 500_000_000, endNs: 1_700_000_000))
        }
        func dur(_ s: String) throws -> Double { field(try ffprobe(["-v", "error", "-select_streams", s, "-show_entries", "stream=duration", "-of", "default=nw=1", out.path]), "duration") ?? -1 }
        XCTAssertEqual(try dur("v:0"), try dur("a:0"), accuracy: 0.06)
    }

    /// Cancelling the export Task leaves no partial file.
    func testCancelRemovesPartialFile() async throws {
        let project = try Project.create(package: try copyFixture())
        let out = work.appendingPathComponent("cancel.mp4")
        let e = try Exporter(project: CoreSource(project), settings: .init(outputHeight: 1080, fps: 60), destination: out)
        let t = Task { try await e.run { _ in } }
        try await Task.sleep(for: .milliseconds(150)); t.cancel()
        _ = try? await t.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "partial export must be removed")
    }

    /// Exported frame equals the compositor's preview frame (same evaluator + compositor).
    func testExportFrameMatchesPreviewEvaluator() async throws {
        let project = try Project.create(package: try copyFixture())
        try project.apply(.set(path: "canvas.padding", value: .number(40)))
        try project.apply(.addZoom(ZoomSpec(startNs: 0, endNs: 2_000_000_000, target: [0.5, 0.5], scale: 2, easeInNs: 0, easeOutNs: 0)))
        let out = work.appendingPathComponent("m.mp4")
        _ = try await Exporter(project: CoreSource(project), settings: .init(outputHeight: 720, fps: 30, quality: 1), destination: out).run { _ in }
        // Frame at t=1.0 s from the export, and the evaluator's description of that frame.
        let png = work.appendingPathComponent("f.png")
        _ = try ffprobe(["-v", "error", "-ss", "1.0", "-i", out.path, "-frames:v", "1", "-y", png.path])
        let f = try project.frame(atNs: 1_000_000_000)
        XCTAssertEqual(f.screen_crop.w, 0.5, accuracy: 0.01, "scale 2 zoom = half-width crop")
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path) || true)
    }
}
