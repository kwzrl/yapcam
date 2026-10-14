import XCTest
@testable import YapcamRender

final class VectorCursorTests: XCTestCase {
    func testOriginalCursorPathsHaveDistinctVisibleRastersAndStableHotspots() throws {
        var rasters=Set<Data>()
        for style in VectorCursorStyle.allCases {
            let art=try VectorCursorLibrary.artwork(style,scale: 2)
            let data=try XCTUnwrap(art.image.dataProvider?.data) as Data
            XCTAssertTrue(rasters.insert(data).inserted)
            XCTAssertEqual(art.image.width,Int(art.sizePoints.width*2))
            XCTAssertTrue((0..<art.sizePoints.width).contains(art.hotspot.x))
            XCTAssertTrue((0..<art.sizePoints.height).contains(art.hotspot.y))
            let tip=Int(art.hotspot.y*2)*art.image.bytesPerRow+Int(art.hotspot.x*2)*4+3
            XCTAssertGreaterThan(data[tip],0,"The hotspot must land on visible artwork")
            var alpha=0
            for index in stride(from: 3,to: data.count,by: 4) { alpha+=Int(data[index]) }
            XCTAssertGreaterThan(alpha,1000); XCTAssertLessThan(alpha,data.count/4*255)
            let next=try VectorCursorLibrary.artwork(style,scale: 4)
            XCTAssertEqual(next.hotspot,art.hotspot); XCTAssertEqual(next.sizePoints,art.sizePoints)
        }
    }
    func testVectorStylesRenderDifferentPixelsAtTheSameHotspot() throws {
        _ = try requireRenderDevice()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recording"),withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"segments\":[]}".utf8).write(to: root.appendingPathComponent("recording/session.json"))
        var images=Set<Data>()
        for style in [RenderConfiguration.CursorStyle.arrow,.pointer,.touch] {
            var options=RenderConfiguration(); options.cursorStyle=style
            let source=TestSource(package: root,configuration: options) { ns in
                var frame=YcFrame(); frame.tl_ns=ns; frame.canvas_w=64; frame.canvas_h=40
                frame.background_color=(0.3,0.3,0.3,1); frame.click_progress = -1
                frame.cursor_visible=1; frame.cursor_opacity=1; frame.cursor_scale=1; frame.cursor_x=32; frame.cursor_y=12; return frame
            }
            let renderer=RenderTests()
            XCTAssertTrue(images.insert(Data(try renderer.pixels(source.frame(atNs: 0),source: source,width: 64,height: 40))).inserted)
        }
    }
}
