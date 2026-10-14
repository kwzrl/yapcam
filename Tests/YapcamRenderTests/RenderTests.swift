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
    let layers: [RenderLayer]
    let renderConfiguration: RenderConfiguration
    init(package: URL, duration: Int64 = 500_000_000, clips: [RenderClip] = [], overlays: [AudioOverlay] = [], layers: [RenderLayer] = [], configuration: RenderConfiguration = .init(), evaluate: @escaping (Int64) -> YcFrame = { ns in
        var f = YcFrame(); f.tl_ns = ns; f.canvas_w = 320; f.canvas_h = 200; f.background_color = (0.5,0.25,0.75,1); f.click_progress = -1; return f
    }) { packageURL = package; durationNs = duration; self.clips = clips; self.overlays = overlays; self.layers = layers; renderConfiguration = configuration; self.evaluate = evaluate }
    func frame(atNs: Int64) throws -> YcFrame { evaluate(atNs) }
    func renderSnapshot() throws -> any RenderProjectSource { self }
    func renderClips() throws -> [RenderClip] { clips }
    func renderAudioOverlays() throws -> [AudioOverlay] { overlays }
    func renderLayers(atNs: Int64) throws -> [RenderLayer] { layers }
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
    func device() throws -> MTLDevice { try requireRenderDevice() }
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
    func testHighlightsDimOutsideAndTextRendersAboveCanvas() throws {
        let plain=TestSource(package: temp)
        let highlight=RenderLayer(content: .highlight(dimOpacity: 0.5,fill: .zero,stroke: .zero,strokeWidth: 0),rect: CGRect(x: 100,y: 60,width: 120,height: 80))
        let source=TestSource(package: temp,layers: [highlight])
        let a=try pixels(plain.frame(atNs: 0),source: plain), b=try pixels(source.frame(atNs: 0),source: source)
        XCTAssertLessThan(b[0],a[0])
        let center=(20*64+32)*4
        XCTAssertEqual(Double(b[center]),Double(a[center]),accuracy: 1)
        let text=RenderLayer(content: .text("⌘K 😀",fontSize: 40,color: SIMD4(1,1,1,1)),rect: CGRect(x: 20,y: 20,width: 260,height: 100))
        let withText=TestSource(package: temp,layers: [text])
        let c=try pixels(withText.frame(atNs: 0),source: withText)
        XCTAssertNotEqual(a,c)
    }
    func testGaussianBackgroundReducesSourceContrast() throws {
        _ = try device()
        let source=TestSource(package: fixture)
        var frame=try source.frame(atNs: 0); frame.background_kind=3; frame.screen.present=1; frame.screen_crop = .init(x: 0,y: 0,w: 1,h: 1)
        // Empty screen destination isolates the background and is a valid max-padding frame.
        frame.background_blur=0
        let sharp=try pixels(frame,source: source)
        frame.background_blur=30
        let blurred=try pixels(frame,source: source)
        func variation(_ pixels: [UInt8]) -> Double {
            var total=0.0
            for y in 0..<40 { for x in 1..<64 { total+=abs(Double(pixels[(y*64+x)*4])-Double(pixels[(y*64+x-1)*4])) } }
            return total
        }
        XCTAssertLessThan(variation(blurred),variation(sharp))
    }
    func testSettingsRejectInvalidRangesAndNonfiniteQuality() throws {
        XCTAssertThrowsError(try ExportSettings(quality: .nan).validatedRange(duration: 1))
        XCTAssertThrowsError(try ExportSettings(rangeStartNs: 10, rangeEndNs: 5).validatedRange(duration: 20))
        XCTAssertThrowsError(try ExportSettings(outputHeight: 100).validatedRange(duration: 20))
        XCTAssertEqual(try ExportSettings().outputWidth(canvasWidth: 1680, canvasHeight: 1050), 1728)
        XCTAssertThrowsError(try packageMediaURL("../../outside", root: temp))
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
        let source = TestSource(package: temp, duration: 1_500_000_000)
        let output = temp.appendingPathComponent("output.gif")
        let exporter = try Exporter(project: source, settings: .init(format: .gif, outputHeight: 720, fps: 30, includeAudio: false, rangeStartNs: 200_000_000, rangeEndNs: 1_200_000_000), destination: output)
        _ = try await exporter.run { _ in }
        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL,nil))
        XCTAssertEqual(CGImageSourceGetCount(gif),30)
        XCTAssertEqual(exporter.metrics?.frames,30)
    }
    func testStillFrameUsesTheSameCompositorAndVerticalOrientation() throws {
        let d=try device(), source=TestSource(package: temp)
        var frame=try source.frame(atNs: 0); frame.background_kind=1; frame.background_color=(0,0,0,1); frame.background_color2=(1,1,1,1); frame.background_angle_deg=90
        let compositor=try FrameCompositor(device: d,project: source)
        let image=try compositor.image(frame,size: CGSize(width: 64,height: 40))
        XCTAssertEqual(image.width,64); XCTAssertEqual(image.height,40)
        let data=try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertLessThan(data[0],data[(image.height-1)*image.bytesPerRow])
    }
    func testMOVAndHEVCFormatsAtSupportedFrameRates() async throws {
        _ = try device()
        let source=TestSource(package: temp,duration: 200_000_000)
        for (format,codec,fps) in [(ExportSettings.Format.mp4,ExportSettings.Codec.hevc,24),(.mov,.h264,60),(.mov,.hevc,30)] {
            let output=temp.appendingPathComponent("\(codec.rawValue)-\(fps).\(format.rawValue)")
            let exporter=try Exporter(project: source,settings: .init(format: format,codec: codec,outputHeight: 720,fps: fps,includeAudio: false),destination: output)
            _ = try await exporter.run { _ in }
            let tracks=try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
            let track=try XCTUnwrap(tracks.first)
            let actual=try await track.load(.nominalFrameRate)
            XCTAssertEqual(Double(actual),Double(fps),accuracy: 0.01)
        }
    }
    func testCancellationAfterProgressRemovesWriterPartial() async throws {
        _ = try device()
        let source=TestSource(package: temp,duration: 3_000_000_000), output=temp.appendingPathComponent("mid-cancel.mp4")
        let exporter=try Exporter(project: source,settings: .init(outputHeight: 720,includeAudio: false),destination: output)
        let task=Task { try await exporter.run { value in if value>0.1 { withUnsafeCurrentTask { $0?.cancel() } } } }
        do { _ = try await task.value; XCTFail("Expected mid-export cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temp.path).contains { $0.hasPrefix(".yapcam-export-") })
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
