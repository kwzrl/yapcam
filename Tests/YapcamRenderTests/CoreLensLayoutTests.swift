import XCTest
import YapcamCore
@testable import YapcamRender

final class CoreLensLayoutTests: XCTestCase {
    private var package: URL!
    override func setUpWithError() throws {
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        package=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-core-lens-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: fixture,to: package)
    }
    override func tearDownWithError() throws {
        if let package { print("Cleanup render-owned lens fixture: \(package.path)"); try FileManager.default.removeItem(at: package) }
    }
    private func projectWithLens() throws -> Project {
        let p=try Project.create(package: package)
        try p.apply(.batch([
            .set(path: "canvas.output_size",value: .array([.integer(320),.integer(200)])),
            .set(path: "canvas.padding_ratio",value: .number(0)),
            .set(path: "canvas.global_motion_blur",value: .number(0))
        ]))
        var zoom=ZoomSpec(startNs: 0,endNs: 1_000_000_000,target: [112.5/320,90.5/200],scale: 2,easeInNs: 0,easeOutNs: 0)
        zoom.style="lens"; zoom.lens = .init(radius: 0.25,bevel: 0,chromaticAberration: 0)
        try p.apply(.addZoom(zoom)); return p
    }
    func testRealLensMetadataKeepsBaseCropAndFrozenAndSavedSelections() throws {
        let p=try projectWithLens(), f=try p.frame(atNs: 500_000_000)
        let canvas=CGSize(width: Int(f.canvas_w),height: Int(f.canvas_h))
        let c=try p.renderEffects(atNs: f.tl_ns,canvasSize: canvas).configuration
        let lens=try XCTUnwrap(c.glassLoupe), instruction=try XCTUnwrap(lens.instruction), core=try XCTUnwrap(p.zoomLens(atNs: f.tl_ns))
        XCTAssertEqual(instruction.center,SIMD2(Float(core.center[0]),Float(core.center[1])))
        XCTAssertEqual(instruction.sourceCenter,SIMD2(Float(core.sourceCenter[0]),Float(core.sourceCenter[1])))
        XCTAssertEqual(instruction.scale,2); XCTAssertEqual(instruction.opacity,1)
        XCTAssertEqual(lens.geometry(f).radius,Float(core.radiusPx))
        XCTAssertEqual(lens.samplingBase(f),SIMD4(0,0,1,1),"Core's local lens must retain the unzoomed source")
        try validateFrame(f,configuration: c)
        XCTAssertNil(try p.renderEffects(atNs: 1_100_000_000,canvasSize: canvas).configuration.glassLoupe)
        let snapshot=try p.renderSnapshot()
        try p.save()
        XCTAssertEqual(try Project.open(package: package).renderEffects(atNs: f.tl_ns,canvasSize: canvas).configuration,c)
        try p.apply(.set(path: "canvas.crop",value: .array([0.1,0.1,0.8,0.8].map(JSONValue.number))))
        XCTAssertEqual(try snapshot.renderEffects(atNs: f.tl_ns,canvasSize: canvas).configuration,c)
        let cropped=try p.frame(atNs: f.tl_ns)
        let selected=try p.renderEffects(atNs: f.tl_ns,canvasSize: canvas).configuration
        XCTAssertEqual(try XCTUnwrap(selected.glassLoupe).samplingBase(cropped),SIMD4(0.1,0.1,0.8,0.8))
        try validateFrame(cropped,configuration: selected)
    }
    func testCutoutEdgesAndAlreadyScaledMasterBlurReachAdapter() throws {
        let p=try Project.create(package: package)
        try p.apply(.batch([
            .set(path: "camera.layout_settings.mode",value: .string("cutout")),
            .set(path: "camera.layout_settings.edge_softness",value: .number(0.7)),
            .set(path: "camera.layout_settings.edge_inset",value: .number(3)),
            .set(path: "canvas.motion_blur",value: .number(0.8)),
            .set(path: "canvas.global_motion_blur",value: .number(0.5)),
            .addZoom(.init(startNs: 0,endNs: 2_000_000_000,scale: 2,easeInNs: 1_000_000_000,easeOutNs: 0))
        ]))
        let f=try p.frame(atNs: 50_000_000)
        let c=try p.renderEffects(atNs: f.tl_ns,canvasSize: CGSize(width: Int(f.canvas_w),height: Int(f.canvas_h))).configuration
        XCTAssertTrue(c.cameraBackgroundRemoval)
        XCTAssertEqual(c.cameraMatte,.init(edgeSoftness: 0.7,edgeInsetPixels: 3))
        XCTAssertEqual(f.motion_blur,0,accuracy: 0.000001,"A new-project zoom at timeline zero has no preceding lead-in delta")
        let evaluated=try p.frameMotion(atNs: f.tl_ns)
        let strength=MotionBlurPolicy.strengths(frame: f,configuration: c,framesPerSecond: 30,enabled: true)
        XCTAssertEqual(strength.x,evaluated.zoom_motion_blur*0.5,accuracy: 0.000001)
        XCTAssertEqual(strength.y,evaluated.pan_motion_blur*0.5,accuracy: 0.000001)
        XCTAssertEqual(strength.z,evaluated.cursor_motion_blur*0.5,accuracy: 0.000001)
        try p.apply(.set(path: "camera.layout_settings.mode",value: .string("overlay")))
        XCTAssertNil(try p.renderEffects(atNs: f.tl_ns,canvasSize: CGSize(width: Int(f.canvas_w),height: Int(f.canvas_h))).configuration.cameraMatte)
    }
    func testLocalLensActuallyMagnifiesAndKeepsOutsidePixelsOnHost() throws {
        _ = try requireRenderDevice()
        let p=try projectWithLens(); var f=try p.frame(atNs: 500_000_000); f.cursor_visible=0; f.click_progress = -1
        XCTAssertEqual(f.canvas_w,320); XCTAssertEqual(f.canvas_h,200)
        let c=try p.renderEffects(atNs: f.tl_ns,canvasSize: CGSize(width: 320,height: 200)).configuration
        var plain=c; plain.glassLoupe=nil
        let base=try RenderTests().pixels(f,source: TestSource(package: package,configuration: plain),width: 320,height: 200)
        let lens=try RenderTests().pixels(f,source: TestSource(package: package,configuration: c),width: 320,height: 200)
        XCTAssertNotEqual(lens,base)
        for (x,y) in [(10,10),(300,180),(112,90)] {
            for channel in 0..<3 { XCTAssertEqual(Double(lens[(y*320+x)*4+channel]),Double(base[(y*320+x)*4+channel]),accuracy: 2) }
        }
    }
}
