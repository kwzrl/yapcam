import XCTest
@testable import YapcamRender

final class RecordedCursorReplacementTests: XCTestCase {
    func testOnlyKnownStandardShapesReplaceAnEnlargedBitmap() throws {
        func policy(_ shape: String?, density: CGFloat = 4, enabled: Bool = true) -> RecordedCursorReplacement? {
            RecordedCursorReplacement(shape: shape,sizePoints: CGSize(width: 16,height: 24),
                bitmapSize: CGSize(width: 32,height: 48),pixelsPerPoint: density,enabled: enabled)
        }
        for style in VectorCursorStyle.allCases where style != .touch {
            XCTAssertEqual(policy(style.shapeID)?.style,style)
        }
        for shape in [nil,"custom-app-cursor","1","touch"] { XCTAssertNil(policy(shape)) }
        for density: CGFloat in [0,1,2,2.01,.nan,.infinity] { XCTAssertNil(policy("arrow",density: density)) }
        XCTAssertNil(policy("arrow",enabled: false))
        XCTAssertEqual(policy("arrow")?.rasterScale,4)
        XCTAssertEqual(policy("arrow",density: 20)?.rasterScale,8,"Keep texture memory bounded")
    }

    func testOwnArtworkKeepsRecordedHeightAndActionPointAtEveryDensity() throws {
        for style in VectorCursorStyle.allCases where style != .touch {
            for height: CGFloat in [8,24,47.5,128,256] {
                let replacement=try XCTUnwrap(RecordedCursorReplacement(shape: style.shapeID,
                    sizePoints: CGSize(width: height,height: height),bitmapSize: CGSize(width: height,height: height),
                    pixelsPerPoint: 4,enabled: true))
                let art=try VectorCursorLibrary.artwork(style,preset: VectorCursorLibrary.presets[0],
                    scale: CGFloat(replacement.rasterScale),heightPoints: replacement.heightPoints)
                let geometry=replacement.geometry(artworkSize: art.sizePoints,hotspot: art.hotspot)
                XCTAssertEqual(geometry.size.height,height)
                let actionPoint=CGPoint(x: 190.25,y: 137.5)
                for zoom: CGFloat in [0.5,1,3] {
                    let rect=VectorCursorLibrary.placement(sizePoints: geometry.size,hotspot: geometry.hotspot,at: actionPoint,scale: zoom)
                    XCTAssertEqual(rect.minX+geometry.hotspot.x*zoom,actionPoint.x,accuracy: 0.000001)
                    XCTAssertEqual(rect.minY+geometry.hotspot.y*zoom,actionPoint.y,accuracy: 0.000001)
                }
            }
        }
    }

    func testQueryAdditionIsOptionalAndDoesNotCoerceBadTypes() throws {
        func value(_ json: String) throws -> ProjectRenderOptions {
            try JSONDecoder().decode(ProjectRenderOptions.self,from: Data(json.utf8))
        }
        XCTAssertTrue(RenderConfiguration().cursorUseDefaultIfAppHasLowResolution)
        XCTAssertNil(try value("{}").base.cursorUseDefaultIfAppHasLowResolution)
        XCTAssertNil(try value(#"{"cursorUseDefaultIfAppHasLowResolution":null}"#).base.cursorUseDefaultIfAppHasLowResolution)
        XCTAssertEqual(try value(#"{"cursorUseDefaultIfAppHasLowResolution":false}"#).base.cursorUseDefaultIfAppHasLowResolution,false)
        XCTAssertThrowsError(try value(#"{"cursorUseDefaultIfAppHasLowResolution":"false"}"#))
        XCTAssertNil(try value("{}").base.cursorAlwaysUseDefault)
        XCTAssertEqual(try value(#"{"cursorAlwaysUseDefault":true}"#).base.cursorAlwaysUseDefault,true)
        XCTAssertThrowsError(try value(#"{"cursorAlwaysUseDefault":"true"}"#))
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let query=try decoder.decode(ProjectRenderOptions.self,from: Data(#"{"cursor_use_default_if_app_has_low_resolution":false,"cursor_always_use_default":true}"#.utf8))
        XCTAssertEqual(query.base.cursorUseDefaultIfAppHasLowResolution,false)
        XCTAssertEqual(query.base.cursorAlwaysUseDefault,true)
    }

    func testExplicitAlwaysDefaultOverridesCapturedArtworkWithoutChangingLegacyStylePolicy() {
        var c=RenderConfiguration()
        c.cursorSetID="original"; c.cursorStyle = .pointer
        XCTAssertTrue(CursorRenderSelection(configuration: c,recordedShape: "text",clickProgress: -1).recorded)
        c.cursorAlwaysUseDefault=true
        let forced=CursorRenderSelection(configuration: c,recordedShape: "text",clickProgress: -1)
        XCTAssertFalse(forced.recorded); XCTAssertEqual(forced.style,.arrow)
        c.cursorSetID="touch"
        XCTAssertEqual(CursorRenderSelection(configuration: c,recordedShape: "text",clickProgress: -1).style,.touch)
    }
}
