import XCTest
import CoreText
import Metal
@testable import YapcamRender

final class CaptionFontTests: XCTestCase {
    func testOptionalFontFamilyKeepsOldTextAndValidatesSelectedFamilies() throws {
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var row: [String:Any] = ["kind":"text","rect":[10,20,280,80],"corner_radius":4,"opacity":0.75,
            "dim_opacity":0,"fill":[0,0,0,0],"stroke":[0,0,0,0],"stroke_width":0,
            "text":"Caption ⌘K 😀","font_size":32,"color":[1,1,1,0.5]]
        func layer() throws -> RenderLayer {
            try decoder.decode(CoreDrawingLayer.self,from: JSONSerialization.data(withJSONObject: row)).drawingLayer()
        }
        let legacy=try layer()
        XCTAssertEqual(legacy.textFontFamily,.sans)
        row["font_family"]=NSNull(); XCTAssertEqual(try layer(),legacy)
        for family in RenderTextFontFamily.allCases {
            row["font_family"]=family.rawValue
            let selected=try layer()
            XCTAssertEqual(selected.textFontFamily,family)
            XCTAssertEqual(selected.content,legacy.content)
            XCTAssertEqual(selected.rect,legacy.rect); XCTAssertEqual(selected.opacity,legacy.opacity)
        }
        row["font_family"]="unknown"; XCTAssertThrowsError(try layer())
        row["font_family"]=42; XCTAssertThrowsError(try layer())
    }

    func testResolvedFontFamiliesAreDistinctAndMonoHasEqualGlyphAdvances() throws {
        var names=Set<String>()
        for family in RenderTextFontFamily.allCases {
            let font=family.font(size: 32)
            names.insert(CTFontCopyPostScriptName(font) as String)
            var characters=Array("iW".utf16), glyphs=[CGGlyph](repeating: 0,count: 2)
            XCTAssertTrue(CTFontGetGlyphsForCharacters(font,&characters,&glyphs,2))
            var advances=[CGSize](repeating: .zero,count: 2)
            CTFontGetAdvancesForGlyphs(font,.horizontal,&glyphs,&advances,2)
            if family == .mono {
                XCTAssertEqual(advances[0].width,advances[1].width,accuracy: 0.001)
            } else {
                XCTAssertGreaterThan(advances[1].width,advances[0].width*1.3)
            }
        }
        XCTAssertEqual(names.count,3,"A missing system font must not silently collapse the three selections")
    }

    func testChangingOnlyFontFamilyDoesNotReuseAnotherFamilyTextureOnHost() throws {
        let device=try requireRenderDevice()
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let source=TestSource(package: fixture)
        let compositor=try FrameCompositor(device: device,project: source)
        let queue=try XCTUnwrap(device.makeCommandQueue())
        let target=try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,width: 320,height: 200,mipmapped: false)))
        func pixels(_ family: RenderTextFontFamily?) throws -> [UInt8] {
            var layer=RenderLayer(content: .text("Wi iii MMM 012",fontSize: 32,color: SIMD4(1,1,1,1)),rect: CGRect(x: 10,y: 50,width: 300,height: 100))
            if let family { layer.textFontFamily=family }
            let selected=TestSource(package: fixture,layers: [layer])
            let cb=try XCTUnwrap(queue.makeCommandBuffer())
            try compositor.encode(selected.frame(atNs: 0),from: selected,to: target,in: cb)
            cb.commit(); cb.waitUntilCompleted()
            XCTAssertEqual(cb.status,.completed,cb.error?.localizedDescription ?? "")
            var bytes=[UInt8](repeating: 0,count: 320*200*4)
            target.getBytes(&bytes,bytesPerRow: 320*4,from: MTLRegionMake2D(0,0,320,200),mipmapLevel: 0)
            return bytes
        }
        let legacy=try pixels(nil), sans=try pixels(.sans), serif=try pixels(.serif), mono=try pixels(.mono)
        XCTAssertEqual(legacy,sans)
        XCTAssertNotEqual(serif,sans); XCTAssertNotEqual(mono,sans); XCTAssertNotEqual(mono,serif)
        XCTAssertEqual(try pixels(.sans),sans,"Returning to a cached family must restore its original glyphs")
    }
}
