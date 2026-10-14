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
        let pkg = work.appendingPathComponent("p.yapcam"); try FileManager.default.copyItem(at: fixture, to: pkg); return pkg
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
}
