import XCTest
import YapcamCore
@testable import YapcamRender

final class CoreDrawingLayerTests: XCTestCase {
    func decode(_ kind: String = "text",text: String? = "Hello ⌘K 😀",color: [Float] = [1,1,1,0.5]) throws -> CoreDrawingLayer {
        var value: [String: Any]=["kind":kind,"rect":[16,8,128,48],"corner_radius":12,"opacity":0.8,"dim_opacity":0,"fill":[0,0,0,0.65],"stroke":[0,0,0,0],"stroke_width":0,"font_size":36,"color":color]
        if let text { value["text"]=text }
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CoreDrawingLayer.self,from: JSONSerialization.data(withJSONObject: value))
    }
    func testEvaluatedTextPayloadPreservesGeometryUnicodeColorAndOpacity() throws {
        let layer=try decode().drawingLayer()
        XCTAssertEqual(layer.rect,CGRect(x: 16,y: 8,width: 128,height: 48))
        XCTAssertEqual(layer.opacity,0.8); XCTAssertEqual(layer.cornerRadius,12)
        guard case .text(let text,let font,let color)=layer.content else { return XCTFail("Expected text instruction") }
        XCTAssertEqual(text,"Hello ⌘K 😀"); XCTAssertEqual(font,36); XCTAssertEqual(color,SIMD4(1,1,1,0.5))
        XCTAssertThrowsError(try decode(text: nil).drawingLayer())
        XCTAssertThrowsError(try decode(color: [1,1,1]).drawingLayer())
        XCTAssertThrowsError(try decode("unsupported").drawingLayer())
    }
    func testSemanticKeycapsExpandPlateGlyphAndModifierNameWithLegacyFallback() throws {
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        func row(_ value: [String:Any]) throws -> CoreDrawingLayer {
            try decoder.decode(CoreDrawingLayer.self,from: JSONSerialization.data(withJSONObject: value))
        }
        let common: [String:Any]=["rect":[10,20,300,60],"corner_radius":12,"opacity":1,
          "dim_opacity":0,"fill":[0.1,0.1,0.1,0.9],"stroke":[1,1,1,0.2],"stroke_width":1]
        var plate=common; plate["id"]="core:key-overlay:background"; plate["kind"]="highlight"; plate["purpose"]="text_background"
        var text=common; text["id"]="core:key-overlay"; text["kind"]="text"; text["text"]="⌘K"; text["font_size"]=36; text["color"]=[1,1,1,1]
        text["keycaps"]=[
          ["glyph":"⌘","name":"command","rect":[10,20,145.63,60]],
          ["glyph":"K","rect":[164.37,20,145.63,60]]
        ]
        let expanded=try coreDrawingLayers([row(plate),row(text)])
        XCTAssertEqual(expanded.count,4)
        XCTAssertEqual(expanded[0].rect.minX,10,accuracy: 0.001)
        XCTAssertEqual(expanded[1].rect.minX,164.37,accuracy: 0.001)
        guard case .keycap(let glyph,let name,_,_)=expanded[2].content else { return XCTFail("Expected semantic keycap") }
        XCTAssertEqual(glyph,"⌘"); XCTAssertEqual(name,"command")
        guard case .keycap(let key,let keyName,_,_)=expanded[3].content else { return XCTFail("Expected named keycap") }
        XCTAssertEqual(key,"K"); XCTAssertNil(keyName)

        text.removeValue(forKey: "keycaps")
        let legacy=try coreDrawingLayers([row(plate),row(text)])
        XCTAssertEqual(legacy.count,2)
        guard case .text("⌘K",_,_)=legacy[1].content else { return XCTFail("Expected joined legacy text") }
    }
    func testRealCoreAnnotationsCaptionsReactionsAndFinalFadeUseOneLayerList() throws {
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let package=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-core-text-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: fixture,to: package)
        defer { try? FileManager.default.removeItem(at: package) }
        let project=try Project.create(package: package)
        let data=try JSONSerialization.jsonObject(with: project.toJSON()) as? [String: Any]
        XCTAssertNotNil((data?["canvas"] as? [String: Any])?["annotations"],"Integrated Core must expose the text model")
        for (path,text) in [("annotations","Annotation"),("captions","Caption"),("reactions","😀")] {
            try project.apply(.set(path: "canvas.\(path)",value: .array([.object([
                "id":.string(path),"tl_start_ns":.integer(0),"tl_end_ns":.integer(2_000_000_000),
                "text":.string(text),"space":.string("canvas"),"rect":.array([0.1,0.2,0.8,0.4].map(JSONValue.number))
            ])])))
        }
        try project.apply(.batch([
            .set(path: "canvas.animation.entrance",value: .string("fade")),
            .set(path: "canvas.animation.entrance_duration_ns",value: .integer(1_000_000_000))
        ]))
        let source=try project.renderSnapshot(), frame=try source.frame(atNs: 500_000_000)
        let effects=try source.renderEffects(atNs: frame.tl_ns,canvasSize: CGSize(width: Int(frame.canvas_w),height: Int(frame.canvas_h)))
        let texts=effects.layers.compactMap { layer -> String? in if case .text(let text,_,_)=layer.content { return text }; return nil }
        XCTAssertEqual(texts,["Annotation","😀","Caption"])
        XCTAssertEqual(effects.layers.count,7,"Three backgrounds, three texts, one fade")
        XCTAssertEqual(effects.layers.last?.opacity,0.5)
        XCTAssertTrue(try source.renderEffects(atNs: 2_000_000_000,canvasSize: .zero).layers.isEmpty)
    }
    func testTranslucentTextUsesStraightSRGBAndRetainsWhiteGlyphBrightness() throws {
        _ = try requireRenderDevice()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-text-alpha-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recording"),withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"segments\":[]}".utf8).write(to: root.appendingPathComponent("recording/session.json"))
        let layer=RenderLayer(content: .text("MMMM",fontSize: 24,color: SIMD4(1,1,1,0.5)),rect: CGRect(x: 2,y: 2,width: 60,height: 36))
        let source=TestSource(package: root,layers: [layer]) { ns in
            var frame=YcFrame(); frame.tl_ns=ns; frame.canvas_w=64; frame.canvas_h=40; frame.background_color=(0,0,0,1); frame.click_progress = -1; return frame
        }
        let bytes=try RenderTests().pixels(source.frame(atNs: 0),source: source,width: 64,height: 40)
        let peak=stride(from: 0,to: bytes.count,by: 4).map { bytes[$0] }.max() ?? 0
        XCTAssertGreaterThan(peak,180); XCTAssertLessThan(peak,191)
    }
}
