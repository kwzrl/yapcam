import XCTest
import YapcamCore
@testable import YapcamRender

final class MotionProjectTests: XCTestCase {
    func testRealCoreMotionAndDefaultArrowUseOneImmutableGeneration() throws {
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let package=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-motion-project-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: fixture,to: package)
        defer { try? FileManager.default.removeItem(at: package) }
        let project=try Project.create(package: package)
        try project.apply(.batch([
            .set(path: "cursor.style",value: .string("touch")),
            .set(path: "cursor.always_default",value: .bool(true)),
            .set(path: "cursor.rotate_on_move",value: .bool(true)),
            .set(path: "cursor.motion_blur",value: .number(0.6)),
            .set(path: "canvas.animation.entrance",value: .string("slide_left")),
            .set(path: "canvas.animation.entrance_duration_ns",value: .integer(500_000_000)),
            .set(path: "canvas.motion_blur_settings.pan",value: .number(0.8)),
            .set(path: "canvas.motion_blur_settings.zoom",value: .number(0))
        ]))
        let source=try project.renderSnapshot()
        let frame=try source.frame(atNs: 200_000_000)
        let options=try source.renderEffects(atNs: frame.tl_ns,canvasSize: .zero).configuration
        let motion=try project.frameMotion(atNs: frame.tl_ns)
        XCTAssertGreaterThan(abs(motion.cursor_rotation_rad),0,"Moving cursor receives evaluated tilt")
        XCTAssertEqual(frame.cursor_id,0)
        XCTAssertEqual(options.cursorStyle,.arrow,"Core pointer means default system arrow, including always_default")
        XCTAssertEqual(options.cursorRotationRadians,motion.cursor_rotation_rad)
        XCTAssertEqual(options.cursorMotionBlur,motion.cursor_motion_blur)
        XCTAssertEqual(options.zoomMotionBlur,0)
        XCTAssertEqual(options.panMotionBlur,0.8)
        let still=try source.renderEffects(atNs: 800_000_000,canvasSize: .zero).configuration
        XCTAssertEqual(still.panMotionBlur,0,"Static plateau has no velocity trail")
        try project.apply(.set(path: "canvas.motion_blur_settings.pan",value: .number(0)))
        XCTAssertEqual(try source.renderEffects(atNs: frame.tl_ns,canvasSize: .zero).configuration,options)
        XCTAssertEqual(try project.renderEffects(atNs: frame.tl_ns,canvasSize: .zero).configuration.panMotionBlur,0)
        var invalid=RenderConfiguration(); invalid.cursorRotationRadians = .nan
        XCTAssertThrowsError(try validateFrame(frame,configuration: invalid))
        invalid = .init(); invalid.zoomMotionBlur=1.1
        XCTAssertThrowsError(try validateFrame(frame,configuration: invalid))
    }
    func testCursorTiltChangesPixelsAroundTheSameHotspot() throws {
        _ = try requireRenderDevice()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-tilt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recording"),withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"segments\":[]}".utf8).write(to: root.appendingPathComponent("recording/session.json"))
        func pixels(_ angle: Float) throws -> [UInt8] {
            var config=RenderConfiguration(); config.cursorStyle = .arrow; config.cursorRotationRadians=angle
            let source=TestSource(package: root,configuration: config) { ns in
                var f=YcFrame(); f.tl_ns=ns; f.canvas_w=128; f.canvas_h=96; f.background_color=(0,0,0,1)
                f.cursor_visible=1; f.cursor_opacity=1; f.cursor_x=64; f.cursor_y=40; f.cursor_scale=1; f.click_progress = -1
                return f
            }
            return try RenderTests().pixels(source.frame(atNs: 100_000_000),source: source,width: 128,height: 96)
        }
        let straight=try pixels(0), tilted=try pixels(.pi/12)
        XCTAssertNotEqual(straight,tilted)
        XCTAssertEqual(try pixels(.pi/12),tilted,"Backward/random seeking does not accumulate rotation")
        for bytes in [straight,tilted] { XCTAssertGreaterThan(bytes[(40*128+64)*4],20,"Rotation keeps the visible hotspot anchored") }
    }
    func testSeparatePanBlurIncludesMovingScreenEdgesAndZoomGateStaysSharp() throws {
        _ = try requireRenderDevice()
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        func pixels(zoom: Float,pan: Float) throws -> [UInt8] {
            var config=RenderConfiguration(); config.zoomMotionBlur=zoom; config.panMotionBlur=pan
            let source=TestSource(package: fixture,configuration: config) { ns in
                var f=YcFrame(); f.tl_ns=ns; f.canvas_w=320; f.canvas_h=200; f.background_color=(0,0,0,1)
                f.screen.present=1; f.screen.segment=0; f.screen.file_ns=100_000_000
                f.screen_dest=YcRect(x: ns<100_000_000 ? 40 : 50,y: 20,w: 240,h: 150)
                f.screen_crop=YcRect(x: 0,y: 0,w: 1,h: 1); f.click_progress = -1
                return f
            }
            return try RenderTests().pixels(source.frame(atNs: 100_000_000),source: source,width: 320,height: 200)
        }
        let sharp=try pixels(zoom: 0,pan: 0)
        XCTAssertEqual(try pixels(zoom: 1,pan: 0),sharp,"Center-only movement must not activate zoom blur")
        let blurred=try pixels(zoom: 0,pan: 1)
        XCTAssertNotEqual(blurred,sharp)
        let outside=(70*320+45)*4
        XCTAssertLessThan(sharp[outside],3)
        XCTAssertGreaterThan(blurred[outside],5,"Moving edge contributes outside the current rectangle")
    }
}
