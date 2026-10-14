import XCTest
@testable import YapcamRender
import Metal
import AVFoundation
import CoreVideo
import ImageIO

final class TestSource: RenderProjectSource, @unchecked Sendable {
    let packageURL: URL
    let durationNs: Int64
    let evaluate: (Int64) -> YcFrame
    let clips: [RenderClip]
    let overlays: [AudioOverlay]
    init(package: URL, duration: Int64 = 500_000_000, clips: [RenderClip] = [], overlays: [AudioOverlay] = [], evaluate: @escaping (Int64) -> YcFrame = { ns in
        var f = YcFrame(); f.tl_ns = ns; f.canvas_w = 320; f.canvas_h = 200; f.background_color = (0.5,0.25,0.75,1); f.click_progress = -1; return f
    }) { packageURL = package; durationNs = duration; self.clips = clips; self.overlays = overlays; self.evaluate = evaluate }
    func frame(atNs: Int64) throws -> YcFrame { evaluate(atNs) }
    func renderSnapshot() throws -> any RenderProjectSource { self }
    func renderClips() throws -> [RenderClip] { clips }
    func renderAudioOverlays() throws -> [AudioOverlay] { overlays }
}

final class RenderTests: XCTestCase {
    var temp: URL!
    var fixture: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam") }
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("recording"), withIntermediateDirectories: true)
        try Data("{\"segments\":[]}".utf8).write(to: temp.appendingPathComponent("recording/session.json"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }
    func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable in the execution sandbox; run on host for GPU verification") }; return device
    }
    func pixels(_ frame: YcFrame, source: TestSource, width: Int = 64, height: Int = 40) throws -> [UInt8] {
        let d = try device(), compositor = try FrameCompositor(device: d, project: source)
        let texture = try XCTUnwrap(d.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)))
        let cb = try XCTUnwrap(d.makeCommandQueue()?.makeCommandBuffer())
        try compositor.encode(frame, to: texture, in: cb); cb.commit(); cb.waitUntilCompleted()
        XCTAssertEqual(cb.status, .completed, cb.error?.localizedDescription ?? "")
        var bytes = [UInt8](repeating: 0, count: width*height*4)
        texture.getBytes(&bytes, bytesPerRow: width*4, from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0)
        return bytes
    }
    func testSolidSRGBGammaAndScaledCanvas() throws {
        let source = TestSource(package: temp), frame = try source.frame(atNs: 0)
        let bytes = try pixels(frame, source: source)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            XCTAssertEqual(Double(bytes[index]), 191, accuracy: 1)
            XCTAssertEqual(Double(bytes[index+1]), 64, accuracy: 1)
            XCTAssertEqual(Double(bytes[index+2]), 128, accuracy: 1)
            XCTAssertEqual(bytes[index+3], 255)
        }
    }
    func testGradientIsLinearLight() throws {
        let source = TestSource(package: temp); var frame = try source.frame(atNs: 0)
        frame.background_kind = 1; frame.background_color = (0,0,0,1); frame.background_color2 = (1,1,1,1)
        let bytes = try pixels(frame, source: source, width: 100, height: 40)
        XCTAssertEqual(Double(bytes[(20*100+49)*4]), 187, accuracy: 2)
        XCTAssertLessThan(bytes[0], bytes[99*4])
    }
    func testIOSurfaceNearestFrameAndRandomScrub() throws {
        var cache: CVMetalTextureCache?; CVMetalTextureCacheCreate(nil,nil,try device(),nil,&cache)
        let source = try FrameSource(url: fixture.appendingPathComponent("recording/seg-000/screen.mov"), cache: XCTUnwrap(cache))
        for ns: Int64 in [0, 45_000_000, 2_400_000_000, 300_000_000, 2_990_000_000, 1_000_000_000] {
            let frame = try source.frame(atNs: ns)
            XCTAssertNotNil(CVPixelBufferGetIOSurface(frame.pixelBuffer))
            XCTAssertLessThanOrEqual(abs(frame.time.seconds - Double(ns)/1e9), 1/30.0 + 0.000_001)
            XCTAssertEqual(frame.texture.width, 320)
        }
    }
    func testCropAndRoundedCorners() throws {
        let source = TestSource(package: fixture)
        var f = try source.frame(atNs: 0); f.screen.present = 1; f.screen.segment = 0; f.screen.file_ns = 0
        f.screen_dest = .init(x: 32,y: 20,w: 256,h: 160); f.screen_crop = .init(x: 0.25,y: 0.25,w: 0.5,h: 0.5); f.screen_corner_radius = 30
        let a = try pixels(f, source: source)
        for (actual,expected) in zip(a[0..<4],[191,64,128,255]) { XCTAssertEqual(Double(actual),Double(expected),accuracy: 1) }
        // Rounded corner remains background; center contains decoded crop.
        for (actual,expected) in zip(a[(4*64+6)*4..<(4*64+6)*4+4],[191,64,128,255]) { XCTAssertEqual(Double(actual),Double(expected),accuracy: 1) }
        XCTAssertNotEqual(Array(a[(20*64+32)*4..<(20*64+32)*4+4]), [191,64,128,255])
    }
    func testSettingsRejectInvalidRangesAndNonfiniteQuality() throws {
        XCTAssertThrowsError(try ExportSettings(quality: .nan).validatedRange(duration: 1))
        XCTAssertThrowsError(try ExportSettings(rangeStartNs: 10, rangeEndNs: 5).validatedRange(duration: 20))
        XCTAssertThrowsError(try ExportSettings(outputHeight: 100).validatedRange(duration: 20))
        XCTAssertEqual(try ExportSettings().outputWidth(canvasWidth: 1680, canvasHeight: 1050), 1728)
        XCTAssertThrowsError(try mediaURL("../../outside", root: temp))
    }
    func testVideoExportReopensAndFFprobeAgrees() async throws {
        _ = try device()
        let source = TestSource(package: temp)
        let output = temp.appendingPathComponent("output.mp4")
        let exporter = try Exporter(project: source, settings: .init(outputHeight: 720, fps: 30, includeAudio: false), destination: output)
        _ = try await exporter.run { _ in }
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration), video = try await asset.loadTracks(withMediaType: .video), audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(duration.seconds, 0.5, accuracy: 1/30)
        XCTAssertEqual(video.count,1); XCTAssertEqual(audio.count,0)
        XCTAssertEqual(exporter.metrics?.frames,15)
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffprobe") {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
            process.arguments = ["-v","error","-show_entries","stream=codec_name,width,height,nb_frames","-of","json",output.path]
            process.standardOutput = pipe; try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus,0)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let streams = try XCTUnwrap(json["streams"] as? [[String: Any]])
            XCTAssertEqual(streams[0]["height"] as? Int,720); XCTAssertEqual(streams[0]["codec_name"] as? String,"h264")
            XCTAssertEqual(streams[0]["nb_frames"] as? String,"15")
        }
    }
    func testGIFRangeAndFrameTiming() async throws {
        _ = try device()
        let source = TestSource(package: temp, duration: 1_000_000_000)
        let output = temp.appendingPathComponent("output.gif")
        let exporter = try Exporter(project: source, settings: .init(format: .gif, outputHeight: 720, fps: 30, includeAudio: false, rangeStartNs: 200_000_000, rangeEndNs: 400_000_000), destination: output)
        _ = try await exporter.run { _ in }
        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL,nil))
        XCTAssertEqual(CGImageSourceGetCount(gif),6)
        XCTAssertEqual(exporter.metrics?.frames,6)
    }
    func testCancelledExportRemovesPartialAndPreservesExistingFile() async throws {
        let source = TestSource(package: temp, duration: 10_000_000_000), output = temp.appendingPathComponent("cancel.mp4")
        let exporter = try Exporter(project: source, settings: .init(outputHeight: 720, includeAudio: false), destination: output)
        let task = Task { _ = try await exporter.run { _ in } }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temp.path).contains(where: { $0.hasPrefix(".yapcam-export-") }))
        let existing = Data("keep".utf8); try existing.write(to: output)
        do { _ = try await exporter.run { _ in }; XCTFail("Expected existing destination rejection") } catch {}
        XCTAssertEqual(try Data(contentsOf: output),existing)
    }
}
