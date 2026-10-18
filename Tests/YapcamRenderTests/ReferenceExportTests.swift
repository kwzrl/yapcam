import XCTest
import AVFoundation
import VideoToolbox
import ImageIO
import AppKit
@testable import YapcamRender

final class ReferenceExportTests: XCTestCase {
    func testWebCompressionStaysVisibleButDoesNotSupport4K() {
        let presets=ExportSettings.Compression.allCases
        XCTAssertEqual(presets.map(\.title),["Studio","Social Media","Web","Web (Low)"])
        XCTAssertEqual(presets.map(\.supports4K),[true,true,false,false])
    }

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
        XCTAssertEqual(ExportSettings.Compression.allCases.map(\.title),["Studio","Social Media","Web","Web (Low)"])
    }
    func testSharedQuickExportSummaryUsesEffectiveOptionsAndLegacyDecoding() throws {
        XCTAssertEqual(ExportSettings().summary(),"MP4 • H.264 • 720p • 60fps • Social Media")
        XCTAssertEqual(ExportSettings(codec: .hevc,outputHeight: 1080).summary(),"MP4 • HEVC • 1080p • 60fps • Social Media")
        XCTAssertEqual(ExportSettings(codec: .both,outputHeight: 2160,compression: .studio).summary(),"MP4 • Both • 4K • 60fps • Studio")
        XCTAssertEqual(ExportSettings(codec: .both).summary(for: .clipboard),"MP4 • H.264 • 720p • 60fps • Social Media")
        XCTAssertEqual(ExportSettings(outputHeight: 2160,compression: .web).summary(),"MP4 • H.264 • 1080p • 60fps • Web")
        XCTAssertEqual(ExportSettings(format: .gif).summary(),"GIF • 480p • 15fps • High quality • Loop")
        XCTAssertEqual(ExportSettings(format: .gif,fps: 24,gifHighQuality: false,gifDisableLoop: true).summary(),"GIF • 480p • 20fps • Standard quality • Play once")
        XCTAssertEqual(ExportSettings(format: .gif,gifLoopCount: 4).summary(),"GIF • 480p • 15fps • High quality • Loop 4×")
        let legacy=try JSONDecoder().decode(ExportSettings.self,from: Data(#"{"quality":0.4}"#.utf8))
        XCTAssertTrue(legacy.hardwareEncodingEnabled)
        XCTAssertTrue(legacy.hardwareDecodingEnabled); XCTAssertFalse(legacy.lowMemory)
        XCTAssertFalse(legacy.parallelSegments)
        XCTAssertEqual(legacy.summary(),"MP4 • H.264 • 720p • 60fps • Custom")
        let software=ExportSettings(codec: .both,hardwareEncodingEnabled: false,hardwareDecodingEnabled: false,lowMemory: true,parallelSegments: true)
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self,from: JSONEncoder().encode(software)),software)
        XCTAssertFalse(software.closestValidPreset().hardwareEncodingEnabled)
        XCTAssertFalse(software.closestValidPreset().hardwareDecodingEnabled)
        XCTAssertTrue(software.closestValidPreset().lowMemory)
        XCTAssertTrue(software.closestValidPreset().parallelSegments)
        XCTAssertThrowsError(try JSONDecoder().decode(ExportSettings.self,from: Data(#"{"hardwareEncodingEnabled":"false"}"#.utf8)))
    }
    func testFiniteGIFLoopCountPolicyAndValidation() throws {
        let properties=try XCTUnwrap(GIFFrameDestination.containerProperties(disableLoop: false,loopCount: 7) as? [CFString:Any])
        let gif=try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString:Any])
        XCTAssertEqual(gif[kCGImagePropertyGIFLoopCount] as? Int,7)
        XCTAssertNil(GIFFrameDestination.containerProperties(disableLoop: true,loopCount: nil))
        XCTAssertNoThrow(try ExportSettings(format: .gif,gifLoopCount: 2).validatedRange(duration: 1))
        XCTAssertNoThrow(try ExportSettings(format: .gif,gifLoopCount: 10).validatedRange(duration: 1))
        XCTAssertThrowsError(try ExportSettings(format: .gif,gifLoopCount: 1).validatedRange(duration: 1))
        XCTAssertThrowsError(try ExportSettings(format: .gif,gifDisableLoop: true,gifLoopCount: 2).validatedRange(duration: 1))
    }
    func testSoftwareDecoderAndLowMemoryPoliciesReachReaderAndExporter() throws {
        let software=FrameSource.outputSettings(hardwareDecodingEnabled: false)
        let properties=try XCTUnwrap(software[AVVideoDecompressionPropertiesKey] as? [String:Any])
        XCTAssertEqual(properties[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String] as? Bool,false)
        let normal=FrameSource.outputSettings(hardwareDecodingEnabled: true)
        let normalProperties=try XCTUnwrap(normal[AVVideoDecompressionPropertiesKey] as? [String:Any])
        XCTAssertEqual(normalProperties[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String] as? Bool,true)

        let root=try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let exporter=try Exporter(project: try syntheticSource(root),settings: .init(lowMemory: true),destination: root.appendingPathComponent("low-memory.mp4"))
        XCTAssertTrue(exporter.effectiveSettings.lowMemory)
        XCTAssertEqual(exporter.maxInFlightFrames,2)
    }
    func testParallelExportPlanPreservesContiguousFrameGrid() {
        for fps in ExportSettings.frameRates(for: .mp4) {
            for duration: Int64 in [16_000_000,100_000_000,1_000_000_000,1_234_567_890,9_999_999_999] {
                let range=123_456_789..<(123_456_789+duration)
                let plan=ParallelExportPlan.make(range: range,fps: fps)
                XCTAssertEqual(plan.ranges.first?.lowerBound,range.lowerBound)
                XCTAssertEqual(plan.ranges.last?.upperBound,range.upperBound)
                if plan.ranges.count==2 { XCTAssertEqual(plan.ranges[0].upperBound,plan.ranges[1].lowerBound) }
                XCTAssertEqual(plan.ranges.reduce(0) { $0+ExportTiming.frameCount(durationNs: Int64($1.count),fps: fps) },
                               ExportTiming.frameCount(durationNs: duration,fps: fps))
            }
        }
    }
    func testTwoHundredMillisecondSixtyFPSGridAndParallelPlanProduceTwelveFrames() {
        let duration: Int64=200_000_000, fps=60
        let plan=ParallelExportPlan.make(range: 0..<duration,fps: fps)
        XCTAssertEqual(ExportTiming.frameCount(durationNs: duration,fps: fps),12)
        XCTAssertEqual(plan.ranges.reduce(0) { $0+ExportTiming.frameCount(durationNs: Int64($1.count),fps: fps) },12)
    }
    func testLowMemoryAndParallelExportsMatchSerialFrameCountOnHost() async throws {
        _ = try requireRenderDevice()
        let root=try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source=try syntheticSource(root)
        var mediaCounts: [Int]=[], submittedCounts: [Int]=[]
        for (name,settings) in [
            ("serial",ExportSettings(fps: 60,includeAudio: false)),
            ("low-memory",ExportSettings(fps: 60,includeAudio: false,lowMemory: true)),
            ("parallel",ExportSettings(fps: 60,includeAudio: false,parallelSegments: true))
        ] {
            let url=root.appendingPathComponent("\(name).mp4")
            let exporter=try Exporter(project: source,settings: settings,destination: url)
            _ = try await exporter.run { _ in }
            XCTAssertGreaterThan(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,1_024)
            let asset=AVURLAsset(url: url),reader=try AVAssetReader(asset: asset)
            let tracks=try await asset.loadTracks(withMediaType: .video)
            let track=try XCTUnwrap(tracks.first)
            let output=AVAssetReaderTrackOutput(track: track,outputSettings: nil)
            reader.add(output); XCTAssertTrue(reader.startReading())
            var mediaCount=0, markerCount=0
            while let sample=output.copyNextSampleBuffer() {
                let samples=CMSampleBufferGetNumSamples(sample)
                mediaCount+=samples
                if samples==0 { markerCount+=1 }
            }
            XCTAssertEqual(reader.status,.completed)
            print("RENDER_EXPORT_COUNT path=\(name) media_samples=\(mediaCount) marker_buffers=\(markerCount)")
            mediaCounts.append(mediaCount)
            submittedCounts.append(try XCTUnwrap(exporter.encodedVideoFrames))
        }
        XCTAssertEqual(submittedCounts,[12,12,12],"Serial, low-memory, and parallel paths must submit the same twelve-frame logical grid")
        XCTAssertEqual(mediaCounts,submittedCounts,"Marker-only AVAssetReader buffers are not encoded video frames")
    }
    func testExplicitSoftwareH264ExportOnHost() async throws {
        _ = try requireRenderDevice()
        let root=try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source=try syntheticSource(root)
        let url=root.appendingPathComponent("software.mp4")
        let exporter=try Exporter(project: source,settings: .init(fps: 10,includeAudio: false,hardwareEncodingEnabled: false),destination: url)
        _ = try await exporter.run { _ in }
        let asset=AVURLAsset(url: url)
        let track=try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        XCTAssertEqual(track.nominalFrameRate,10)
        XCTAssertEqual(track.naturalSize,CGSize(width: 1152,height: 720))
        XCTAssertEqual(exporter.encodedVideoFrames,2)
        XCTAssertFalse(exporter.effectiveSettings.hardwareEncodingEnabled)
    }
    func testSoftwareEncoderPreferenceReachesVideoToolboxSpecification() throws {
        let software = videoOutputSettings(for: .init(hardwareEncodingEnabled: false), width: 1280, height: 720)
        let softwareSpecification = try XCTUnwrap(software[AVVideoEncoderSpecificationKey] as? [String: Any])
        XCTAssertEqual(softwareSpecification[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] as? Bool, false)

        let normal = videoOutputSettings(for: .init(), width: 1280, height: 720)
        let normalSpecification = try XCTUnwrap(normal[AVVideoEncoderSpecificationKey] as? [String: Any])
        XCTAssertEqual(normalSpecification[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] as? Bool, true)
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
    func testClosestValidPresetMapsOldSheetsAndPreservesSavedControls() throws {
        let bytes = Data(#"{"format":"gif","codec":"hevc","outputHeight":1440,"fps":24,"quality":0.6,"includeAudio":true,"rangeStartNs":10,"rangeEndNs":700000000}"#.utf8)
        let saved = try JSONDecoder().decode(ExportSettings.self,from: bytes)
        // Decoding remains lossless for old frame rates, dimensions and quality;
        // normalization is explicit and must not silently rewrite saved records.
        XCTAssertEqual(saved.fps,24); XCTAssertEqual(saved.outputHeight,1440)
        XCTAssertEqual(saved.quality,0.6); XCTAssertNil(saved.compression)
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self,from: JSONEncoder().encode(saved)),saved)
        let mapped = saved.closestValidPreset()
        XCTAssertEqual(mapped.fps,20); XCTAssertEqual(mapped.outputHeight,1080); XCTAssertEqual(mapped.codec,.h264)
        XCTAssertFalse(mapped.includeAudio); XCTAssertNil(mapped.speechEnhancement)
        XCTAssertEqual(mapped.rangeStartNs,10); XCTAssertEqual(mapped.rangeEndNs,700_000_000)
        XCTAssertEqual(mapped.quality,0.6); XCTAssertNil(mapped.compression)
        XCTAssertEqual(saved.fps,24,"Mapping must not mutate the caller's settings")
        for format in [ExportSettings.Format.mp4,.mov,.gif] {
            for compression in ExportSettings.Compression.allCases {
                for target in ExportSettings.Target.allCases {
                    for fps in [Int.min,9,24,29,60,Int.max] {
                        for height in [Int.min,480,719,1440,2160,Int.max] {
                            let requested = ExportSettings(format: format,codec: .both,outputHeight: height,fps: fps,compression: compression,gifHighQuality: false,gifDisableLoop: true)
                            let result = requested.closestValidPreset(for: target)
                            XCTAssertNoThrow(try result.validatedRange(duration: 1))
                            XCTAssertEqual(result.closestValidPreset(for: target),result,"Mapping is idempotent")
                            XCTAssertEqual(result.compression,compression)
                            XCTAssertFalse(result.gifHighQuality); XCTAssertTrue(result.gifDisableLoop)
                            if target == .clipboard || format == .gif { XCTAssertNotEqual(result.codec,.both) }
                        }
                    }
                }
            }
        }
        let web = ExportSettings(codec: .both,outputHeight: 2160,fps: 60,compression: .web).closestValidPreset()
        XCTAssertEqual(web.outputHeight,1080); XCTAssertEqual(web.fps,60); XCTAssertEqual(web.codec,.both)
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try syntheticSource(root)
        let legacy = ExportSettings(format: .gif,outputHeight: 720,fps: 24,quality: 0.6)
        XCTAssertThrowsError(try legacy.validatedRange(duration: source.durationNs),"The old sheet request is outside the new catalog; execution must map it first")
        let exporter = try Exporter(project: source,settings: legacy,destination: root.appendingPathComponent("legacy.gif"))
        XCTAssertEqual(exporter.effectiveSettings,legacy.closestValidPreset())
        for invalid in [ExportSettings(fps: 0),ExportSettings(outputHeight: -1),ExportSettings(quality: .nan),ExportSettings(rangeEndNs: 300_000_000)] {
            XCTAssertThrowsError(try Exporter(project: source,settings: invalid,destination: root.appendingPathComponent("bad.mp4")))
        }
    }
    func testLegacyEditorGIFExportsWithClosestSupportedRateOnHost() async throws {
        _ = try requireRenderDevice()
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try syntheticSource(root)
        let output = root.appendingPathComponent("legacy.gif")
        let exporter = try Exporter(project: source,settings: .init(format: .gif,outputHeight: 720,fps: 24,quality: 0.6),destination: output)
        _ = try await exporter.run { _ in }
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL,nil))
        XCTAssertEqual(CGImageSourceGetCount(image),4)
        XCTAssertEqual(exporter.metrics?.frames,4)
        XCTAssertEqual(exporter.effectiveSettings.fps,20)
        var duration = 0.0
        for i in 0..<4 {
            let p = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image,i,nil) as? [CFString:Any])
            let gif = try XCTUnwrap(p[kCGImagePropertyGIFDictionary] as? [CFString:Any])
            duration += try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
        }
        XCTAssertEqual(duration,0.2,accuracy: 0.000001)
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
