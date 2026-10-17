import XCTest
import YapcamCore
import Metal
import ImageIO
import UniformTypeIdentifiers
import CoreVideo
@testable import YapcamRender

final class AgentVisionRenderTests: XCTestCase {
    func testContentCropUsesRecordingDestinationAndClipsToCanvas() throws {
        let canvas = CGSize(width: 1920, height: 1080)
        let recording = CGRect(x: 240, y: 90, width: 1440, height: 900)
        XCTAssertEqual(try AgentCaptureCrop.content.area(canvas: canvas, recording: recording), recording)
        XCTAssertEqual(try AgentCaptureCrop.frame.area(canvas: canvas, recording: recording), CGRect(origin: .zero, size: canvas))
        XCTAssertEqual(try AgentCaptureCrop.content.area(canvas: canvas, recording: CGRect(x: -100, y: 80, width: 800, height: 600)),
                       CGRect(x: 0, y: 80, width: 700, height: 600))
        XCTAssertThrowsError(try AgentCaptureCrop.content.area(canvas: canvas, recording: .zero))
        XCTAssertThrowsError(try AgentCaptureCrop.content.area(canvas: canvas, recording: recording, recordingVisible: false))
        XCTAssertEqual(try AgentCaptureCrop.frame.area(canvas: canvas, recording: recording, recordingVisible: false), CGRect(origin: .zero, size: canvas))
        XCTAssertThrowsError(try AgentCaptureCrop.content.area(canvas: canvas, recording: CGRect(x: 2000, y: 0, width: 20, height: 20)))
    }

    func testFrameDifferenceDetectsSceneChangeButIgnoresSmallCursorAndAlpha() {
        let black = [UInt8](repeating: 0, count: 64 * 40 * 4)
        let baseline = AgentFrameSignature(rgba: black)
        XCTAssertEqual(baseline.difference(from: baseline), 0)
        var alpha = black
        for i in stride(from: 3, to: alpha.count, by: 4) { alpha[i] = 255 }
        XCTAssertEqual(AgentFrameSignature(rgba: alpha).difference(from: baseline), 0)
        var cursor = black
        for i in 0..<16 { cursor[i] = 255 }
        XCTAssertLessThan(AgentFrameSignature(rgba: cursor).difference(from: baseline), 0.005)
        let changed = AgentFrameSignature(rgba: [UInt8](repeating: 128, count: black.count))
        XCTAssertEqual(changed.difference(from: baseline), 128.0 / 255.0, accuracy: 0.00001)
        XCTAssertGreaterThan(changed.difference(from: baseline), 0.005)
    }

    func testDownsampledSyntheticFramePairFindsSmallUIChange() throws {
        func signature(changed: Bool) throws -> AgentFrameSignature {
            var pixelBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 640, 400, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            bytes.initialize(repeating: 255, count: rowBytes * 400)
            if changed {
                // A dark panel covering just 2.5% of an otherwise white UI.
                for y in 100..<180 { for x in 100..<180 {
                    for channel in 0..<3 { bytes[y * rowBytes + x * 4 + channel] = 32 }
                } }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return try AgentFrameSignature(pixelBuffer: buffer)
        }
        let before = try signature(changed: false), after = try signature(changed: true)
        XCTAssertEqual(before.difference(from: before), 0)
        XCTAssertGreaterThan(after.difference(from: before), 0.005)
        XCTAssertLessThan(after.difference(from: before), 0.04)
    }

    func testContentCapturePreservesCompositedZoomAndRemovesPadding() throws {
        _ = try requireRenderDevice()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-vision-crop-\(UUID()).yapcam")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: root)
        let project = try Project.create(package: root)
        try project.apply(.set(path: "canvas.padding", value: .number(120)))
        try project.apply(.addZoom(.init(startNs: 0, endNs: 2_000_000_000, target: [0.6, 0.4], scale: 2, easeInNs: 0, easeOutNs: 0)))
        let renderer = try AgentFrameRenderer(snapshot: project.snapshot())
        let size = CGSize(width: 4096, height: 4096)
        let full = try renderer.capture(atNs: 1_000_000_000, fitting: size)
        let content = try renderer.capture(atNs: 1_000_000_000, fitting: size, crop: .content)
        let frame = try project.frame(atNs: 1_000_000_000)
        XCTAssertLessThan(frame.screen_crop.w, 1)
        let rect = try AgentCaptureCrop.content.area(canvas: CGSize(width: Int(frame.canvas_w), height: Int(frame.canvas_h)),
                                                     recording: CGRect(x: frame.screen_dest.x, y: frame.screen_dest.y, width: frame.screen_dest.w, height: frame.screen_dest.h)).integral
        let expected = try XCTUnwrap(full.cropping(to: rect))
        XCTAssertLessThan(content.width, full.width)
        XCTAssertEqual(content.width, expected.width)
        XCTAssertEqual(content.height, expected.height)
        XCTAssertEqual(try AgentContactSheet.png(content), try AgentContactSheet.png(expected))
    }

    func testAllSheetLayoutsFitBudgetAndKeepCellsSeparate() throws {
        for count in 1...12 {
            let layout = try AgentSheetLayout(count: count)
            XCTAssertLessThanOrEqual(layout.width, 2576)
            XCTAssertLessThanOrEqual(layout.height, 1456)
            for i in 0..<count {
                let cell = layout.cell(at: i)
                XCTAssertTrue(CGRect(x: 0, y: 0, width: layout.width, height: layout.height).contains(cell))
                for j in 0..<i { XCTAssertFalse(cell.intersects(layout.cell(at: j))) }
            }
        }
        XCTAssertThrowsError(try AgentSheetLayout(count: 0))
        XCTAssertThrowsError(try AgentSheetLayout(count: 13))
        XCTAssertEqual(AgentSheetLayout.timecode(42_100_000_000), "0:42.10")
        XCTAssertEqual(AgentSheetLayout.timecode(3_661_999_999_999), "61:01.99")
    }

    func testPNGIsLosslessFormatAndShrinksNoiseToWireBudget() throws {
        let width = 1920, height = 1080
        var state: UInt64 = 12345
        let pixels = (0..<(width * height * 4)).map { _ -> UInt8 in
            state = state &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: state >> 32)
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let png = try AgentContactSheet.png(image)
        XCTAssertEqual(Array(png.prefix(8)), [137,80,78,71,13,10,26,10])
        XCTAssertLessThanOrEqual(png.base64EncodedString().utf8.count, 1_000_000)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        XCTAssertLessThan(try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil)).width, width)
    }

    func testRawMappingUsesCoreCutsSpeedSegmentOffsetsAndFrozenEdits() throws {
        _ = try requireRenderDevice()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-vision-mapping-\(UUID()).yapcam")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: root)
        let manifestURL = root.appendingPathComponent("recording/session.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var segments = manifest["segments"] as! [[String: Any]]
        for i in segments.indices {
            var files = segments[i]["files"] as! [String: String]
            files["camera"] = files["screen"] // a real decoded source, hidden below
            segments[i]["files"] = files
            var offsets = segments[i]["track_start_ns"] as! [String: Int64]
            offsets["camera"] = 200_000_000
            segments[i]["track_start_ns"] = offsets
        }
        manifest["segments"] = segments
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let project = try Project.create(package: root)
        try project.apply(.set(path: "camera.visible", value: .bool(false)))
        try project.apply(.deleteRange(startNs: 0, endNs: 1_000_000_000))
        let clips = try project.query("{\"q\":\"clips\"}", as: [ClipInfo].self)
        try project.apply(.setSpeed(clipID: clips[0].id, speed: 2))
        let snapshot = try project.snapshot()
        let renderer = try AgentFrameRenderer(snapshot: snapshot)
        let screen = try renderer.sourceLocation(atNs: 250_000_000, source: "screen")
        XCTAssertEqual(screen.fileNs, 1_500_000_000)
        XCTAssertTrue(screen.path.hasPrefix("seg-000/"))
        XCTAssertEqual(try renderer.sourceLocation(atNs: 250_000_000, source: "camera").fileNs, 1_300_000_000)
        XCTAssertEqual(try snapshot.frame(atNs: 250_000_000).camera.present, 0)
        XCTAssertGreaterThan(try renderer.grab(atNs: 250_000_000, source: "camera").width, 0)
        try project.apply(.deleteRange(startNs: 0, endNs: 100_000_000))
        XCTAssertEqual(try renderer.sourceLocation(atNs: 250_000_000, source: "screen").fileNs, screen.fileNs)
        // Every retained segment follows the core's mapping, including the split boundary.
        for time in stride(from: Int64(0), to: snapshot.durationNs, by: 100_000_000) {
            let frame = try snapshot.frame(atNs: time)
            XCTAssertEqual(try renderer.sourceLocation(atNs: time, source: "screen").fileNs, frame.screen.file_ns)
        }
    }
    /// Opt-in proof on a disposable real package; never opens a user's original.
    func testRealCaptureMatchesOneSecondExport() async throws {
        guard let path = ProcessInfo.processInfo.environment["YAPCAM_VISION_REAL_PACKAGE"],
              let output = ProcessInfo.processInfo.environment["YAPCAM_VISION_ARTIFACTS"] else {
            throw XCTSkip("Set YAPCAM_VISION_REAL_PACKAGE and YAPCAM_VISION_ARTIFACTS for the real recording proof")
        }
        _ = try requireRenderDevice()
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = try Project.open(package: URL(fileURLWithPath: path)).snapshot()
        let time: Int64 = ProcessInfo.processInfo.environment["YAPCAM_VISION_PARITY_ZOOM"] == "1" ? 9_000_000_000 : 6_000_000_000
        let suffix = time == 9_000_000_000 ? "-zoom" : ""
        let renderer = try AgentFrameRenderer(snapshot: project)
        let still = try renderer.capture(atNs: time, fitting: CGSize(width: 1280, height: 720))
        let png = root.appendingPathComponent("capture-parity\(suffix).png")
        let sink = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(sink, still, nil)
        XCTAssertTrue(CGImageDestinationFinalize(sink))
        let movie = root.appendingPathComponent("parity-export\(suffix).mp4")
        let settings = ExportSettings(outputHeight: still.height, fps: 60, includeAudio: false,
                                      rangeStartNs: time, rangeEndNs: time + 1_000_000_000)
        _ = try await Exporter(project: project, settings: settings, destination: movie).run { _ in }
        func decode(_ url: URL) throws -> [UInt8] {
            let task = Process(), pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            task.arguments = ["-v", "error", "-i", url.path, "-frames:v", "1", "-pix_fmt", "rgba", "-f", "rawvideo", "pipe:1"]
            task.standardOutput = pipe
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            XCTAssertEqual(task.terminationStatus, 0)
            return Array(data)
        }
        let captured = try decode(png), exported = try decode(movie)
        XCTAssertEqual(captured.count, exported.count)
        guard captured.count == exported.count, !captured.isEmpty else { return }
        var sum = 0, samples = 0, histogram = [Int](repeating: 0, count: 256)
        for i in stride(from: 0, to: captured.count, by: 4) {
            for channel in 0..<3 {
                let delta = abs(Int(captured[i + channel]) - Int(exported[i + channel]))
                sum += delta; samples += 1; histogram[delta] += 1
            }
        }
        var total = 0, p99 = 0
        for (delta, count) in histogram.enumerated() { total += count; if total * 100 >= samples * 99 { p99 = delta; break } }
        let mean = Double(sum) / Double(samples)
        print("AGENT_VISION_EXPORT_PARITY time_s=\(Double(time) / 1e9) mean_rgb_error=\(mean) p99=\(p99) size=\(still.width)x\(still.height)")
        XCTAssertLessThan(mean, 3)
        XCTAssertLessThan(p99, 25)
    }

}
