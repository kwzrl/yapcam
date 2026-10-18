import XCTest
import YapcamCore
import AVFoundation
import MetalKit
@testable import YapcamRender

final class CoreCameraStyleTests: XCTestCase {
    private var package: URL!
    override func setUpWithError() throws {
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        package=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-core-camera-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: fixture,to: package)
    }
    override func tearDownWithError() throws {
        if let package { print("Cleanup render-owned camera fixture: \(package.path)"); try FileManager.default.removeItem(at: package) }
    }
    private func configuration(_ project: Project) throws -> RenderConfiguration {
        let f=try project.frame(atNs: 0)
        return try project.renderEffects(atNs: 0,canvasSize: CGSize(width: Int(f.canvas_w),height: Int(f.canvas_h))).configuration
    }
    func testCoreRippleContractMapsKindDurationAndSnapshot() throws {
        let project=try Project.create(package: package)
        try project.apply(.set(path: "cursor.click_effect",value: .string("highlight")))
        let selected=try configuration(project)
        XCTAssertEqual(selected.cursorClickEffect,.ripple)
        XCTAssertEqual(selected.cursorClickDurationNs,450_000_000,"Ripple has three 450 ms rings regardless of Circle's legacy timing")
        let snapshot=try project.renderSnapshot()
        try project.apply(.set(path: "cursor.click_effect",value: .string("ring")))
        XCTAssertEqual(try configuration(project).cursorClickEffect,.circle)
        XCTAssertEqual(try configuration(project).cursorClickDurationNs,400_000_000,"Circle retains today's single-ring timing")
        XCTAssertGreaterThan(try snapshot.frame(atNs: 2_250_000_000).click_progress,0,"Ripple's 590 ms total clock keeps the final ring alive")
        XCTAssertEqual(try snapshot.frame(atNs: 2_300_000_000).click_progress,-1)
        XCTAssertEqual(try project.frame(atNs: 2_250_000_000).click_progress,-1,"Circle remains finished after its 400 ms lifetime")
        let frame=try snapshot.frame(atNs: 0)
        let frozen=try snapshot.renderEffects(atNs: 0,canvasSize: CGSize(width: Int(frame.canvas_w),height: Int(frame.canvas_h))).configuration
        XCTAssertEqual(frozen.cursorClickEffect,.ripple)
        XCTAssertEqual(frozen.cursorClickDurationNs,450_000_000)
    }
    func testOptionalLayoutEffectsDecodeStrictlyAndKeepLegacyDefaults() throws {
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let legacy=try decoder.decode(ProjectRenderOptions.self,from: Data("{}".utf8))
        XCTAssertNil(legacy.cameraSourceCrop); XCTAssertNil(legacy.screenOpacity); XCTAssertNil(legacy.cameraBlur)
        XCTAssertNil(legacy.cursorClickEffect); XCTAssertNil(legacy.cursorClickDurationNs)
        let selected=try decoder.decode(ProjectRenderOptions.self,from: Data(#"{"camera_source_crop":[0,0.125,1,0.75],"screen_opacity":0.25,"camera_blur":0.75,"cursor_click_effect":"highlight","cursor_click_duration_ns":450000000}"#.utf8))
        XCTAssertEqual(selected.cameraSourceCrop,SIMD4(0,0.125,1,0.75))
        XCTAssertEqual(selected.screenOpacity,0.25); XCTAssertEqual(selected.cameraBlur,0.75)
        XCTAssertEqual(selected.cursorClickEffect,.ripple); XCTAssertEqual(selected.cursorClickDurationNs,450_000_000)
        for json in [
            #"{"camera_source_crop":[0,0,1]}"#,
            #"{"camera_source_crop":[0,0,1,"bad"]}"#,
            #"{"camera_source_crop":[-0.1,0,1,1]}"#,
            #"{"camera_source_crop":[0.1,0,1,1]}"#,
            #"{"screen_opacity":-0.01}"#,
            #"{"screen_opacity":1.01}"#,
            #"{"camera_blur":-0.01}"#,
            #"{"camera_blur":1.01}"#,
            #"{"cursor_click_effect":"unknown"}"#,
            #"{"cursor_click_duration_ns":0}"#
        ] {
            XCTAssertThrowsError(try decoder.decode(ProjectRenderOptions.self,from: Data(json.utf8)),json)
        }
    }
    func testEveryCoreRecipeOriginalBypassSnapshotAndSaveReopen() throws {
        let project=try Project.create(package: package)
        let original=try configuration(project)
        XCTAssertFalse(original.cameraColor.isEnabled,"Core's stored original-mode tone defaults must remain inactive")
        XCTAssertEqual(original.cameraBackgroundPop,0)
        XCTAssertEqual(original.cameraCrop,SIMD4(0,0,1,1))
        let recipes=try project.cameraStyleLibrary()
        XCTAssertEqual(recipes.count,12)
        for recipe in recipes {
            try project.apply(.set(path: "camera.style.preset",value: .string(recipe.id)))
            let c=try configuration(project)
            XCTAssertNil(c.cameraColor.presetID,"Core recipes supply their evaluated scalar values, not Render palette IDs")
            XCTAssertEqual(c.cameraColor.warmth,Float(recipe.warmth))
            XCTAssertEqual(c.cameraColor.contrast,Float(recipe.contrast))
            XCTAssertEqual(c.cameraColor.colorIntensity,Float(recipe.colorIntensity))
            XCTAssertEqual(c.cameraBackgroundPop,Float(recipe.backgroundPop))
            try validateFrame(project.frame(atNs: 0),configuration: c)
        }
        try project.apply(.batch([
            .set(path: "camera.style.intensity",value: .number(0.5)),
            .set(path: "camera.style.crop",value: .array([0.1,0.2,0.7,0.6].map(JSONValue.number))),
            .set(path: "camera.style.background_blur",value: .number(0.3)),
            .set(path: "camera.style.sharpen",value: .number(0.2))
        ]))
        let selected=try configuration(project), frozen=try project.renderSnapshot()
        XCTAssertEqual(selected.cameraCrop,SIMD4(0.1,0.2,0.7,0.6))
        XCTAssertEqual(selected.cameraBackgroundBlur,0.3)
        XCTAssertEqual(selected.cameraColor.intensity,0.5)
        try project.save()
        XCTAssertEqual(try configuration(Project.open(package: package)),selected)
        try project.apply(.set(path: "camera.style.preset",value: .string("original")))
        let reset=try configuration(project)
        XCTAssertEqual(reset.cameraColor.contrast,0); XCTAssertEqual(reset.cameraBackgroundPop,0)
        XCTAssertEqual(reset.cameraColor.sharpen,0.2,"Original disables grading, not independent sharpen/crop controls")
        XCTAssertEqual(try frozen.renderEffects(atNs: 0,canvasSize: CGSize(width: 1728,height: 1080)).configuration,selected)
    }
    func testCoreRegisteredLUTUsesLocalPathAndDoesNotApplyInactiveToneDefaults() throws {
        let project=try Project.create(package: package)
        var text="LUT_3D_SIZE 2\n"
        for b in 0...1 { for g in 0...1 { for r in 0...1 { text += "\(r) \(g) \(b)\n" } } }
        // Core accepts 32MiB; a valid table with a long comment must also render.
        let bytes=Data((text+"#"+String(repeating: "x",count: 16*1024*1024)+"\n").utf8)
        let selected=package.appendingPathComponent("selected.cube")
        try bytes.write(to: selected)
        try project.importCameraLUT(from: selected)
        let c=try configuration(project), url=try XCTUnwrap(c.cameraColor.lutURL)
        XCTAssertNotEqual(url,selected); XCTAssertTrue(url.path.hasPrefix(package.path+"/assets/"))
        XCTAssertEqual(c.cameraColor.warmth,0); XCTAssertEqual(c.cameraColor.contrast,0)
        XCTAssertEqual(c.cameraBackgroundPop,0)
        let table=try YapcamRender.CubeLUT(contentsOf: url)
        XCTAssertEqual(try table.sample(SIMD3(0.25,0.5,0.75)),SIMD3(0.25,0.5,0.75))
        XCTAssertEqual(try Data(contentsOf: selected),bytes)
        try project.undo()
        XCTAssertNil(try configuration(project).cameraColor.lutURL)
    }
    func testInvalidCameraGeometryAndBackgroundValuesAreRejected() throws {
        var f=YcFrame(); f.canvas_w=320; f.canvas_h=200; f.background_color=(0,0,0,1); f.click_progress = -1
        var c=RenderConfiguration()
        for crop in [SIMD4<Float>(.nan,0,1,1),SIMD4(-0.1,0,1,1),SIMD4(0.5,0,0.6,1),SIMD4(0,0,0,1)] {
            c.cameraCrop=crop; XCTAssertThrowsError(try validateFrame(f,configuration: c))
        }
        c.cameraCrop=SIMD4(0,0,1,1)
        c.cameraBackgroundPop = .nan; XCTAssertThrowsError(try validateFrame(f,configuration: c))
        c.cameraBackgroundPop=0; c.cameraBackgroundBlur=2; XCTAssertThrowsError(try validateFrame(f,configuration: c))
        c.cameraBackgroundBlur=0; c.screenOpacity = -0.1; XCTAssertThrowsError(try validateFrame(f,configuration: c))
        c.screenOpacity=1; c.cameraBlur = 1.1; XCTAssertThrowsError(try validateFrame(f,configuration: c))
        c.cameraBlur=0; c.cursorClickDurationNs = 0; XCTAssertThrowsError(try validateFrame(f,configuration: c))
    }
    func testCameraCropChangesSourceRegionOnHost() throws {
        _ = try requireRenderDevice()
        let session=package.appendingPathComponent("recording/session.json")
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: session)) as? [String:Any])
        var segments=try XCTUnwrap(json["segments"] as? [[String:Any]])
        var files=try XCTUnwrap(segments[0]["files"] as? [String:String]); files["camera"]=files["screen"]; segments[0]["files"]=files; json["segments"]=segments
        try JSONSerialization.data(withJSONObject: json).write(to: session)
        var f=YcFrame(); f.canvas_w=320; f.canvas_h=200; f.background_color=(0,0,0,1); f.click_progress = -1
        f.camera.present=1; f.camera.segment=0; f.camera.file_ns=500_000_000; f.camera_dest = .init(x: 0,y: 0,w: 320,h: 200); f.camera_opacity=1
        let full=try RenderTests().pixels(f,source: TestSource(package: package),width: 320,height: 200)
        var c=RenderConfiguration(); c.cameraCrop=SIMD4(0.25,0.25,0.5,0.5)
        let cropped=try RenderTests().pixels(f,source: TestSource(package: package,configuration: c),width: 160,height: 100)
        // Half-size output gives an exact 1:1 sample grid for the selected source quarter.
        for (x,y) in [(10,10),(80,50),(140,80)] {
            for channel in 0..<3 { XCTAssertEqual(Double(cropped[(y*160+x)*4+channel]),Double(full[((50+y)*320+80+x)*4+channel]),accuracy: 2) }
        }
    }
    func testLayoutTransitionScreenFadeAndCameraBlurChangePixelsOnHost() throws {
        _ = try requireRenderDevice()
        let session=package.appendingPathComponent("recording/session.json")
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: session)) as? [String:Any])
        var segments=try XCTUnwrap(json["segments"] as? [[String:Any]])
        var files=try XCTUnwrap(segments[0]["files"] as? [String:String]); files["camera"]=files["screen"]; segments[0]["files"]=files; json["segments"]=segments
        try JSONSerialization.data(withJSONObject: json).write(to: session)

        var screen=YcFrame(); screen.canvas_w=320; screen.canvas_h=200; screen.background_color=(0.02,0.02,0.02,1); screen.click_progress = -1
        screen.screen.present=1; screen.screen.segment=0; screen.screen.file_ns=500_000_000
        screen.screen_dest = .init(x: 0,y: 0,w: 320,h: 200); screen.screen_crop = .init(x: 0,y: 0,w: 1,h: 1)
        var visible=RenderConfiguration(); visible.screenOpacity=1
        visible.glassLoupe=GlassLoupeSettings(instruction: .init(center: SIMD2(160,100),sourceCenter: SIMD2(0.5,0.5),scale: 2,radiusPixels: 60,opacity: 1))
        var hidden=visible; hidden.screenOpacity=0
        let visiblePixels=try RenderTests().pixels(screen,source: TestSource(package: package,configuration: visible),width: 320,height: 200)
        let hiddenPixels=try RenderTests().pixels(screen,source: TestSource(package: package,configuration: hidden),width: 320,height: 200)
        XCTAssertNotEqual(visiblePixels,hiddenPixels,"Fullscreen transitions must fade the screen layer")
        var background=screen; background.screen.present=0; background.screen_dest = .init()
        let backgroundPixels=try RenderTests().pixels(background,source: TestSource(package: package),width: 320,height: 200)
        XCTAssertEqual(hiddenPixels,backgroundPixels,"Screen opacity zero must also hide an overlapping glass lens and its shadow")

        var camera=screen; camera.screen.present=0; camera.screen_dest = .init()
        camera.camera.present=1; camera.camera.segment=0; camera.camera.file_ns=500_000_000
        camera.camera_dest = .init(x: 0,y: 0,w: 320,h: 200); camera.camera_opacity=1
        var sharp=RenderConfiguration(); sharp.cameraBlur=0
        var blurred=sharp; blurred.cameraBlur=1
        let sharpPixels=try RenderTests().pixels(camera,source: TestSource(package: package,configuration: sharp),width: 320,height: 200)
        let blurredPixels=try RenderTests().pixels(camera,source: TestSource(package: package,configuration: blurred),width: 320,height: 200)
        XCTAssertNotEqual(sharpPixels,blurredPixels,"Hidden-camera transitions must ramp camera blur")
    }
    func testCameraBlurFiltersOnlySelectedSourcePixelsOnHost() throws {
        let device=try requireRenderDevice()
        var cache: CVMetalTextureCache?, pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVMetalTextureCacheCreate(nil,nil,device,nil,&cache),kCVReturnSuccess)
        XCTAssertEqual(CVPixelBufferCreate(nil,64,40,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,&pixelBuffer),kCVReturnSuccess)
        let buffer=try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer,[])
        let bytes=try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self), stride=CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<40 { for x in 0..<64 {
            let i=y*stride+x*4, value: UInt8=(x+y)%2==0 ? 100 : 160
            bytes[i]=x<16 ? 255 : value; bytes[i+1]=x<16 ? 0 : value; bytes[i+2]=x<16 ? 255 : value; bytes[i+3]=255
        } }
        CVPixelBufferUnlockBaseAddress(buffer,[])
        let source=try TextureFrame(buffer: buffer,cache: XCTUnwrap(cache),time: .zero)
        let blur=try BackgroundBlur(device: device), queue=try XCTUnwrap(device.makeCommandQueue())
        func values(radius: Float) throws -> [Float] {
            let cb=try XCTUnwrap(queue.makeCommandBuffer())
            let texture=try blur.encode(source: source,canvas: SIMD2(48,40),radius: radius,crop: SIMD4(0.25,0,0.75,1),in: cb)
            let pitch=(texture.width*8+255)/256*256
            let output=try XCTUnwrap(device.makeBuffer(length: pitch*texture.height,options: .storageModeShared))
            let blit=try XCTUnwrap(cb.makeBlitCommandEncoder())
            blit.copy(from: texture,sourceSlice: 0,sourceLevel: 0,sourceOrigin: .init(x: 0,y: 0,z: 0),sourceSize: .init(width: texture.width,height: texture.height,depth: 1),to: output,destinationOffset: 0,destinationBytesPerRow: pitch,destinationBytesPerImage: pitch*texture.height)
            blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            XCTAssertEqual(cb.status,.completed,cb.error?.localizedDescription ?? "")
            let samples=output.contents().assumingMemoryBound(to: Float16.self)
            var result: [Float]=[]
            for y in 0..<texture.height { for x in 0..<texture.width {
                let i=y*(pitch/2)+x*4, r=Float(samples[i]), g=Float(samples[i+1]), b=Float(samples[i+2])
                XCTAssertEqual(r,g,accuracy: 0.0001,"Hidden pink pixels must not leak across selected crop")
                XCTAssertEqual(r,b,accuracy: 0.0001)
                result.append(r)
            } }
            return result
        }
        func variance(_ values: [Float]) -> Float {
            let mean=values.reduce(0,+)/Float(values.count)
            return values.map { ($0-mean)*($0-mean) }.reduce(0,+)/Float(values.count)
        }
        let sharp=try values(radius: 0), softened=try values(radius: 4)
        XCTAssertGreaterThan(variance(sharp),0.001)
        XCTAssertLessThan(variance(softened),variance(sharp)*0.1)
    }
}
