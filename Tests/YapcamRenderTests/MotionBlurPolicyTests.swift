import XCTest
@testable import YapcamRender

final class MotionBlurPolicyTests: XCTestCase {
    func testAllExportRatesScaleGlobalAndRetainedPerKindAmounts() {
        var frame=YcFrame(); frame.motion_blur=0.8
        var c=RenderConfiguration(); c.cursorMotionBlur=0.6
        for fps in ExportSettings.frameRates(for: .mp4) {
            let value=MotionBlurPolicy.strengths(frame: frame,configuration: c,framesPerSecond: fps,enabled: true)
            XCTAssertEqual(value.x,0.8*Float(fps)/60,accuracy: 0.000001)
            XCTAssertEqual(value.y,value.x)
            XCTAssertEqual(value.z,0.6*Float(fps)/60,accuracy: 0.000001)
        }
        c.zoomMotionBlur=0.2; c.panMotionBlur=0.7
        XCTAssertEqual(MotionBlurPolicy.strengths(frame: frame,configuration: c,framesPerSecond: 30,enabled: true),SIMD3(0.1,0.35,0.3))
        XCTAssertEqual(MotionBlurPolicy.strengths(frame: frame,configuration: c,framesPerSecond: 60,enabled: false),.zero)
    }
    func testScaledPanShutterAndDisabledPreviewChangeActualGhostPixelsOnHost() throws {
        let device=try requireRenderDevice()
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let source=TestSource(package: fixture) { ns in
            var f=YcFrame(); f.tl_ns=ns; f.canvas_w=320; f.canvas_h=200; f.background_color=(1,1,1,1); f.click_progress = -1
            f.screen.present=1; f.screen.segment=0; f.screen.file_ns=500_000_000
            f.screen_crop = .init(x: 0,y: 0,w: 1,h: 1)
            f.screen_dest = .init(x: ns<400_000_000 ? 50 : 100,y: 50,w: 160,h: 100)
            f.motion_blur=1
            return f
        }
        let frame=try source.frame(atNs: 400_000_000)
        let full=try FrameCompositor(device: device,project: source,framesPerSecond: 60)
        let half=try FrameCompositor(device: device,project: source,framesPerSecond: 30)
        let a=try GIFPalette.rgba(full.image(frame)), b=try GIFPalette.rgba(half.image(frame))
        full.setMotionBlurEnabled(false)
        let sharp=try GIFPalette.rgba(full.image(frame))
        func luma(_ p: [UInt8]) -> Double { let i=(100*320+65)*4; return (Double(p[i])+Double(p[i+1])+Double(p[i+2]))/3 }
        XCTAssertLessThan(luma(a),luma(b)-5)
        XCTAssertEqual(luma(b),luma(sharp),accuracy: 1)
        XCTAssertEqual(luma(sharp),255,accuracy: 1)
    }
}
