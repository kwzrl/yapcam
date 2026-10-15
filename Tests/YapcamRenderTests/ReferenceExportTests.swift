import XCTest
import AVFoundation
import ImageIO
import AppKit
@testable import YapcamRender

final class ReferenceExportTests: XCTestCase {
    func testExactOptionSetsDefaultsAndResolutionGates() throws {
        let video = ExportSettings(), gif = ExportSettings(format: .gif)
        XCTAssertEqual(video.outputHeight,720); XCTAssertEqual(video.fps,60)
        XCTAssertEqual(video.compression,.social); XCTAssertEqual(video.codec,.h264)
        XCTAssertEqual(gif.outputHeight,480); XCTAssertEqual(gif.fps,15)
        XCTAssertTrue(gif.gifHighQuality); XCTAssertFalse(gif.gifDisableLoop); XCTAssertFalse(gif.includeAudio)
        XCTAssertEqual(ExportSettings.primaryFormats,[.mp4,.gif])
        XCTAssertEqual(ExportSettings.frameRates(for: .mp4),[60,50,30,25,24,20,10])
        XCTAssertEqual(ExportSettings.frameRates(for: .gif),[50,30,25,20,15,10])
        XCTAssertEqual(ExportSettings.heights(for: .mp4),[720,1080,2160])
        XCTAssertEqual(ExportSettings.heights(for: .gif),[480,720,1080])
        XCTAssertEqual(ExportSettings.normalizedFrameRate(29,for: .mp4),25)
        XCTAssertEqual(ExportSettings.normalizedFrameRate(24,for: .gif),20)
        XCTAssertEqual(ExportSettings.normalizedFrameRate(-1,for: .mp4),10)
        XCTAssertEqual(ExportSettings.codecs(for: .file),[.h264,.hevc,.both])
        XCTAssertEqual(ExportSettings.codecs(for: .clipboard),[.h264,.hevc])
        for preset in ExportSettings.Compression.allCases {
            let settings = ExportSettings(outputHeight: 2160,compression: preset)
            if preset.supports4K { XCTAssertNoThrow(try settings.validatedRange(duration: 1)) }
            else { XCTAssertThrowsError(try settings.validatedRange(duration: 1)) }
        }
        XCTAssertEqual(ExportSettings.Compression.allCases.map(\.preferredQuantizer),[14,24,30,42])
    }
    func testCompressionBitratesSavedLegacyQualityAndDimensionCaps() throws {
        let rates = ExportSettings.Compression.allCases.map { ExportSettings(compression: $0).videoBitrate(width: 1280) }
        XCTAssertEqual(rates,[16_588_800,2_764_800,967_680,414_720])
        let original = ExportSettings(codec: .both,outputHeight: 1080,fps: 50,compression: .studio,gifDisableLoop: true)
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self,from: JSONEncoder().encode(original)),original)
        let legacy = try JSONDecoder().decode(ExportSettings.self,from: Data(#"{"format":"mp4","codec":"h264","outputHeight":1080,"fps":30,"quality":0.4,"includeAudio":true}"#.utf8))
        XCTAssertNil(legacy.compression); XCTAssertEqual(legacy.quality,0.4)
        XCTAssertTrue(legacy.gifHighQuality); XCTAssertFalse(legacy.gifDisableLoop)
        var mutated = ExportSettings(); mutated.quality = 0.2; XCTAssertNil(mutated.compression)
        let wide = try ExportSettings(outputHeight: 2160).outputSize(canvasWidth: 21,canvasHeight: 9)
        XCTAssertEqual(wide.width,3840); XCTAssertEqual(wide.height,1644)
        let odd = try ExportSettings(outputHeight: 1080).outputSize(canvasWidth: 1001,canvasHeight: 1000)
        XCTAssertEqual(odd.width,1080); XCTAssertEqual(odd.height,1080)
        for (w,h): (UInt32,UInt32) in [(16,9),(9,16),(21,9),(1,UInt32.max),(UInt32.max,1)] {
            let size = try ExportSettings(outputHeight: 2160).outputSize(canvasWidth: w,canvasHeight: h)
            XCTAssertTrue((2...3840).contains(size.width)); XCTAssertTrue((2...2160).contains(size.height))
            XCTAssertEqual(size.width%2,0); XCTAssertEqual(size.height%2,0)
        }
    }
    func testGlobalPaletteImprovesErrorAndGIFOnceHasNoRepeatExtension() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let image = try BackgroundLibrary.image(for: XCTUnwrap(BackgroundLibrary.preset(id: "quiet-dawn")),width: 64,height: 40)
        var histogram = GIFPaletteHistogram(); try histogram.add(image)
        let high = try histogram.palette().indexed(image), low = try GIFPalette.fast().indexed(image)
        let original = try GIFPalette.rgba(image)
        func error(_ image: CGImage) throws -> Double {
            let pixels = try GIFPalette.rgba(image)
            return zip(original,pixels).enumerated().filter { $0.offset%4 != 3 }.reduce(0) { $0+pow(Double($1.element.0)-Double($1.element.1),2) }
        }
        XCTAssertEqual(high.bitsPerPixel,8); XCTAssertEqual(high.colorSpace?.model,.indexed)
        XCTAssertLessThan(try error(high),try error(low))
        for once in [false,true] {
            let url = root.appendingPathComponent("\(once).gif")
            let writer = try GIFFrameDestination(url: url,count: 2,disableLoop: once)
            writer.add(high,delay: 0.07); writer.add(high,delay: 0.06)
            let source = try writer.finish()
            XCTAssertEqual(CGImageSourceGetCount(source),2)
            let properties = try XCTUnwrap(CGImageSourceCopyProperties(source,nil) as? [CFString:Any])
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString:Any]
            if once { XCTAssertNil(try Data(contentsOf: url).range(of: Data("NETSCAPE2.0".utf8)), "One-play GIF must omit the repeat extension") }
            else { XCTAssertEqual(gif?[kCGImagePropertyGIFLoopCount] as? Int,0) }
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
            XCTAssertEqual(frame.width,64); XCTAssertEqual(frame.height,40)
        }
    }
    func testFailedPairPublicationRollsBackOnlyNewOutputAndPreservesExistingCompanion() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let sources = [root.appendingPathComponent("stage-a"),root.appendingPathComponent("stage-b")]
        let targets = [root.appendingPathComponent("a.mp4"),root.appendingPathComponent("a-h265.mp4")]
        for source in sources { try Data("new".utf8).write(to: source) }
        let existing = Data("existing user's output".utf8); try existing.write(to: targets[1])
        XCTAssertThrowsError(try ExportPublication.publish(Array(zip(sources,targets))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targets[0].path))
        XCTAssertEqual(try Data(contentsOf: targets[1]),existing)
    }
    @MainActor func testClipboardPublishesCompletedFileOnlyRetainsHistoryAndCleansFailures() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var copied: [URL] = []
        let output = try await ClipboardExport.perform(settings: .init(),directory: root,render: { url in
            XCTAssertTrue(copied.isEmpty)
            try Data("completed synthetic output".utf8).write(to: url); return url
        },publish: { copied.append($0) })
        XCTAssertEqual(copied,[output]); XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try ClipboardExport.previousExports(directory: root).map(\.lastPathComponent),[output.lastPathComponent])
        try Data("unrelated".utf8).write(to: root.appendingPathComponent("other.mp4"))
        do {
            _ = try await ClipboardExport.perform(settings: .init(),directory: root,render: { url in
                try Data("partial".utf8).write(to: url); throw RenderError.write("injected render failure")
            },publish: { _ in XCTFail("Failed render changed clipboard") })
            XCTFail("Expected failure")
        } catch RenderError.write { }
        XCTAssertEqual(try ClipboardExport.previousExports(directory: root).map(\.lastPathComponent),[output.lastPathComponent])
        let cancelled = Task { @MainActor in
            try await ClipboardExport.perform(settings: .init(),directory: root,render: { url in
                try Data("completed but cancelled".utf8).write(to: url)
                withUnsafeCurrentTask { $0?.cancel() }; return url
            },publish: { _ in XCTFail("Cancelled render changed clipboard") })
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertEqual(try ClipboardExport.previousExports(directory: root).map(\.lastPathComponent),[output.lastPathComponent])
        do {
            _ = try await ClipboardExport.perform(settings: .init(codec: .both),directory: root,render: { _ in XCTFail("Both must be file-only"); return output },publish: { _ in XCTFail() })
            XCTFail("Expected single-codec requirement")
        } catch RenderError.invalidSettings { }
    }
    func testEveryVideoRateBothCodecsAndBothFileOutputOnHost() async throws {
        _ = try requireRenderDevice()
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try syntheticSource(root)
        for codec in [ExportSettings.Codec.h264,.hevc,.both] {
            let rates = codec == .both ? [50] : ExportSettings.frameRates(for: .mp4)
            for fps in rates {
                let settings = ExportSettings(codec: codec,fps: fps,includeAudio: false)
                let url = root.appendingPathComponent("\(codec.rawValue)-\(fps).mp4")
                let exporter = try Exporter(project: source,settings: settings,destination: url)
                _ = try await exporter.run { _ in }
                XCTAssertEqual(exporter.outputURLs,settings.destinations(for: url))
                for (i,output) in exporter.outputURLs.enumerated() {
                    let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
                    let track = try XCTUnwrap(tracks.first)
                    let rate = try await track.load(.nominalFrameRate)
                    let descriptions = try await track.load(.formatDescriptions)
                    XCTAssertEqual(rate,Float(fps),accuracy: 0.01)
                    let expected = codec == .hevc || i == 1 ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
                    XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(descriptions.first)),expected)
                }
            }
        }
    }
    @MainActor func testRealGIFFileClipboardUsesURLPasteboardOnHost() async throws {
        _ = try requireRenderDevice()
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try syntheticSource(root)
        let pasteboard = NSPasteboard(name: .init("mov.yapcam.render-test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let output = try await ClipboardExport.run(project: source,settings: .init(format: .gif),directory: root,pasteboard: pasteboard)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        let pasted = try XCTUnwrap(urls?.first)
        XCTAssertEqual(urls?.count,1); XCTAssertEqual(pasted.lastPathComponent,output.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: pasted),try Data(contentsOf: output))
    }
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-reference-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true); return url
    }
    private func syntheticSource(_ root: URL) throws -> TestSource {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recording"),withIntermediateDirectories: true)
        try Data("{\"segments\":[]}".utf8).write(to: root.appendingPathComponent("recording/session.json"))
        return TestSource(package: root,duration: 200_000_000)
    }
}
