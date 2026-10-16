import XCTest
import CoreGraphics
import ImageIO
import CryptoKit
import Metal
@testable import YapcamRender

final class CursorCatalogTests: XCTestCase {
    private func bytes(_ image: CGImage) throws -> Data { try XCTUnwrap(image.dataProvider?.data) as Data }
    private func alpha(_ image: CGImage) throws -> Data {
        let raw = try bytes(image)
        return Data(stride(from: 3,to: raw.count,by: 4).map { raw[$0] })
    }

    func testCatalogHasOriginalTouchAndTwelveDifferentGeometryFamilies() throws {
        XCTAssertEqual(VectorCursorLibrary.catalog.prefix(2).map(\.id),["original","touch"])
        XCTAssertEqual(VectorCursorLibrary.catalog.count,14)
        XCTAssertEqual(Set(VectorCursorLibrary.presets.map(\.geometry)).count,12)
        XCTAssertEqual(Set(VectorCursorLibrary.catalog.map(\.id)).count,14)
        XCTAssertEqual(Set(VectorCursorStyle.allCases.map(\.shapeID)).count,12)
        for style in VectorCursorStyle.allCases {
            XCTAssertEqual(VectorCursorStyle(shapeID: style.shapeID),style)
            XCTAssertEqual(VectorCursorLibrary.variants(for: style).map(\.id),[.standard,.alternate])
        }
        XCTAssertThrowsError(try VectorCursorLibrary.artwork(.arrow,setID: "original"))
        XCTAssertThrowsError(try VectorCursorLibrary.artwork(.arrow,setID: "classic",heightPoints: 15))
        XCTAssertThrowsError(try VectorCursorLibrary.artwork(.arrow,setID: "classic",heightPoints: .nan))
        XCTAssertThrowsError(try VectorCursorLibrary.thumbnail(setID: "missing"))
    }

    func testEverySetTypeVariantAndPointHeightRasterizesWithTheExactHotspot() throws {
        for preset in VectorCursorLibrary.presets {
            for style in VectorCursorStyle.allCases {
                let standard = try VectorCursorLibrary.artwork(style,setID: preset.id,heightPoints: 32,rasterScale: 2)
                let alternate = try VectorCursorLibrary.artwork(style,setID: preset.id,heightPoints: 32,rasterScale: 2,variant: .alternate)
                XCTAssertNotEqual(try bytes(standard.image),try bytes(alternate.image),"\(preset.id)/\(style): a variant changes real geometry")
                for height: CGFloat in [16,24,32,64,128] {
                    for density: CGFloat in [1,2,4] {
                        for variant in VectorCursorVariant.allCases {
                            let art = try VectorCursorLibrary.artwork(style,setID: preset.id,heightPoints: height,rasterScale: density,variant: variant)
                            let label = "\(preset.id)/\(style)/\(variant)/\(height)pt@\(density)x"
                            XCTAssertEqual(art.image.height,Int(height*density),label)
                            XCTAssertEqual(art.hotspot.x,standard.hotspot.x*height/32,accuracy: 0.000001,label)
                            XCTAssertEqual(art.hotspot.y,standard.hotspot.y*height/32,accuracy: 0.000001,label)
                            let raw = try bytes(art.image)
                            let index = Int(art.hotspot.y*density)*art.image.bytesPerRow+Int(art.hotspot.x*density)*4+3
                            XCTAssertGreaterThan(raw[index],0,label)
                            for projectScale: CGFloat in [0.5,1,2.75] {
                                let click = CGPoint(x: 543.25,y: 217.75), rect = art.rect(at: click,scale: projectScale)
                                XCTAssertEqual(rect.minX+art.hotspot.x*projectScale,click.x,accuracy: 0.000001,label)
                                XCTAssertEqual(rect.minY+art.hotspot.y*projectScale,click.y,accuracy: 0.000001,label)
                            }
                        }
                    }
                }
            }
        }
    }

    func testSetSilhouettesDifferWithoutUsingColorAsTheDistinction() throws {
        for style in VectorCursorStyle.allCases {
            var masks = Set<Data>()
            for preset in VectorCursorLibrary.presets {
                let art = try VectorCursorLibrary.artwork(style,setID: preset.id,heightPoints: 32,rasterScale: 4)
                XCTAssertTrue(masks.insert(try alpha(art.image)).inserted,"Geometry must differ: \(preset.id)/\(style)")
            }
            XCTAssertEqual(masks.count,12)
        }
    }

    func testOriginalAndTouchPolicyRecordedTypesAndPerTypeVariants() throws {
        var configuration = RenderConfiguration()
        configuration.cursorSetID = "original"; configuration.cursorStyle = .arrow
        XCTAssertTrue(CursorRenderSelection(configuration: configuration,recordedShape: "text",clickProgress: -1).recorded)
        configuration.cursorSetID = nil; configuration.cursorStyle = .recorded
        XCTAssertTrue(CursorRenderSelection(configuration: configuration,recordedShape: "text",clickProgress: -1).recorded)
        configuration.cursorSetID = "paper"; configuration.cursorVariants = ["text": .alternate,"not_allowed": .alternate]
        for style in VectorCursorStyle.allCases {
            let selection = CursorRenderSelection(configuration: configuration,recordedShape: style.shapeID,clickProgress: -1)
            XCTAssertFalse(selection.recorded); XCTAssertEqual(selection.style,style)
            XCTAssertEqual(selection.variant,configuration.cursorVariants[style.shapeID] ?? .standard)
        }
        configuration.cursorSetID = "touch"; configuration.cursorStyle = .arrow
        let released = CursorRenderSelection(configuration: configuration,recordedShape: "not_allowed",clickProgress: -1)
        let pressed = CursorRenderSelection(configuration: configuration,recordedShape: "not_allowed",clickProgress: 0.1)
        XCTAssertEqual(released.style,.touch); XCTAssertTrue(pressed.pressed); XCTAssertFalse(released.pressed)
        configuration.cursorPressed = true
        XCTAssertTrue(CursorRenderSelection(configuration: configuration,recordedShape: nil,clickProgress: -1).pressed,"Touch works with the global click ring disabled")
        configuration.cursorPressed = false
        XCTAssertFalse(CursorRenderSelection(configuration: configuration,recordedShape: nil,clickProgress: 0.1).pressed,"Explicit button state wins over the legacy ring pulse")
        let a = try VectorCursorLibrary.artwork(.arrow,setID: "touch"), b = try VectorCursorLibrary.artwork(.text,setID: "touch",pressed: true)
        XCTAssertEqual(a.hotspot,b.hotspot)
        XCTAssertNotEqual(try bytes(a.image),try bytes(b.image),"Touch click must show a press without an arrow")
        for id in VectorCursorLibrary.presets.map(\.id) + ["touch"] {
            let up = try VectorCursorLibrary.artwork(.touch,setID: id), down = try VectorCursorLibrary.artwork(.touch,setID: id,pressed: true)
            XCTAssertEqual(up.hotspot,down.hotspot)
            XCTAssertNotEqual(try bytes(up.image),try bytes(down.image),id)
        }
    }

    func testPartialQueriesAndSidecarsDecodeLegacyAndNewFields() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        for json in ["{}","{\"cursor_variants\":null}"] {
            XCTAssertNil(try decoder.decode(ProjectRenderOptions.self,from: Data(json.utf8)).base.cursorVariants)
        }
        let query = try decoder.decode(ProjectRenderOptions.self,from: Data(#"{"cursor_set_id":"original","cursor_shape":"crosshair","cursor_pressed":true,"cursor_variants":{"crosshair":"alternate","not_allowed":"standard"}}"#.utf8))
        XCTAssertEqual(query.base.cursorShape,"crosshair")
        XCTAssertEqual(query.base.cursorPressed,true)
        XCTAssertEqual(query.base.cursorVariants?["crosshair"],.alternate)
        // convertFromSnakeCase must not rewrite dictionary keys (shape ids).
        XCTAssertEqual(query.base.cursorVariants?["not_allowed"],.standard)
        XCTAssertThrowsError(try decoder.decode(ProjectRenderOptions.self,from: Data(#"{"cursor_variants":{"text":"invented"}}"#.utf8)))
        let legacy = try JSONDecoder().decode(FrameCompositor.Cursor.self,from: Data(#"{"file":"1.png","hotspot":[3,4],"size_points":[16,24]}"#.utf8))
        let typed = try JSONDecoder().decode(FrameCompositor.Cursor.self,from: Data(#"{"file":"1.png","hotspot":[3,4],"size_points":[16,24],"shape":"crosshair"}"#.utf8))
        XCTAssertNil(legacy.shape); XCTAssertEqual(typed.shape,"crosshair")
        var frame = YcFrame(); frame.canvas_w = 320; frame.canvas_h = 200
        for id in ["original","touch"] { var c = RenderConfiguration(); c.cursorSetID = id; XCTAssertNoThrow(try validateFrame(frame,configuration: c)) }
        var invalid = RenderConfiguration(); invalid.cursorVariants = ["invented": .alternate]
        XCTAssertThrowsError(try validateFrame(frame,configuration: invalid))
    }

    func testLocalGoldenThumbnailsAndGridCostWhenOptedIn() throws {
        guard ProcessInfo.processInfo.environment["YAPCAM_CURSOR_GOLDENS"] == "1" else { throw XCTSkip("Opt in to local own-art PNG/manifest artifacts") }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Yapcam/render-cursors/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        func png(_ image: CGImage,_ name: String) throws {
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(root.appendingPathComponent(name).appendingPathExtension("png") as CFURL,"public.png" as CFString,1,nil))
            CGImageDestinationAddImage(destination,image,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let sheet = try XCTUnwrap(CGContext(data: nil,width: 640,height: 400,bitsPerComponent: 8,bytesPerRow: 640*4,space: space,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        var hashes: [String:String] = [:]
        for (index,item) in VectorCursorLibrary.catalog.enumerated() {
            let image = try VectorCursorLibrary.thumbnail(setID: item.id)
            XCTAssertEqual(image.width,160); XCTAssertEqual(image.height,100)
            hashes[item.id] = SHA256.hash(data: try bytes(image)).map { String(format: "%02x",$0) }.joined()
            try png(image,item.id)
            sheet.draw(image,in: CGRect(x: index%4*160,y: 300-index/4*100,width: 160,height: 100))
            if item.kind == .recorded { continue }
            let atlas = try XCTUnwrap(CGContext(data: nil,width: 384,height: 64,bitsPerComponent: 8,bytesPerRow: 384*4,space: space,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            for (x,style) in VectorCursorStyle.allCases.enumerated() {
                for (y,variant) in VectorCursorVariant.allCases.enumerated() {
                    let art = try VectorCursorLibrary.artwork(style,setID: item.id,heightPoints: 32,rasterScale: 2,variant: variant)
                    atlas.draw(art.image,in: CGRect(x: CGFloat(x*32)+(32-art.sizePoints.width)/2,y: CGFloat(32-y*32),width: art.sizePoints.width,height: 32))
                }
            }
            try png(try XCTUnwrap(atlas.makeImage()),item.id+"-types")
        }
        try png(try XCTUnwrap(sheet.makeImage()),"catalog")
        var costs: [Double] = []
        for _ in 0..<21 {
            let start = DispatchTime.now().uptimeNanoseconds
            try autoreleasepool { for item in VectorCursorLibrary.catalog { _ = try VectorCursorLibrary.thumbnail(setID: item.id) } }
            costs.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
        }
        costs.removeFirst(); costs.sort()
        let report: [String:Any] = ["revision": ProcessInfo.processInfo.environment["YAPCAM_CURSOR_REVISION"] ?? "working tree",
            "procedure": "CPU catalog thumbnails, 14 x 160x100, one warmup then 20 grids; local goldens awaiting visual review",
            "grid_p50_ms": costs[9],"grid_p95_ms": costs[18],"thumbnail_sha256": hashes,
            "order": VectorCursorLibrary.catalog.map(\.id),"types": VectorCursorStyle.allCases.map(\.shapeID),"variants": VectorCursorVariant.allCases.map(\.rawValue)]
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("manifest.json"))
        print("RENDER_CURSOR_GOLDENS \(root.lastPathComponent) grid_p50_ms=\(costs[9]) grid_p95_ms=\(costs[18])")
    }
}
