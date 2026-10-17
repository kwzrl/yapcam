import XCTest
import Metal
@testable import YapcamRender

final class CursorCompositorTests: XCTestCase {
    func testOriginalSidecarTypedReplacementVariantsAndTouchPressOnHost() throws {
        let device = try requireRenderDevice()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-cursor-gpu-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture,to: root)
        defer { print("Cleanup render-owned cursor fixture: \(root.lastPathComponent)"); try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("recording/seg-000/cursors.json")
        try Data(#"{"1":{"file":"cursors/1.png","hotspot":[5,7],"size_points":[16,24],"shape":"text"}}"#.utf8).write(to: metadata)
        let compositor = try FrameCompositor(device: device,project: TestSource(package: root))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let target = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,width: 192,height: 144,mipmapped: false)))
        func render(_ configuration: RenderConfiguration,click: Float = -1,scale: Float = 1.75) throws -> Data {
            let source = TestSource(package: root,configuration: configuration) { ns in
                var frame = YcFrame(); frame.tl_ns = ns; frame.canvas_w = 192; frame.canvas_h = 144
                frame.background_color = (0.2,0.2,0.2,1); frame.click_progress = click
                frame.cursor_visible = 1; frame.cursor_opacity = 1; frame.cursor_scale = scale; frame.cursor_id = 1; frame.screen.segment = 0
                frame.cursor_x = 84; frame.cursor_y = 58; frame.click_x = 84; frame.click_y = 58
                return frame
            }
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            try compositor.encode(source.frame(atNs: 0),from: source,to: target,in: command)
            command.commit(); command.waitUntilCompleted(); XCTAssertEqual(command.status,.completed,command.error?.localizedDescription ?? "")
            var pixels = [UInt8](repeating: 0,count: 192*144*4)
            target.getBytes(&pixels,bytesPerRow: 192*4,from: MTLRegionMake2D(0,0,192,144),mipmapLevel: 0)
            return Data(pixels)
        }
        let legacy = try render(.init(),scale: 0.75)
        var c = RenderConfiguration(); c.cursorSetID = "original"; c.cursorStyle = .crosshair
        XCTAssertEqual(try render(c,scale: 0.75),legacy,"Original keeps native-sized captured artwork and its nonzero hotspot")
        let enlarged=try render(c,scale: 8)
        c.cursorUseDefaultIfAppHasLowResolution=false
        XCTAssertNotEqual(try render(c,scale: 8),enlarged,"Enlarged typed low-res art must use our sharp equivalent")
        c.cursorUseDefaultIfAppHasLowResolution=true
        c.cursorSetID = "paper"; c.cursorStyle = .recorded
        let typed = try render(c)
        c.cursorStyle = .text
        XCTAssertEqual(try render(c),typed,"Optional sidecar shape selects the matching set type")
        c.cursorVariants = ["text": .alternate]
        XCTAssertNotEqual(try render(c),typed,"Variant must participate in the GPU cache key")
        c.cursorSetID = "touch"; c.cursorVariants = [:]; c.cursorStyle = .arrow
        let released = try render(c)
        c.cursorStyle = .notAllowed
        XCTAssertEqual(try render(c),released,"Touch never becomes an arrow or a recorded-type glyph")
        c.cursorPressed = true
        let pressed = try render(c) // Click ring disabled: only the sprite changes.
        let center = (58*192+84)*4
        XCTAssertNotEqual(released.subdata(in: center..<center+3),pressed.subdata(in: center..<center+3),"Press changes the circle center, independently of the outer click ring")
        c.cursorPressed = false
        XCTAssertEqual(try render(c),released,"Releasing must reuse the correct unpressed texture")
        for style in [VectorCursorStyle.crosshair,.notAllowed] {
            c.cursorSetID = "classic"; c.cursorStyle = .init(style); c.cursorVariants = [:]
            let standard = try render(c)
            c.cursorVariants = [style.shapeID: .alternate]
            XCTAssertNotEqual(try render(c),standard)
        }
    }
}
