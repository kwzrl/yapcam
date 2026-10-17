import XCTest
import YapcamCore
@testable import YapcamRender

final class LayerPurposeTests: XCTestCase {
    private func layer(_ purpose: String? = nil,kind: String = "highlight",dim: Double = 0) throws -> RenderLayer {
        var row: [String: Any]=[
            "id":"core:caption:example:background","kind":kind,"rect":[20,20,100,30],
            "corner_radius":8,"opacity":1,"dim_opacity":dim,"fill":[0,0,0,1],
            "stroke":[0,0,0,0],"stroke_width":0
        ]
        row["purpose"]=purpose
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CoreDrawingLayer.self,from: JSONSerialization.data(withJSONObject: row)).drawingLayer()
    }
    private var frame: YcFrame {
        var f=YcFrame(); f.canvas_w=320; f.canvas_h=200; f.click_progress = -1
        f.screen.present=1; f.screen_dest = .init(x: 0,y: 0,w: 320,h: 200)
        f.screen_crop = .init(x: 0,y: 0,w: 1,h: 1)
        return f
    }
    private var configuration: RenderConfiguration {
        var c=RenderConfiguration()
        c.glassLoupe = .init(instruction: .init(center: SIMD2(160,100),sourceCenter: SIMD2(0.5,0.5),scale: 2,radiusPixels: 60,opacity: 1))
        return c
    }

    func testPurposeDecodesLenientlyWhenAbsentButRejectsUnknownOrUnsafeTags() throws {
        XCTAssertEqual(try layer().purpose,.unspecified)
        XCTAssertEqual(try layer("text_background").purpose,.textBackground)
        XCTAssertEqual(try layer("privacy_mask").purpose,.privacyMask)
        XCTAssertThrowsError(try layer("unknown"))
        XCTAssertThrowsError(try layer("text_background",kind: "blur"))
        XCTAssertThrowsError(try layer("text_background",dim: 0.5))
    }

    func testExplicitTextBackgroundCoexistsWithLensWhileMasksFailClosed() throws {
        let captionBackground=try layer("text_background")
        XCTAssertNoThrow(try validateFrame(frame,configuration: configuration,layers: [captionBackground]))
        // A familiar-looking ID is not sufficient permission to expose pixels.
        XCTAssertThrowsError(try validateFrame(frame,configuration: configuration,layers: [layer()]))
        var mask=try layer("privacy_mask")
        XCTAssertThrowsError(try validateFrame(frame,configuration: configuration,layers: [captionBackground,mask]))
        mask.opacity=0.25
        XCTAssertThrowsError(try validateFrame(frame,configuration: configuration,layers: [mask]),"Partially opaque privacy covers still need source-space handling")
        mask.opacity=0
        XCTAssertNoThrow(try validateFrame(frame,configuration: configuration,layers: [mask]))
        mask.opacity=1; mask.content = .blur(radius: 16)
        XCTAssertThrowsError(try validateFrame(frame,configuration: configuration,layers: [mask]))
        mask.purpose = .textBackground
        XCTAssertThrowsError(try validateFrame(frame,configuration: configuration,layers: [mask]),"A bad tag cannot bypass blur protection")
        mask.purpose = .privacyMask
        mask.content = .highlight(dimOpacity: 0.5,fill: .zero,stroke: .zero,strokeWidth: 0)
        XCTAssertThrowsError(try validateFrame(frame,configuration: configuration,layers: [mask]),"Source masking is needed for explicit outside dimming too")
        mask.content = .image(relativePath: "private.png")
        XCTAssertThrowsError(try validateFrame(frame,configuration: configuration,layers: [mask]),"An unsupported mask tag must not silently render as an ordinary image")
    }

    func testPurposeDoesNotChangeBackgroundPixelsOnHost() throws {
        _ = try requireRenderDevice()
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let background=try layer("text_background")
        let source=TestSource(package: fixture,layers: [background],configuration: configuration)
        let untagged=try layer()
        let baseline=TestSource(package: fixture,layers: [untagged],configuration: configuration)
        var f=frame
        f.screen_crop = .init(x: 0.25,y: 0.25,w: 0.5,h: 0.5)
        // With no lens both roles must produce identical legacy pixels.
        let noLensA=TestSource(package: fixture,layers: [background])
        let noLensB=TestSource(package: fixture,layers: [untagged])
        let renderer=RenderTests()
        XCTAssertEqual(try renderer.pixels(f,source: noLensA),try renderer.pixels(f,source: noLensB))
        XCTAssertThrowsError(try renderer.pixels(f,source: baseline))
        let pixels=try renderer.pixels(f,source: source,width: 320,height: 200)
        let interior=(30*320+30)*4
        XCTAssertEqual(Array(pixels[interior..<interior+4]),[0,0,0,255],"The opaque caption background is drawn over the lens")
    }
}
