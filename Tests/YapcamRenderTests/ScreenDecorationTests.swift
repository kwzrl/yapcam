import XCTest
import YapcamCore
@testable import YapcamRender

final class ScreenDecorationTests: XCTestCase {
    private var fixture: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam") }
    func testCoreDirectionalAndClassicOffsetsMapThroughSnapshotsAndSave() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-shadow-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: fixture,to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let project=try Project.create(package: root)
        try project.apply(.batch([
            .set(path: "canvas.shadow.style",value: .string("directional")),
            .set(path: "canvas.shadow.distance",value: .number(32)),
            .set(path: "canvas.shadow.blur",value: .number(2)),
            .set(path: "canvas.shadow.opacity",value: .number(0.5))
        ]))
        for (angle,x,y): (Double,Double,Double) in [(0,32,0),(45,32/sqrt(2),32/sqrt(2)),(90,0,32),(180,-32,0)] {
            try project.apply(.set(path: "canvas.shadow.angle_deg",value: .number(angle)))
            let frozen=try project.renderSnapshot()
            for source in [project as any RenderProjectSource,frozen] {
                let f=try source.frame(atNs: 0)
                let c=try source.renderEffects(atNs: 0,canvasSize: CGSize(width: Int(f.canvas_w),height: Int(f.canvas_h))).configuration
                XCTAssertEqual(Double(c.screenShadowOffsetX),x,accuracy: 0.00001)
                XCTAssertEqual(Double(f.shadow_offset_y),y,accuracy: 0.00001)
                XCTAssertEqual(f.shadow_radius,16); XCTAssertEqual(f.shadow_opacity,0.5)
            }
        }
        try project.apply(.batch([
            .set(path: "canvas.shadow.radius",value: .number(8)),
            .set(path: "canvas.shadow.offset_y",value: .number(12))
        ]))
        try project.save()
        for source in [project,try Project.open(package: root)] {
            let c=try source.renderEffects(atNs: 0,canvasSize: CGSize(width: 1728,height: 1080)).configuration
            XCTAssertEqual(c.screenShadowOffsetX,0,"Legacy radius/y edits select classic")
            XCTAssertEqual(try source.frame(atNs: 0).shadow_radius,8)
            XCTAssertEqual(try source.frame(atNs: 0).shadow_offset_y,12)
        }
    }
    func testInsetQueryDefaultsAndDecorationValidation() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-inset-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: fixture,to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let project=try Project.create(package: root)
        var json=try project.query("{\"q\":\"render_options_at\",\"tl_ns\":0}",as: [String:JSONValue].self)
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertEqual(try decoder.decode(ProjectRenderOptions.self,from: JSONEncoder().encode(json)).insetOrigin,.zero)
        json.removeValue(forKey: "inset_origin")
        XCTAssertNil(try decoder.decode(ProjectRenderOptions.self,from: JSONEncoder().encode(json)).insetOrigin,"Older query payloads still inherit centered rendering")
        json["inset_origin"] = .array([.number(1),.number(-0.5)])
        XCTAssertEqual(try decoder.decode(ProjectRenderOptions.self,from: JSONEncoder().encode(json)).insetOrigin,SIMD2(1,-0.5))
        let f=try project.frame(atNs: 0)
        for value in [SIMD2<Float>(2,0),SIMD2(0,-2),SIMD2(.nan,0)] {
            var c=RenderConfiguration(); c.screenInsetOrigin=value
            XCTAssertThrowsError(try validateFrame(f,configuration: c))
        }
        var c=RenderConfiguration(); c.screenShadowOffsetX = .infinity
        XCTAssertThrowsError(try validateFrame(f,configuration: c))
    }
    func testDirectionalShadowMovesToOppositeSidesAndClassicRetainsVerticalOffsetOnHost() throws {
        _ = try requireRenderDevice()
        var f=frame(); f.shadow_radius=10; f.shadow_opacity=0.5
        var c=RenderConfiguration(); c.screenShadowOffsetX=30
        let right=try pixels(f,c)
        c.screenShadowOffsetX = -30
        let left=try pixels(f,c)
        XCTAssertLessThan(luminance(right,x: 260,y: 100),luminance(left,x: 260,y: 100)-20)
        XCTAssertLessThan(luminance(left,x: 60,y: 100),luminance(right,x: 60,y: 100)-20)
        f.shadow_offset_y=12; c.screenShadowOffsetX=0
        let classic=try pixels(f,c)
        XCTAssertLessThan(luminance(classic,x: 160,y: 165),luminance(classic,x: 160,y: 35)-10)
    }
    func testInsetBiasWeightsOppositeEdgesAndOpacityBlendsOnHost() throws {
        _ = try requireRenderDevice()
        var f=frame(); f.inset_width=10; f.inset_color=(0,0,0,1)
        var c=RenderConfiguration()
        let centered=try pixels(f,c)
        c.screenInsetOrigin=SIMD2(1,0)
        let biased=try pixels(f,c)
        func average(_ image: [UInt8],_ x: Int) -> Double { (70...130).map { luminance(image,x: x,y: $0) }.reduce(0,+)/61 }
        XCTAssertLessThan(average(biased,225),average(centered,225)-10)
        XCTAssertGreaterThan(average(biased,85),average(centered,85)+10)
        f.inset_color=(0,0,0,0.5)
        let translucent=try pixels(f,c)
        XCTAssertGreaterThan(average(translucent,225),average(biased,225)+10)
        XCTAssertLessThan(average(translucent,225),average(centered,225)-5)
    }
    private func frame() -> YcFrame {
        var f=YcFrame(); f.canvas_w=320; f.canvas_h=200; f.background_color=(1,1,1,1); f.click_progress = -1
        f.screen.present=1; f.screen.segment=0; f.screen.file_ns=500_000_000
        f.screen_crop = .init(x: 0,y: 0,w: 1,h: 1); f.screen_dest = .init(x: 80,y: 50,w: 160,h: 100)
        f.screen_corner_radius=12
        return f
    }
    private func pixels(_ f: YcFrame,_ c: RenderConfiguration) throws -> [UInt8] {
        try RenderTests().pixels(f,source: TestSource(package: fixture,configuration: c),width: 320,height: 200)
    }
    private func luminance(_ pixels: [UInt8],x: Int,y: Int) -> Double {
        let i=(y*320+x)*4
        return (Double(pixels[i])+Double(pixels[i+1])+Double(pixels[i+2]))/3
    }
}
