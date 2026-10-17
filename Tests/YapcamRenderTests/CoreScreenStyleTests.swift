import XCTest
import YapcamCore
@testable import YapcamRender

final class CoreScreenStyleTests: XCTestCase {
    func testOptionalQueryFieldsAcceptOlderAndPartialShapesWithDocumentedDefaults() throws {
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        func options(_ row: [String:JSONValue]) throws -> ProjectRenderOptions {
            try decoder.decode(ProjectRenderOptions.self,from: JSONEncoder().encode(row))
        }
        let missing=try options([:])
        XCTAssertNil(missing.screenQuality); XCTAssertNil(missing.insetOrigin)
        XCTAssertNil(missing.base.cursorLogicalSize)
        let nulls=try options(["screen_quality":.null,"inset_origin":.null])
        XCTAssertNil(nulls.screenQuality); XCTAssertNil(nulls.insetOrigin)
        let cases: [([String:JSONValue],ScreenQualitySettings)] = [
            ([:],.init()),
            (["improve_quality":.number(0.25)],.init(improveQuality: 0.25)),
            (["upscaling":.string("off")],.init(upscaling: .off)),
            (["improve_quality":.null,"upscaling":.null],.init()),
            (["future_field":.bool(true)],.init())
        ]
        for (fields,expected) in cases {
            XCTAssertEqual(try options(["screen_quality":.object(fields)]).screenQuality,expected)
        }
        XCTAssertEqual(try options(["inset_origin":.array([.number(0),.number(0)])]).insetOrigin,.zero)
        for fields: [String:JSONValue] in [["improve_quality":.string("invalid")],["upscaling":.string("unknown")]] {
            XCTAssertThrowsError(try options(["screen_quality":.object(fields)]))
        }
        XCTAssertThrowsError(try options(["inset_origin":.string("invalid")]))
    }

    func testPersistedInsetOriginAndQualityReachAdapterSnapshotsAndReopenedProjects() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-core-screen-style-\(UUID().uuidString).yapcam")
        defer { print("Cleanup render-owned screen style fixture: \(root.path)"); try? FileManager.default.removeItem(at: root) }
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        try FileManager.default.copyItem(at: fixture,to: root)
        let project=try Project.create(package: root)
        func configuration(_ source: any RenderProjectSource) throws -> RenderConfiguration {
            try source.renderEffects(atNs: 500_000_000,canvasSize: CGSize(width: 1728,height: 1080)).configuration
        }
        XCTAssertEqual(try configuration(project).screenInsetOrigin,.zero)
        XCTAssertEqual(try configuration(project).screenQuality,ScreenQualitySettings(),"Revision2 factory selects .5/quality")
        let original=try project.renderSnapshot(), frame=try project.frame(atNs: 500_000_000)
        for mode in CoreScreenQuality.Upscaling.allCases {
            try project.setScreenQuality(.init(improveQuality: 0.75,upscaling: mode))
            let selected=try XCTUnwrap(configuration(project).screenQuality)
            XCTAssertEqual(selected.improveQuality,0.75)
            XCTAssertEqual(selected.upscaling.rawValue,mode.rawValue)
        }
        try project.apply(.set(path: "canvas.inset_origin",value: .array([.number(1),.number(-0.5)])))
        let selected=try project.renderSnapshot()
        XCTAssertEqual(try configuration(selected).screenInsetOrigin,SIMD2(1,-0.5))
        XCTAssertEqual(try configuration(selected).screenQuality,ScreenQualitySettings(improveQuality: 0.75,upscaling: .quality))
        XCTAssertEqual(try configuration(original).screenInsetOrigin,.zero)
        XCTAssertEqual(try configuration(original).screenQuality,ScreenQualitySettings(),"Frozen factory selection survives later edits")
        let unchanged=try project.frame(atNs: 500_000_000)
        XCTAssertEqual(unchanged.screen_dest.x,frame.screen_dest.x); XCTAssertEqual(unchanged.screen_dest.w,frame.screen_dest.w)
        XCTAssertEqual(unchanged.screen_crop.x,frame.screen_crop.x); XCTAssertEqual(unchanged.screen_crop.w,frame.screen_crop.w)
        XCTAssertEqual(unchanged.inset_width,frame.inset_width,"Origin and screen processing do not alter Core geometry")
        try project.save()
        let reopened=try Project.open(package: root)
        XCTAssertEqual(try configuration(reopened),try configuration(selected))
        try project.setScreenQuality(nil)
        try project.apply(.set(path: "canvas.inset_origin",value: .array([.number(-1),.number(0.5)])))
        XCTAssertNil(try configuration(project).screenQuality)
        XCTAssertEqual(try configuration(project).screenInsetOrigin,SIMD2(-1,0.5))
        XCTAssertNotNil(try configuration(selected).screenQuality)
        // Missing optional fields in a saved document retain original sampling
        // and centered inset instead of opting an older project into processing.
        try project.save() // Clear the current edit journal before creating an older document.
        var legacy=try XCTUnwrap(JSONSerialization.jsonObject(with: project.toJSON()) as? [String:Any])
        var canvas=try XCTUnwrap(legacy["canvas"] as? [String:Any])
        canvas.removeValue(forKey: "screen_quality"); canvas.removeValue(forKey: "inset_origin"); legacy["canvas"]=canvas
        try JSONSerialization.data(withJSONObject: legacy).write(to: root.appendingPathComponent("project.json"))
        let old=try Project.open(package: root)
        XCTAssertEqual(try configuration(old).screenInsetOrigin,.zero)
        XCTAssertNil(try configuration(old).screenQuality)
    }

    func testTypedQueryRejectsInvalidOriginAndDoubleQualityBeforeFloatRounding() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-core-screen-style-\(UUID().uuidString).yapcam")
        defer { print("Cleanup render-owned screen style fixture: \(root.path)"); try? FileManager.default.removeItem(at: root) }
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        try FileManager.default.copyItem(at: fixture,to: root)
        let project=try Project.create(package: root)
        let base=try project.query("{\"q\":\"render_options_at\",\"tl_ns\":0}",as: [String:JSONValue].self)
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        for values: [Double] in [[],[0],[0,0,0],[1.000000001,0],[-1.000000001,0]] {
            var row=base; row["inset_origin"] = .array(values.map(JSONValue.number))
            XCTAssertThrowsError(try decoder.decode(ProjectRenderOptions.self,from: JSONEncoder().encode(row)))
        }
        for amount in [-0.000000001,1.000000001] {
            var row=base; row["screen_quality"] = .object(["improve_quality":.number(amount),"upscaling":.string("quality")])
            XCTAssertThrowsError(try decoder.decode(ProjectRenderOptions.self,from: JSONEncoder().encode(row)))
        }
    }
}
