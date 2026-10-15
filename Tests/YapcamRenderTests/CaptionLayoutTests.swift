import XCTest
import CoreText
import YapcamCore
@testable import YapcamRender

final class CaptionLayoutTests: XCTestCase {
    private let box = CGSize(width: 280, height: 80)

    private func caption(growth: String = "full", reveal: String = "word", opacity: Double = 1,
                         offset: Double = 0, secondVisible: Bool = false) throws -> CoreCaptionEvaluation {
        let word: (String,Int,Bool,Double,Double) -> [String:Any] = { text,start,visible,alpha,y in
            ["text":text,"tl_start_ns":start,"tl_end_ns":start+900_000_000,"visible":visible,
             "progress":visible ? 1 : 0,"opacity":alpha,"offset_y":y]
        }
        let row: [String:Any] = ["full_text":"office 世界","visible_text":reveal == "line" || secondVisible ? "office 世界" : "office",
            "font_family":"sans","reveal":reveal,"growth":growth,"entrance":"appear","language":"auto",
            "line_opacity":1,"line_offset_y":0,
            "words":[word("office",0,true,opacity,offset),word("世界",1_000_000_000,reveal == "line" || secondVisible,1,0)]]
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CoreCaptionEvaluation.self,from: JSONSerialization.data(withJSONObject: row))
    }
    private func layout(_ caption: CoreCaptionEvaluation) throws -> CaptionTextLayout {
        try CaptionLayoutCache.shared.layout(caption,fontSize: 28,family: .sans,size: box)
    }
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data)
        return Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data),count: CFDataGetLength(data)))
    }
    private func alpha(_ image: CGImage) throws -> [UInt8] {
        let bytes = try rgba(image)
        return stride(from: 3,to: bytes.count,by: 4).map { bytes[$0] }
    }

    func testGrowthFitsMeasuredPrefixAndPreservesFullBoxOrRequestedAnchor() throws {
        let full = try caption(), expanding = try caption(growth: "expanding"), centered = try caption(growth: "centered")
        let f = try layout(full), e = try layout(expanding), c = try layout(centered)
        XCTAssertEqual(f.fittedWidth,box.width)
        XCTAssertLessThan(e.fittedWidth,box.width / 2)
        XCTAssertEqual(c.fittedWidth,e.fittedWidth)
        let rect = CGRect(origin: CGPoint(x: 20,y: 30),size: box)
        XCTAssertEqual(e.fittedRect(rect,growth: .expanding).minX,rect.minX)
        XCTAssertEqual(c.fittedRect(rect,growth: .centered).midX,rect.midX)
        XCTAssertEqual(c.fittedRect(rect,growth: .centered).minY,rect.minY)
        XCTAssertEqual(c.fittedRect(rect,growth: .centered).height,rect.height)
        let grown = try layout(caption(growth: "expanding",secondVisible: true))
        XCTAssertGreaterThan(grown.fittedWidth,e.fittedWidth)
        XCTAssertEqual(try layout(caption(secondVisible: true)).wordRanges,f.wordRanges,
                       "Full growth shapes the same complete string before and after reveal")
        let line = try layout(caption(growth: "centered",reveal: "line"))
        XCTAssertEqual(line.fittedWidth,grown.fittedWidth)
    }

    func testShapedWordFadeSlideAndFallbackGlyphsRasterizeWithoutGPU() throws {
        let opaque = try caption(), faded = try caption(opacity: 0.25), hidden = try caption(opacity: 0), slide = try caption(offset: 0.125)
        let shaped = try layout(opaque)
        XCTAssertTrue(shaped === (try layout(faded)),"Animation progress must not create new shaped layouts")
        let color = SIMD4<Float>(1,0,0,1)
        let image = try shaped.image(caption: opaque,color: color,scale: 1)
        let a = try alpha(image), quarter = try alpha(shaped.image(caption: faded,color: color,scale: 1))
        XCTAssertEqual(a.max(),255)
        XCTAssertEqual(Int(quarter.max() ?? 0),64,accuracy: 1)
        XCTAssertEqual(try alpha(shaped.image(caption: hidden,color: color,scale: 1)).max(),0)
        let rgba = try rgba(image)
        let peak = try XCTUnwrap(a.firstIndex(of: 255)) * 4
        XCTAssertEqual(rgba[peak],255); XCTAssertEqual(rgba[peak+1],0); XCTAssertEqual(rgba[peak+2],0)
        // Match the existing renderer's CTFrameDraw path, independently of the
        // new run-fragment implementation used for animated captions.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil,width: 280,height: 80,bitsPerComponent: 8,bytesPerRow: 280*4,
            space: space,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        let attributes: [NSAttributedString.Key:Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): RenderTextFontFamily.sans.font(size: 28),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(colorSpace: space,components: [1,0,0,1])!
        ]
        let reference = NSMutableAttributedString(string: opaque.fullText,attributes: attributes)
        // Full growth reserves fallback-font metrics for hidden words too. Hide
        // their ink without deleting them from the independent reference frame.
        reference.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),value: CGColor(gray: 0,alpha: 0),
                               range: NSRange(location: "office".utf16.count,length: " 世界".utf16.count))
        let setter = CTFramesetterCreateWithAttributedString(reference)
        CTFrameDraw(CTFramesetterCreateFrame(setter,CFRange(location: 0,length: 0),CGPath(rect: CGRect(origin: .zero,size: box),transform: nil),nil),context)
        XCTAssertTrue(rgba == (try self.rgba(XCTUnwrap(context.makeImage()))),"Opaque fragments match the complete legacy layout with hidden-word ink removed")
        func centroid(_ alpha: [UInt8]) -> Double {
            let mass = alpha.reduce(0.0) { $0 + Double($1) }
            return alpha.enumerated().reduce(0.0) { $0 + Double($1.offset / image.width) * Double($1.element) } / mass
        }
        let moved = try alpha(shaped.image(caption: slide,color: color,scale: 1))
        XCTAssertEqual(abs(centroid(moved)-centroid(a)),10,accuracy: 0.1)
        let all = try caption(secondVisible: true)
        XCTAssertGreaterThan(try alpha(shaped.image(caption: all,color: color,scale: 1)).filter { $0 > 0 }.count,
                             a.filter { $0 > 0 }.count,"Revealing CJK fallback glyphs must add ink")
        XCTAssertThrowsError(try shaped.image(caption: all,color: color,scale: .infinity))
    }

    func testUnicodeWordRangesAndCachedWordPartitionsStayDistinct() throws {
        var first = try caption(secondVisible: true)
        first.fullText = "👩‍💻 café 世界"; first.visibleText = first.fullText
        first.words[0].text = "👩‍💻 café"; first.words[1].text = "世界"
        let a = try layout(first)
        XCTAssertEqual(a.wordRanges[0].length,"👩‍💻 café".utf16.count)
        var second = first
        second.words[0].text = "👩‍💻"; second.words[1].text = "café 世界"
        let b = try layout(second)
        XCTAssertFalse(a === b,"Identical joined text with different word boundaries cannot share range metadata")
        XCTAssertNotEqual(a.wordRanges,b.wordRanges)
        for value in [first,second] {
            try validateCaption(value)
            XCTAssertGreaterThan(try alpha(layout(value).image(caption: value,color: SIMD4(1,1,1,1),scale: 1)).max() ?? 0,0)
        }
        var invalid = first; invalid.words[0].opacity = .nan
        XCTAssertThrowsError(try validateCaption(invalid))
        invalid = first; invalid.visibleText = "mismatched"
        XCTAssertThrowsError(try validateCaption(invalid))
    }

    func testWordFragmentsPreserveWholeLineShapingAcrossWrappingRTLAndEmoji() throws {
        var words = try caption(secondVisible: true)
        let pieces = ["office","café","مرحبا","العالم","👩‍💻","世界"]
        let seed = words.words[0]
        words.words = pieces.enumerated().map { index,text in
            var word = seed; word.text = text
            word.tlStartNs = Int64(index) * 1_000_000_000
            word.tlEndNs = word.tlStartNs + 900_000_000
            return word
        }
        words.fullText = pieces.joined(separator: " "); words.visibleText = words.fullText
        var line = words; line.reveal = .line
        let size = CGSize(width: 130,height: 220)
        let wordLayout = try CaptionLayoutCache.shared.layout(words,fontSize: 28,family: .sans,size: size)
        let lineLayout = try CaptionLayoutCache.shared.layout(line,fontSize: 28,family: .sans,size: size)
        XCTAssertGreaterThan(CFArrayGetCount(CTFrameGetLines(wordLayout.frame)),1)
        XCTAssertTrue(try rgba(wordLayout.image(caption: words,color: SIMD4(1,1,1,1),scale: 1)) ==
                      rgba(lineLayout.image(caption: line,color: SIMD4(1,1,1,1),scale: 1)),
                      "Drawing shaped fragments must retain the complete line's glyph positions and fallback fonts")
        var rtl = try caption(secondVisible: true)
        rtl.words[0].text = "مرحبا"; rtl.words[1].text = "العالم"
        rtl.fullText = "مرحبا العالم"; rtl.visibleText = rtl.fullText
        let complete = try layout(rtl).image(caption: rtl,color: SIMD4(1,1,1,1),scale: 1)
        rtl.growth = .centered
        let fitted = try layout(rtl).image(caption: rtl,color: SIMD4(1,1,1,1),scale: 1)
        XCTAssertEqual(try alpha(complete).filter { $0 > 0 }.count,try alpha(fitted).filter { $0 > 0 }.count,
                       "Fitting a right-to-left line must not crop its glyphs")
    }

    func testRealCoreStyleCombinationsSnapshotsAndPairedBackgroundsReachRenderer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-caption-layout-\(UUID().uuidString).yapcam")
        defer { print("Cleanup render-owned caption fixture: \(root.path)"); try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        try FileManager.default.copyItem(at: fixture,to: root)
        let project = try Project.create(package: root)
        let words = [CaptionWord(text: "office",startNs: 0,endNs: 900_000_000),
                     CaptionWord(text: "👩‍💻",startNs: 1_000_000_000,endNs: 1_900_000_000),
                     CaptionWord(text: "世界",startNs: 2_000_000_000,endNs: 2_900_000_000)]
        let record = TextEffectRecord(startNs: 0,endNs: 3_000_000_000,text: "office 👩‍💻 世界",rect: [0.1,0.2,0.8,0.3],words: words)
        let id = try XCTUnwrap(project.apply(.addText(.caption,record)).createdIDs.first)
        let original = try project.renderSnapshot()
        let annotation = TextEffectRecord(startNs: 0,endNs: 3_000_000_000,text: "untouched",rect: record.rect)
        let annotationID = try XCTUnwrap(project.apply(.addText(.annotation,annotation)).createdIDs.first)
        for family in TextStyle.FontFamily.allCases {
            for reveal in TextStyle.Reveal.allCases {
                for growth in TextStyle.Growth.allCases {
                    for entrance in TextStyle.Entrance.allCases {
                        let style = TextStyle(fontFamily: family,reveal: reveal,growth: growth,entrance: entrance)
                        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
                        let patch = try JSONDecoder().decode(JSONValue.self,from: encoder.encode(style))
                        try project.apply(.updateText(.caption,id: id,patch: ["style":patch]))
                        let sampleNs = reveal == .line ? 100_000_000 : 1_100_000_000
                        let rows = try project.query("{\"q\":\"layers_at\",\"tl_ns\":\(sampleNs)}",as: [CoreDrawingLayer].self)
                        let layers = try coreDrawingLayers(rows)
                        let textIndex = try XCTUnwrap(rows.firstIndex { $0.id == "core:caption:\(id)" })
                        let text = layers[textIndex], core = try XCTUnwrap(rows[textIndex].caption)
                        XCTAssertEqual(text.textFontFamily.rawValue,family.rawValue)
                        XCTAssertEqual(text.opacity,rows[textIndex].opacity,"Core's evaluated line fade is applied exactly once")
                        if reveal == .line && entrance == .fade { XCTAssertEqual(text.opacity,0.5) }
                        XCTAssertEqual(text.rect.origin.y,rows[textIndex].rect[1],"Core's line slide is already evaluated")
                        XCTAssertEqual(text.caption == nil,reveal == .line && growth == .full)
                        let background = try XCTUnwrap(rows.firstIndex { $0.id == "core:caption:\(id):background" })
                        let shaped = try CaptionLayoutCache.shared.layout(core,fontSize: style.fontSize,family: text.textFontFamily,size: text.rect.size)
                        XCTAssertEqual(layers[background].rect,shaped.fittedRect(text.rect,growth: growth))
                        let unrelated = try XCTUnwrap(rows.firstIndex { $0.id == "core:annotation:\(annotationID):background" })
                        XCTAssertEqual(layers[unrelated],try rows[unrelated].drawingLayer(),"Only the matching caption background may grow")
                    }
                }
            }
        }
        XCTAssertNil(try original.renderEffects(atNs: 1_100_000_000,canvasSize: .zero).layers.last?.caption)
        let frozen = try project.renderSnapshot()
        let selected = try frozen.renderEffects(atNs: 1_100_000_000,canvasSize: .zero)
        try project.save()
        XCTAssertEqual(try Project.open(package: root).renderEffects(atNs: 1_100_000_000,canvasSize: .zero),selected)
        try project.apply(.removeText(.caption,id: id))
        XCTAssertEqual(try project.renderEffects(atNs: 1_100_000_000,canvasSize: .zero).layers.count,2,"Removing the caption preserves the unrelated annotation")
        XCTAssertEqual(try frozen.renderEffects(atNs: 1_100_000_000,canvasSize: .zero),selected)
    }

    func testCaptionGrowthAndWordAnimationUseSharedCompositorOnHost() throws {
        let device = try requireRenderDevice()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        func pixels(_ evaluation: CoreCaptionEvaluation?) throws -> [UInt8] {
            let layer = RenderLayer(content: .text(evaluation?.visibleText ?? "office 世界",fontSize: 28,color: SIMD4(1,1,1,1)),rect: CGRect(x: 20,y: 40,width: 280,height: 80),caption: evaluation)
            let source = TestSource(package: fixture,layers: [layer]) { ns in
                var f = YcFrame(); f.canvas_w = 320; f.canvas_h = 200; f.tl_ns = ns
                f.background_color = (0,0,0,1); f.click_progress = -1; return f
            }
            let compositor = try FrameCompositor(device: device,project: source)
            return try GIFPalette.rgba(compositor.image(source.frame(atNs: 0)))
        }
        let full = try pixels(caption()), faded = try pixels(caption(opacity: 0.25))
        XCTAssertNotEqual(full,faded)
        XCTAssertNotEqual(full,try pixels(caption(offset: 0.125)))
        XCTAssertNotEqual(full,try pixels(caption(growth: "centered")))
        XCTAssertTrue(try pixels(nil) == pixels(caption(secondVisible: true)),"Revealed full-line glyphs retain legacy positions and brightness")
    }
}
