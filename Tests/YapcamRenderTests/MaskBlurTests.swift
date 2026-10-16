import XCTest
import YapcamCore
import Metal
import Darwin
@preconcurrency import AVFoundation
@testable import YapcamRender

final class MaskBlurTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-mask-blur-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recording"),withIntermediateDirectories: true)
        try Data(#"{"segments":[]}"#.utf8).write(to: root.appendingPathComponent("recording/session.json"))
    }
    override func tearDownWithError() throws {
        if let root,FileManager.default.fileExists(atPath: root.path) {
            print("Cleaning own blur fixture: \(root.lastPathComponent): \(try FileManager.default.contentsOfDirectory(atPath: root.path))")
            try FileManager.default.removeItem(at: root)
        }
    }
    private func row(kind: String = "blur",radius: Any? = nil) throws -> CoreDrawingLayer {
        var fields: [String: Any]=["kind":kind,"rect":[16,8,32,24],"corner_radius":8,"opacity":0.75,
                                  "dim_opacity":1,"fill":[1,0,0,1],"stroke":[0,1,0,1],"stroke_width":20]
        fields["blur_radius"]=radius
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CoreDrawingLayer.self,from: JSONSerialization.data(withJSONObject: fields))
    }
    func testBlurQueryDefaultsBoundariesAndLegacyCoverRemainDistinct() throws {
        let defaults=try row().drawingLayer()
        XCTAssertEqual(defaults.content,.blur(radius: 32))
        XCTAssertEqual(defaults.rect,CGRect(x: 16,y: 8,width: 32,height: 24))
        XCTAssertEqual(defaults.opacity,0.75); XCTAssertEqual(defaults.cornerRadius,8)
        // Blur intentionally ignores highlight fill, border and outside dim.
        for radius: Float in [0,0.5,128] { XCTAssertEqual(try row(radius: radius).drawingLayer().content,.blur(radius: radius)) }
        for radius in [-0.001,128.001,128.00000001] { XCTAssertThrowsError(try row(radius: radius).drawingLayer()) }
        for radius in [Float.nan,.infinity,-.infinity] { XCTAssertThrowsError(try MaskBlur.validate(radius: radius)) }
        XCTAssertEqual(try row(kind: "highlight").drawingLayer().content,
                       .highlight(dimOpacity: 1,fill: SIMD4(1,0,0,1),stroke: SIMD4(0,1,0,1),strokeWidth: 20))
        XCTAssertThrowsError(try row(kind: "invented").drawingLayer())
    }
    func testRadiusScalesWithOutputAndZeroRemainsIdentity() throws {
        let canvas=SIMD2<Float>(1920,1080)
        XCTAssertEqual(try MaskBlur.scaledSigma(radius: 32,canvas: canvas,width: 1920,height: 1080),32)
        XCTAssertEqual(try MaskBlur.scaledSigma(radius: 32,canvas: canvas,width: 640,height: 360),32/3,accuracy: 0.00001)
        XCTAssertEqual(try MaskBlur.scaledSigma(radius: 32,canvas: canvas,width: 3840,height: 2160),64)
        XCTAssertEqual(try MaskBlur.scaledSigma(radius: 0,canvas: canvas,width: 3840,height: 2160),0)
        XCTAssertThrowsError(try MaskBlur.scaledSigma(radius: 32,canvas: .zero,width: 640,height: 360))
        XCTAssertThrowsError(try MaskBlur.scaledSigma(radius: 32,canvas: canvas,width: 0,height: 360))
        XCTAssertEqual(try MaskBlur.scaledSigma(radius: 128,canvas: SIMD2(1,1),width: 4096,height: 4096),524288)
    }
    func testRealCoreBlurAdapterPreservesGeometryTimingSnapshotAndFinalFadeOnce() throws {
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let package=root.appendingPathComponent("project.yapcam")
        try FileManager.default.copyItem(at: fixture,to: package)
        let project=try Project.create(package: package)
        try project.apply(.batch([
            .set(path: "canvas.highlights",value: .array([.object([
                "id":.string("private"),"kind":.string("blur"),"space":.string("source"),
                "rect":.array([0.25,0.25,0.5,0.5].map(JSONValue.number)),
                "tl_start_ns":.integer(0),"tl_end_ns":.integer(2_000_000_000)
            ])])),
            .set(path: "canvas.animation.entrance",value: .string("fade")),
            .set(path: "canvas.animation.entrance_duration_ns",value: .integer(2_000_000_000)),
            .addZoom(.init(startNs: 0,endNs: 2_000_000_000,target: [0.5,0.5],scale: 2,easeInNs: 0,easeOutNs: 0))
        ]))
        let frozen=try project.renderSnapshot(), frame=try frozen.frame(atNs: 1_000_000_000)
        let canvas=CGSize(width: Int(frame.canvas_w),height: Int(frame.canvas_h))
        let effects=try frozen.renderEffects(atNs: frame.tl_ns,canvasSize: canvas)
        XCTAssertEqual(effects.layers.count,2,"One blur plus final fade; never draw the opaque extras fallback as another layer")
        let blur=try XCTUnwrap(effects.layers.first)
        XCTAssertEqual(blur.content,.blur(radius: 32))
        XCTAssertEqual(blur.rect.minX,frame.screen_dest.x,accuracy: 0.00001)
        XCTAssertEqual(blur.rect.minY,frame.screen_dest.y,accuracy: 0.00001)
        XCTAssertEqual(blur.rect.width,frame.screen_dest.w,accuracy: 0.00001)
        XCTAssertEqual(blur.rect.height,frame.screen_dest.h,accuracy: 0.00001)
        XCTAssertEqual(effects.layers.last?.opacity,0.5)
        try project.save()
        XCTAssertEqual(try Project.open(package: package).renderEffects(atNs: frame.tl_ns,canvasSize: canvas).layers,effects.layers)
        try project.apply(.set(path: "canvas.highlights",value: .array([])))
        XCTAssertEqual(try frozen.renderEffects(atNs: frame.tl_ns,canvasSize: canvas).layers,effects.layers)
        XCTAssertEqual(try project.renderEffects(atNs: frame.tl_ns,canvasSize: canvas).layers.count,1)
        XCTAssertTrue(try frozen.renderEffects(atNs: 2_000_000_000,canvasSize: canvas).layers.isEmpty)
    }
    func testLocalLensRejectsPartialPrivacyBlurLikeOpaqueCovers() throws {
        var frame=Self.frame(); frame.screen.present=1; frame.screen_crop = .init(x: 0,y: 0,w: 1,h: 1)
        var configuration=RenderConfiguration(); configuration.glassLoupe = .init()
        var mask=Self.mask()
        XCTAssertThrowsError(try validateFrame(frame,configuration: configuration,layers: [mask]))
        mask.content = .blur(radius: 0)
        XCTAssertNoThrow(try validateFrame(frame,configuration: configuration,layers: [mask]))
        mask=Self.mask(); mask.rect=CGRect(x: 0,y: 0,width: 64,height: 40); mask.cornerRadius=0
        XCTAssertNoThrow(try validateFrame(frame,configuration: configuration,layers: [mask]))
    }
    private static func frame() -> YcFrame {
        var f=YcFrame(); f.canvas_w=64; f.canvas_h=40; f.background_color=(0,0,0,1); f.click_progress = -1; return f
    }
    private static func mask(radius: Float = 4,opacity: Float = 1) -> RenderLayer {
        .init(content: .blur(radius: radius),rect: CGRect(x: 16,y: 8,width: 32,height: 24),cornerRadius: 8,opacity: opacity)
    }
    private var step: RenderLayer {
        .init(content: .highlight(dimOpacity: 0,fill: SIMD4(1,1,1,1),stroke: .zero,strokeWidth: 0),rect: CGRect(x: 32,y: 0,width: 32,height: 40))
    }
    private func source(_ layers: [RenderLayer]) -> TestSource {
        TestSource(package: root,duration: 200_000_000,layers: layers) { ns in var f=Self.frame(); f.tl_ns=ns; return f }
    }
    private func pixels(_ layers: [RenderLayer],scale: Int = 1) throws -> [UInt8] {
        let source=source(layers)
        return try RenderTests().pixels(source.frame(atNs: 0),source: source,width: 64*scale,height: 40*scale)
    }
    private func srgb(_ linear: Double) -> Double {
        255*(linear <= 0.0031308 ? linear*12.92 : 1.055*pow(linear,1/2.4)-0.055)
    }
    func testGaussianMatchesIndependentStepResponseAndKeepsOutsideAndRoundedCornersOnHost() throws {
        _ = try requireRenderDevice()
        for scale in [1,2,4] {
            let baseline=try pixels([step],scale: scale), blurred=try pixels([step,Self.mask()],scale: scale)
            let width=64*scale
            for offset in [-6,-3,0,3,6] {
                let x=(32+offset)*scale, y=20*scale
                let distance=Double(x)+0.5-Double(32*scale)
                let expected=srgb(0.5*(1+erf(distance/(Double(4*scale)*sqrt(2)))))
                XCTAssertEqual(Double(blurred[(y*width+x)*4]),expected,accuracy: 6,"Gaussian in linear light at scale\(scale), offset\(offset)")
            }
            for (x,y) in [(8,20),(56,20),(32,4),(32,36),(17,9),(47,9),(17,31),(47,31)] {
                let i=(y*scale*width+x*scale)*4
                XCTAssertEqual(Array(blurred[i..<i+4]),Array(baseline[i..<i+4]),"Outside/corner unchanged at \(x),\(y) @\(scale)")
            }
            XCTAssertEqual(try pixels([step,Self.mask(radius: 0)],scale: scale),baseline)
            XCTAssertEqual(try pixels([step,Self.mask(opacity: 0)],scale: scale),baseline)
        }
        // Real standard output sizes exercise the same canonical radius at
        // 1080p and 4K, independently of the small boundary fixture above.
        let white=RenderLayer(content: .highlight(dimOpacity: 0,fill: SIMD4(1,1,1,1),stroke: .zero,strokeWidth: 0),rect: CGRect(x: 960,y: 0,width: 960,height: 1080))
        let mask=RenderLayer(content: .blur(radius: 32),rect: CGRect(x: 480,y: 270,width: 960,height: 540),cornerRadius: 64)
        let fullSource=TestSource(package: root,layers: [white,mask]) { _ in
            var f=Self.frame(); f.canvas_w=1920; f.canvas_h=1080; return f
        }
        for scale in [1,2] {
            let width=1920*scale, image=try RenderTests().pixels(fullSource.frame(atNs: 0),source: fullSource,width: width,height: 1080*scale)
            for offset in [-64,-32,0,32,64] {
                let x=(960+offset)*scale, distance=Double(x)+0.5-Double(960*scale)
                let expected=srgb(0.5*(1+erf(distance/(Double(32*scale)*sqrt(2)))))
                XCTAssertEqual(Double(image[(540*scale*width+x)*4]),expected,accuracy: 6,"Gaussian at \(width)x\(1080*scale)")
            }
        }
    }
    func testOpacityOrderedOverlapsAndFinalFadeOnHost() throws {
        _ = try requireRenderDevice()
        let baseline=try pixels([step]), full=try pixels([step,Self.mask()]), half=try pixels([step,Self.mask(opacity: 0.5)])
        let i=(20*64+30)*4
        XCTAssertGreaterThan(half[i],baseline[i]); XCTAssertLessThan(half[i],full[i])
        let green=RenderLayer(content: .highlight(dimOpacity: 0,fill: SIMD4(0,1,0,1),stroke: .zero,strokeWidth: 0),rect: CGRect(x: 29,y: 16,width: 6,height: 8))
        let before=try pixels([step,green,Self.mask()]), after=try pixels([step,Self.mask(),green])
        XCTAssertNotEqual(before,after); XCTAssertEqual(Array(after[i..<i+4]),[0,255,0,255])
        let twice=try pixels([step,Self.mask(),Self.mask(radius: 2)])
        XCTAssertNotEqual(twice,full,"A subsequent mask samples the preceding composition, not the original frame")
        let fade=RenderLayer(content: .highlight(dimOpacity: 0,fill: SIMD4(0,0,0,1),stroke: .zero,strokeWidth: 0),rect: CGRect(x: 0,y: 0,width: 64,height: 40),opacity: 0.5)
        let faded=try pixels([step,Self.mask(),fade])
        let fullLinear=pow((Double(full[i])/255+0.055)/1.055,2.4)
        XCTAssertEqual(Double(faded[i]),srgb(fullLinear*0.5),accuracy: 2)
        // Premultiplication must preserve a flat translucent color through the
        // maximum32 ordered masks, without accumulating dark/opaque fringes.
        let masks=Array(repeating: Self.mask(),count: 32)
        func translucent(_ layers: [RenderLayer]) throws -> [UInt8] {
            let source=TestSource(package: root,layers: layers) { _ in
                var f=Self.frame(); f.background_color=(0.25,0.5,0.75,0.5); return f
            }
            return try RenderTests().pixels(source.frame(atNs: 0),source: source,width: 64,height: 40)
        }
        let flat=try translucent([]), filtered=try translucent(masks)
        for index in flat.indices { XCTAssertEqual(Double(filtered[index]),Double(flat[index]),accuracy: 1) }
    }
    @MainActor func testPreviewAndBothExportPipelineDepthsKeepTheSameBlurOnHost() async throws {
        let device=try requireRenderDevice(), source=source([step,Self.mask()])
        let preview=try PreviewPlayer(project: source)
        defer { preview.pause() }
        let width=1152,height=720
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,width: width,height: height,mipmapped: false)
        descriptor.usage = [.renderTarget,.shaderRead]
        let target=try XCTUnwrap(device.makeTexture(descriptor: descriptor)), cb=try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        try preview.compositor.encode(source.frame(atNs: 0),to: target,in: cb)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
            cb.addCompletedHandler { _ in continuation.resume() }; cb.commit()
        }
        XCTAssertEqual(cb.status,.completed)
        var expected=[UInt8](repeating: 0,count: width*height*4)
        target.getBytes(&expected,bytesPerRow: width*4,from: MTLRegionMake2D(0,0,width,height),mipmapLevel: 0)
        for depth in [1,2] {
            let url=root.appendingPathComponent("mask-depth\(depth).mp4")
            let exporter=try Exporter(project: source,settings: .init(outputHeight: height,fps: 30,includeAudio: false,compression: .studio),destination: url,videoPipelineDepth: depth)
            _ = try await exporter.run { _ in }
            let asset=AVURLAsset(url: url), reader=try AVAssetReader(asset: asset)
            let track=try XCTUnwrap(asset.tracks(withMediaType: .video).first)
            let output=AVAssetReaderTrackOutput(track: track,outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var count=0
            while let sample=output.copyNextSampleBuffer() {
                guard let pixel=CMSampleBufferGetImageBuffer(sample) else { continue }
                CVPixelBufferLockBaseAddress(pixel,.readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pixel,.readOnly) }
                let raw=try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
                for (x,y) in [(8,20),(26,20),(30,20),(32,20),(36,20),(40,20),(56,20)] {
                    for channel in 0..<3 {
                        let px=x*18,py=y*18
                        XCTAssertEqual(Double(raw[py*CVPixelBufferGetBytesPerRow(pixel)+px*4+channel]),Double(expected[(py*width+px)*4+channel]),accuracy: 10,
                                       "Preview/export match depth\(depth),frame\(count),point\(x),\(y)")
                    }
                }
                count+=1
            }
            XCTAssertEqual(reader.status,.completed); XCTAssertEqual(count,6)
        }
    }
}
