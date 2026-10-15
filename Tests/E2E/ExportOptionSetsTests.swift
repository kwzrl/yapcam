import XCTest
import AppKit
import ImageIO
import YapcamCore
@testable import YapcamRender

/// Reference-gap RND-1/2/3: option sets, defaults, paired codec files, GIF options, clipboard FILE export.
@MainActor
final class ExportOptionSetsTests: XCTestCase {
    var work: URL!
    var fixture: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam") }
    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-e2e-opts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: work) }
    func project() throws -> CoreSource {
        let pkg = work.appendingPathComponent("p-\(UUID().uuidString).yapcam"); try FileManager.default.copyItem(at: fixture, to: pkg)
        return CoreSource(try Project.create(package: pkg))
    }
    func probe(_ url: URL, _ entries: String) throws -> String {
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        p.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", entries, "-of", "default=nw=1", url.path]
        p.standardOutput = pipe; try p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }

    func testCatalogsAndDefaults() {
        XCTAssertEqual(ExportSettings.frameRates(for: .mp4), [60, 50, 30, 25, 24, 20, 10])
        XCTAssertEqual(ExportSettings.heights(for: .mp4), [720, 1080, 2160])
        XCTAssertEqual(ExportSettings.frameRates(for: .gif), [50, 30, 25, 20, 15, 10])
        XCTAssertEqual(ExportSettings.heights(for: .gif), [480, 720, 1080])
        XCTAssertEqual(ExportSettings.Compression.allCases.map(\.preferredQuantizer), [14, 24, 30, 42])
        XCTAssertEqual(ExportSettings.Compression.allCases.map(\.supports4K), [true, true, false, false])
        let mp4 = ExportSettings(), gif = ExportSettings(format: .gif)
        XCTAssertEqual([mp4.fps, mp4.outputHeight], [60, 720]); XCTAssertEqual(mp4.codec, .h264); XCTAssertEqual(mp4.compression, .social)
        XCTAssertEqual([gif.fps, gif.outputHeight], [15, 480]); XCTAssertTrue(gif.gifHighQuality); XCTAssertFalse(gif.gifDisableLoop)
        XCTAssertEqual(ExportSettings.codecs(for: .file), [.h264, .hevc, .both]); XCTAssertEqual(ExportSettings.codecs(for: .clipboard), [.h264, .hevc])
    }

    func testDefaultMP4ExportMatchesDefaults() async throws {
        let out = work.appendingPathComponent("d.mp4")
        _ = try await Exporter(project: try project(), settings: ExportSettings(), destination: out).run { _ in }
        let r = try probe(out, "stream=codec_name,height,r_frame_rate")
        XCTAssertTrue(r.contains("codec_name=h264") && r.contains("height=720") && r.contains("r_frame_rate=60/1"), r)
    }

    func testBothCodecsWritePairedFiles() async throws {
        let out = work.appendingPathComponent("b.mp4")
        let s = ExportSettings(codec: .both, outputHeight: 720, fps: 30)
        let dests = s.destinations(for: out)
        XCTAssertEqual(dests.count, 2)
        _ = try await Exporter(project: try project(), settings: s, destination: out).run { _ in }
        let names = try dests.map { try probe($0, "stream=codec_name") }
        XCTAssertTrue(names[0].contains("h264"), names[0]); XCTAssertTrue(names[1].contains("hevc"), names[1])
    }

    func testGIFHighQualityAndLoopOption() async throws {
        func loopCount(_ url: URL) -> Int? {
            let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let props = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
            return (props?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        }
        let looped = work.appendingPathComponent("l.gif"), once = work.appendingPathComponent("o.gif")
        _ = try await Exporter(project: try project(), settings: ExportSettings(format: .gif, rangeStartNs: 0, rangeEndNs: 1_000_000_000), destination: looped).run { _ in }
        _ = try await Exporter(project: try project(), settings: ExportSettings(format: .gif, rangeStartNs: 0, rangeEndNs: 1_000_000_000, gifDisableLoop: true), destination: once).run { _ in }
        let a = try probe(looped, "stream=codec_name,height"), b = try probe(once, "stream=codec_name,height")
        XCTAssertTrue(a.contains("codec_name=gif") && a.contains("height=480"), a); XCTAssertTrue(b.contains("height=480"), b)
        print("QA gif loopCount looped=\(String(describing: loopCount(looped))) once=\(String(describing: loopCount(once)))")
        XCTAssertNotEqual(loopCount(looped), loopCount(once), "disable-loop must change the loop setting")
    }

    func testClipboardExportPutsTheFileOnThePasteboard() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("yapcam-qa-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let dir = work.appendingPathComponent("copied")
        let url = try await ClipboardExport.run(project: try project(), settings: ExportSettings(outputHeight: 720, fps: 30, rangeStartNs: 0, rangeEndNs: 1_000_000_000), directory: dir, pasteboard: board)
        let items = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(items?.first?.standardizedFileURL.resolvingSymlinksInPath(), url.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let history = try ClipboardExport.previousExports(directory: dir)
        XCTAssertTrue(history.contains { $0.lastPathComponent == url.lastPathComponent }, "recent-exports list shows the file")
        XCTAssertThrowsError(try ClipboardExport.copyFile(work.appendingPathComponent("missing.mp4"), to: board))
    }
}
