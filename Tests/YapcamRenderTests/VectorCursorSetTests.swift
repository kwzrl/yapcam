import XCTest
import Metal
@testable import YapcamRender

final class VectorCursorSetTests: XCTestCase {
    func testCatalogProvidesDistinctOriginalArtworkAndStableHotspotsAcrossScales() throws {
        let sets=VectorCursorLibrary.presets
        XCTAssertGreaterThanOrEqual(sets.count,12)
        XCTAssertEqual(Set(sets.map(\.id)).count,sets.count)
        XCTAssertEqual(Set(sets.map(\.category)),Set(VectorCursorSet.Category.allCases))
        var distinct=Set<Data>()
        for preset in sets {
            XCTAssertEqual(VectorCursorLibrary.preset(id: preset.id),preset)
            for style in VectorCursorStyle.allCases {
                let normal=try VectorCursorLibrary.artwork(style,setID: preset.id)
                let bytes=try XCTUnwrap(normal.image.dataProvider?.data) as Data
                XCTAssertTrue(distinct.insert(bytes).inserted,"Every set/type pair must have its own artwork: \(preset.id)/\(style)")
                for scale: CGFloat in [1,1.5,2,4,8] {
                    let artwork=try VectorCursorLibrary.artwork(style,setID: preset.id,scale: scale)
                    XCTAssertEqual(artwork.hotspot,normal.hotspot)
                    XCTAssertEqual(artwork.sizePoints,normal.sizePoints)
                    XCTAssertEqual(artwork.image.width,Int((artwork.sizePoints.width*scale).rounded()))
                    let pixels=try XCTUnwrap(artwork.image.dataProvider?.data) as Data
                    let alpha=Int(artwork.hotspot.y*scale)*artwork.image.bytesPerRow+Int(artwork.hotspot.x*scale)*4+3
                    XCTAssertGreaterThan(pixels[alpha],0,"Hotspot stays visible at all supported raster scales")
                    // Padding must remain transparent so stroke extents aren't clipped at the texture boundary.
                    for x in 0..<artwork.image.width {
                        XCTAssertEqual(pixels[x*4+3],0)
                        XCTAssertEqual(pixels[(artwork.image.height-1)*artwork.image.bytesPerRow+x*4+3],0)
                    }
                    for y in 0..<artwork.image.height {
                        XCTAssertEqual(pixels[y*artwork.image.bytesPerRow+3],0,"Left border \(preset.id)/\(style) scale=\(scale) row=\(y)")
                        XCTAssertEqual(pixels[y*artwork.image.bytesPerRow+(artwork.image.width-1)*4+3],0,"Right border \(preset.id)/\(style) scale=\(scale) row=\(y)")
                    }
                }
                let repeatImage=try VectorCursorLibrary.artwork(style,setID: preset.id)
                XCTAssertEqual(try XCTUnwrap(repeatImage.image.dataProvider?.data) as Data,bytes)
            }
        }
        XCTAssertEqual(distinct.count,sets.count*VectorCursorStyle.allCases.count)
    }
    func testEveryShapeHasFourLogicalSizesWithScaledActionPointsAndClearBorders() throws {
        XCTAssertEqual(VectorCursorStyle.allCases.count,12)
        for preset in VectorCursorLibrary.presets {
            for style in VectorCursorStyle.allCases {
                let regular=try VectorCursorLibrary.artwork(style,setID: preset.id)
                for size in VectorCursorSize.allCases {
                    for density: CGFloat in [1,2,4,8] {
                        let art=try VectorCursorLibrary.artwork(style,setID: preset.id,size: size,scale: density)
                        XCTAssertEqual(art.sizePoints.width,regular.sizePoints.width*size.multiplier)
                        XCTAssertEqual(art.sizePoints.height,regular.sizePoints.height*size.multiplier)
                        XCTAssertEqual(art.hotspot.x,regular.hotspot.x*size.multiplier)
                        XCTAssertEqual(art.hotspot.y,regular.hotspot.y*size.multiplier)
                        let bytes=try XCTUnwrap(art.image.dataProvider?.data) as Data
                        let stride=art.image.bytesPerRow, w=art.image.width, h=art.image.height
                        let description="\(preset.id)/\(style)/\(size) @\(density)x"
                        for x in 0..<w {
                            XCTAssertEqual(bytes[x*4+3],0,description)
                            XCTAssertEqual(bytes[(h-1)*stride+x*4+3],0,description)
                        }
                        for y in 0..<h {
                            XCTAssertEqual(bytes[y*stride+3],0,description)
                            XCTAssertEqual(bytes[y*stride+(w-1)*4+3],0,description)
                        }
                        let tip=Int(art.hotspot.y*density)*stride+Int(art.hotspot.x*density)*4+3
                        XCTAssertGreaterThan(bytes[tip],0,description)
                    }
                }
            }
        }
    }
    func testClassicDefaultRemainsAvailableAndUnknownSetIsAnExplicitError() throws {
        for style in VectorCursorStyle.allCases {
            let old=try VectorCursorLibrary.artwork(style), classic=try VectorCursorLibrary.artwork(style,setID: "classic")
            XCTAssertEqual(old.hotspot,classic.hotspot)
            XCTAssertEqual(try XCTUnwrap(old.image.dataProvider?.data) as Data,try XCTUnwrap(classic.image.dataProvider?.data) as Data)
        }
        XCTAssertNil(VectorCursorLibrary.preset(id: "missing"))
        XCTAssertThrowsError(try VectorCursorLibrary.artwork(.arrow,setID: "missing"))
        XCTAssertThrowsError(try VectorCursorLibrary.artwork(.touch,setID: "classic",scale: .nan))
        var frame=YcFrame(); frame.canvas_w=320; frame.canvas_h=200
        var configuration=RenderConfiguration(); configuration.cursorSetID="missing"
        XCTAssertThrowsError(try validateFrame(frame,configuration: configuration))
    }
    func testSharedCompositorSupportsEveryShapeAndLogicalSize() throws {
        let device=try requireRenderDevice()
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let compositor=try FrameCompositor(device: device,project: TestSource(package: fixture))
        let target=try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,width: 128,height: 96,mipmapped: false)))
        let queue=try XCTUnwrap(device.makeCommandQueue())
        let styles: [RenderConfiguration.CursorStyle] = [.arrow,.pointer,.touch,.text,.resizeHorizontal,.resizeVertical,.resizeDiagonalNWSE,.resizeDiagonalNESW,.openHand,.closedHand]
        var distinct=Set<Data>()
        for preset in ["classic","lagoon"] {
            for style in styles {
                for size in VectorCursorSize.allCases {
                    var configuration=RenderConfiguration()
                    configuration.cursorSetID=preset; configuration.cursorStyle=style; configuration.cursorSize=size
                    let source=TestSource(package: fixture,configuration: configuration) { ns in
                        var frame=YcFrame(); frame.tl_ns=ns; frame.canvas_w=128; frame.canvas_h=96
                        frame.background_color=(0.3,0.3,0.3,1); frame.click_progress = -1
                        frame.cursor_visible=1; frame.cursor_opacity=1; frame.cursor_scale=1
                        frame.cursor_x=48; frame.cursor_y=32; return frame
                    }
                    let buffer=try XCTUnwrap(queue.makeCommandBuffer())
                    try compositor.encode(source.frame(atNs: 0),from: source,to: target,in: buffer)
                    buffer.commit(); buffer.waitUntilCompleted()
                    XCTAssertEqual(buffer.status,.completed,buffer.error?.localizedDescription ?? "")
                    var bytes=[UInt8](repeating: 0,count: 128*96*4)
                    target.getBytes(&bytes,bytesPerRow: 128*4,from: MTLRegionMake2D(0,0,128,96),mipmapLevel: 0)
                    let image=Data(bytes)
                    XCTAssertTrue(distinct.insert(image).inserted,"Shape/size must be part of the GPU cache key")
                }
            }
        }
        XCTAssertEqual(distinct.count,80)
    }
    func testEverySetChangesSharedCompositorPixelsAndSelectionOverridesRecordedPNG() throws {
        let device=try requireRenderDevice()
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let compositor=try FrameCompositor(device: device,project: TestSource(package: fixture))
        let target=try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,width: 96,height: 80,mipmapped: false)))
        let queue=try XCTUnwrap(device.makeCommandQueue())
        func pixels(_ source: TestSource) throws -> Data {
            let buffer=try XCTUnwrap(queue.makeCommandBuffer())
            try compositor.encode(source.frame(atNs: 0),from: source,to: target,in: buffer)
            buffer.commit(); buffer.waitUntilCompleted()
            XCTAssertEqual(buffer.status,.completed,buffer.error?.localizedDescription ?? "")
            var bytes=[UInt8](repeating: 0,count: 96*80*4)
            target.getBytes(&bytes,bytesPerRow: 96*4,from: MTLRegionMake2D(0,0,96,80),mipmapLevel: 0)
            return Data(bytes)
        }
        var images=Set<Data>(), firstImage: Data?, firstSource: TestSource?
        for preset in VectorCursorLibrary.presets {
            // Recorded sprite 1 exists, so this also proves explicit set selection replaces it.
            var configuration=RenderConfiguration(); configuration.cursorSetID=preset.id
            let source=TestSource(package: fixture,configuration: configuration) { ns in
                var frame=YcFrame(); frame.tl_ns=ns; frame.canvas_w=96; frame.canvas_h=80
                frame.background_color=(0.3,0.3,0.3,1); frame.click_progress = -1
                frame.screen.segment=0; frame.cursor_id=1
                frame.cursor_visible=1; frame.cursor_opacity=1; frame.cursor_scale=1
                frame.cursor_x=32; frame.cursor_y=16; return frame
            }
            let rendered=try pixels(source)
            if firstImage==nil { firstImage=rendered; firstSource=source }
            XCTAssertTrue(images.insert(rendered).inserted,"Compositor must include set ID in its artwork/cache selection")
        }
        XCTAssertEqual(images.count,VectorCursorLibrary.presets.count)
        XCTAssertEqual(try pixels(XCTUnwrap(firstSource)),try XCTUnwrap(firstImage),"Returning to the first set must reuse the correct cached texture")
    }
}
