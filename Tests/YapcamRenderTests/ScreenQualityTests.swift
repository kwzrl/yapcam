import XCTest
import AVFoundation
import YapcamCore
@testable import YapcamRender

final class ScreenQualityTests: XCTestCase {
    private var fixture: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam") }
    func testSettingsAndOptionalQueryKeepLegacyPathUntilSelected() throws {
        XCTAssertEqual(ScreenQualitySettings().improveQuality,0.5)
        XCTAssertEqual(ScreenQualitySettings().upscaling,.quality)
        XCTAssertNil(RenderConfiguration().screenQuality)
        for value in [Float.nan,-1,2] { XCTAssertThrowsError(try ScreenQualitySettings(improveQuality: value).validate()) }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-quality-contract-\(UUID().uuidString).yapcam")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture,to: root)
        let project=try Project.create(package: root)
        var json=try project.query("{\"q\":\"render_options_at\",\"tl_ns\":0}",as: [String:JSONValue].self)
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertNil(try decoder.decode(ProjectRenderOptions.self,from: JSONEncoder().encode(json)).screenQuality)
        json["screen_quality"] = .object([:])
        XCTAssertEqual(try decoder.decode(ProjectRenderOptions.self,from: JSONEncoder().encode(json)).screenQuality,ScreenQualitySettings())
        for mode in ScreenQualitySettings.Upscaling.allCases {
            json["screen_quality"] = .object(["improve_quality":.number(0.25),"upscaling":.string(mode.rawValue)])
            let settings=try decoder.decode(ProjectRenderOptions.self,from: JSONEncoder().encode(json)).screenQuality
            XCTAssertEqual(settings,ScreenQualitySettings(improveQuality: 0.25,upscaling: mode))
        }
    }
    func testLocalPreferencesRoundTripPreserveLegacyAndValidateBeforeExport() throws {
        let legacy=try JSONDecoder().decode(ExportSettings.self,from: Data(#"{"format":"mp4","codec":"h264","outputHeight":720,"fps":30,"quality":0.5}"#.utf8))
        XCTAssertNil(legacy.screenQuality)
        XCTAssertNil(PreviewSettings().screenQuality)
        let source=TestSource(package: fixture)
        for mode in ScreenQualitySettings.Upscaling.allCases {
            let quality=ScreenQualitySettings(improveQuality: 0.7,upscaling: mode)
            let selected=ExportSettings(codec: .both,screenQuality: quality)
            XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self,from: JSONEncoder().encode(selected)),selected)
            XCTAssertEqual(selected.closestValidPreset(for: .clipboard).screenQuality,quality)
            var gif=selected; gif.format = .gif
            XCTAssertEqual(gif.closestValidPreset().screenQuality,quality,"Palette and frame passes must use the same selected processing")
            XCTAssertNoThrow(try PreviewSettings(screenQuality: quality).validate())
            let exporter=try Exporter(project: source,settings: selected,destination: fixture.appendingPathComponent("unused.mp4"))
            XCTAssertEqual(exporter.effectiveSettings.screenQuality,quality)
        }
        for amount in [Float.nan,.infinity,-0.1,1.1] {
            let invalid=ScreenQualitySettings(improveQuality: amount)
            XCTAssertThrowsError(try PreviewSettings(screenQuality: invalid).validate())
            XCTAssertThrowsError(try Exporter(project: source,settings: .init(screenQuality: invalid),destination: fixture.appendingPathComponent("unused.mp4")))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ExportSettings.self,from: Data(#"{"screenQuality":{"improveQuality":2,"upscaling":"quality"}}"#.utf8)))
    }

    @MainActor func testLocalPreviewOverrideRestoresProjectPixelsWithoutResettingAudioOrDecoderOnHost() async throws {
        let device=try requireRenderDevice()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-quality-preferences-\(UUID().uuidString).yapcam")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture,to: root)
        try await Self.replaceScreenWithPattern(in: root)
        var frame=YcFrame(); frame.canvas_w=64; frame.canvas_h=40; frame.click_progress = -1
        frame.screen.present=1; frame.screen.segment=0
        frame.screen_crop = .init(x: 0,y: 0,w: 1,h: 1); frame.screen_dest = .init(x: 0,y: 0,w: 64,h: 40)
        var configuration=RenderConfiguration()
        configuration.screenQuality = .init(improveQuality: 1,upscaling: .quality)
        let source=TestSource(package: root,configuration: configuration) { _ in frame }
        let player=try PreviewPlayer(project: source)
        defer { player.pause() }
        let queue=try XCTUnwrap(device.makeCommandQueue())
        let target=try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,width: 128,height: 80,mipmapped: false)))
        func pixels(_ compositor: FrameCompositor) throws -> [UInt8] {
            let cb=try XCTUnwrap(queue.makeCommandBuffer())
            try compositor.encode(frame,to: target,in: cb); cb.commit(); cb.waitUntilCompleted()
            XCTAssertEqual(cb.status,.completed,cb.error?.localizedDescription ?? "")
            var bytes=[UInt8](repeating: 0,count: 128*80*4)
            target.getBytes(&bytes,bytesPerRow: 128*4,from: MTLRegionMake2D(0,0,128,80),mipmapLevel: 0)
            return bytes
        }
        let inherited=try pixels(player.compositor), generation=player.audioGeneration
        let opens=player.compositor.sourceOpenCount
        let bypass=ScreenQualitySettings(improveQuality: 0,upscaling: .off)
        try player.setPreviewSettings(.init(screenQuality: bypass))
        let unprocessed=try pixels(player.compositor)
        XCTAssertNotEqual(unprocessed,inherited)
        // Export constructs this same compositor with the chosen local preference.
        let exportCompositor=try FrameCompositor(device: device,project: source,screenQuality: bypass)
        XCTAssertEqual(try pixels(exportCompositor),unprocessed)
        XCTAssertThrowsError(try player.setPreviewSettings(.init(screenQuality: .init(improveQuality: .nan))))
        XCTAssertEqual(player.previewSettings.screenQuality,bypass)
        XCTAssertEqual(try pixels(player.compositor),unprocessed)
        try player.setPreviewSettings(.init())
        XCTAssertEqual(try pixels(player.compositor),inherited,"Nil restores the project's evaluated setting")
        XCTAssertEqual(player.audioGeneration,generation)
        XCTAssertEqual(player.compositor.sourceOpenCount,opens)
        XCTAssertFalse(player.isPlaying)
    }
    func testScreenDenoiseUpscalersAndCropBoundsOnHost() async throws {
        _ = try requireRenderDevice()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-quality-pixels-\(UUID().uuidString).yapcam")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture,to: root)
        try await Self.replaceScreenWithPattern(in: root)
        var f=YcFrame(); f.canvas_w=64; f.canvas_h=40; f.click_progress = -1
        f.screen.present=1; f.screen.segment=0; f.screen_crop = .init(x: 0,y: 0,w: 1,h: 1); f.screen_dest = .init(x: 0,y: 0,w: 64,h: 40)
        func image(_ quality: ScreenQualitySettings?,_ width: Int = 64,_ height: Int = 40) throws -> [UInt8] {
            var c=RenderConfiguration(); c.screenQuality=quality
            return try RenderTests().pixels(f,source: TestSource(package: root,configuration: c),width: width,height: height)
        }
        let baseline=try image(nil)
        XCTAssertEqual(try image(.init(improveQuality: 0,upscaling: .off)),baseline)
        let cleaned=try image(.init(improveQuality: 1,upscaling: .off))
        func variance(_ p: [UInt8]) -> Double {
            let values=(8..<32).flatMap { y in (24..<40).map { x in Double(p[(y*64+x)*4]) } }
            let mean=values.reduce(0,+)/Double(values.count)
            return values.map { ($0-mean)*($0-mean) }.reduce(0,+)/Double(values.count)
        }
        XCTAssertGreaterThan(variance(baseline),1,"The encoded authored noise must survive for this test to be meaningful")
        XCTAssertLessThan(variance(cleaned),variance(baseline)*0.95)
        let linear=try image(.init(improveQuality: 0,upscaling: .off),128,80)
        let fast=try image(.init(improveQuality: 0,upscaling: .fast),128,80)
        let quality=try image(.init(improveQuality: 0,upscaling: .quality),128,80)
        XCTAssertNotEqual(fast,linear); XCTAssertNotEqual(quality,linear); XCTAssertNotEqual(fast,quality)
        // Pink source pixels end at x15; the selected crop starts at x16.
        f.screen_crop = .init(x: 0.25,y: 0,w: 0.75,h: 1)
        let cropped=try image(.init(improveQuality: 1,upscaling: .quality),128,80)
        for y in 16..<64 {
            let i=(y*128)*4
            let color=cropped[i..<i+3].map(Int.init)
            // Decode may already have chroma bleed at the source boundary.
            // Processing must not add hidden-source color beyond that baseline.
            let visibleSpan=(max(0,y/2-2)...min(39,y/2+2)).flatMap { row in (16...18).map { x -> Int in
                let j=(row*64+x)*4, c=baseline[j..<j+3].map(Int.init)
                return c.max()!-c.min()!
            } }.max()!
            XCTAssertLessThanOrEqual(color.max()!-color.min()!,visibleSpan+10,"Kernel must not pull hidden pink source pixels across crop bounds")
        }
    }
    private static func replaceScreenWithPattern(in package: URL) async throws {
        try await writePattern(package.appendingPathComponent("recording/seg-000/quality.mov"))
        let session=package.appendingPathComponent("recording/session.json")
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: session)) as? [String:Any])
        var segments=try XCTUnwrap(json["segments"] as? [[String:Any]])
        var files=try XCTUnwrap(segments[0]["files"] as? [String:String])
        files["screen"]="seg-000/quality.mov"; segments[0]["files"]=files; json["segments"]=segments
        try JSONSerialization.data(withJSONObject: json).write(to: session)
    }
    private static func writePattern(_ url: URL) async throws {
        let writer=try AVAssetWriter(outputURL: url,fileType: .mov)
        let input=AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:64,AVVideoHeightKey:40,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:4_000_000]])
        guard writer.canAdd(input) else { throw RenderError.write("Pattern encoder unavailable") }; writer.add(input)
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes: nil)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil,64,40,kCVPixelFormatType_32BGRA,nil,&buffer)==kCVReturnSuccess, let buffer else { throw RenderError.write("Pattern allocation failed") }
        CVPixelBufferLockBaseAddress(buffer,[])
        let bytes=CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self), stride=CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<40 { for x in 0..<64 {
            let i=y*stride+x*4, value: UInt8=(x+y)%2==0 ? 118 : 138
            if x<16 { bytes[i]=255; bytes[i+1]=0; bytes[i+2]=255 }
            else { bytes[i]=value; bytes[i+1]=value; bytes[i+2]=value }
            bytes[i+3]=255
        } }
        CVPixelBufferUnlockBaseAddress(buffer,[])
        guard writer.startWriting() else { throw RenderError.write("Pattern writer did not start") }
        defer { if writer.status != .completed { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        let deadline=ProcessInfo.processInfo.systemUptime+15
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing, ProcessInfo.processInfo.systemUptime<deadline else { throw RenderError.write("Pattern encoder timed out") }
            try await Task.sleep(for: .milliseconds(2))
        }
        guard adaptor.append(buffer,withPresentationTime: .zero) else { throw RenderError.write("Pattern append failed") }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 1,timescale: 30))
        await writer.finishWriting()
        guard writer.status == .completed else { throw RenderError.write("Pattern finalization failed") }
    }
}
