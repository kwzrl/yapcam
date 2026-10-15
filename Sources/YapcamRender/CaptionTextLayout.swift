import Foundation
import CoreText
import YapcamCore

/// Core owns the animation clock. This immutable layout owns only glyph shaping.
/// Word ranges are UTF-16 ranges in the shaped string, never character counts.
final class CaptionTextLayout: @unchecked Sendable {
    let frame: CTFrame
    let size: CGSize
    let fittedWidth: CGFloat
    let wordRanges: [NSRange]
    private let fittedOriginX: CGFloat

    init(caption: CoreCaptionEvaluation, fontSize: Double, family: RenderTextFontFamily, size: CGSize) throws {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 8192, size.height <= 8192, fontSize.isFinite, fontSize > 0 else {
            throw RenderError.invalidSettings("Invalid caption layout size")
        }
        self.size = size
        let text: String
        if caption.reveal == .word {
            var joined = "", ranges: [NSRange] = []
            for word in caption.words {
                if caption.growth != .full && !word.visible { continue }
                if !joined.isEmpty { joined += " " }
                let normalized = word.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                ranges.append(NSRange(location: joined.utf16.count, length: normalized.utf16.count))
                joined += normalized
            }
            text = joined; wordRanges = ranges
        } else {
            text = caption.fullText; wordRanges = []
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): family.font(size: fontSize),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        // Reserve the complete caller box for full growth. Other modes crop the
        // existing layout, preserving wrapping and baseline positions.
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        // Natural RTL paragraphs can start near the right edge of the frame.
        // Fit the union in visual coordinates, rather than clipping at x=0.
        let left = floor(origins.map(\.x).min() ?? 0)
        let right = ceil(zip(lines,origins).map { line,origin in
            origin.x + CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }.max() ?? 0)
        fittedOriginX = caption.growth == .full ? 0 : left
        fittedWidth = caption.growth == .full ? size.width : min(size.width, max(1, right - left))
    }

    func fittedRect(_ rect: CGRect, growth: TextStyle.Growth) -> CGRect {
        var result = rect
        result.size.width = fittedWidth
        if growth == .centered { result.origin.x += (rect.width - fittedWidth) / 2 }
        return result
    }

    func image(caption: CoreCaptionEvaluation, color: SIMD4<Float>, scale: Double) throws -> CGImage {
        guard scale.isFinite, scale > 0, fittedWidth * scale <= 8192, size.height * scale <= 8192,
              [color.x,color.y,color.z,color.w].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw RenderError.invalidSettings("Invalid caption raster settings")
        }
        let width = Int(ceil(fittedWidth * scale)), height = Int(ceil(size.height * scale))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw RenderError.write("Cannot rasterize caption")
        }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -fittedOriginX, y: 0)
        // Use context color so opacity changes do not affect shaping or fallback fonts.
        context.setFillColor(CGColor(colorSpace: space, components: [CGFloat(color.x),CGFloat(color.y),CGFloat(color.z),CGFloat(color.w)])!)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let words = caption.growth == .full ? caption.words : caption.words.filter(\.visible)
        for (lineIndex, line) in lines.enumerated() {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                if caption.reveal == .line {
                    context.textPosition = origins[lineIndex]
                    CTRunDraw(run, context, CFRange(location: 0, length: 0))
                    continue
                }
                for (index, word) in words.enumerated() where word.visible && word.opacity > 0 {
                    let range = wordRanges[index]
                    // Draw consecutive glyphs from the original shaped run. This
                    // retains kerning, ligatures, RTL positions and emoji fallback.
                    var first: Int?
                    for glyph in 0...count {
                        let belongs = glyph < count && NSLocationInRange(indices[glyph], range)
                        if belongs && first == nil { first = glyph }
                        if !belongs, let start = first {
                            context.saveGState()
                            context.setAlpha(word.opacity)
                            context.textPosition = CGPoint(x: origins[lineIndex].x, y: origins[lineIndex].y - word.offsetY * size.height)
                            CTRunDraw(run, context, CFRange(location: start, length: glyph - start))
                            context.restoreGState()
                            first = nil
                        }
                    }
                }
            }
        }
        guard let image = context.makeImage() else { throw RenderError.write("Cannot create caption image") }
        return image
    }
}

/// Adapter and renderer share bounded, immutable layouts; animation progress is
/// deliberately absent from the cache key. No rendered animation frames accumulate.
final class CaptionLayoutCache: @unchecked Sendable {
    static let shared = CaptionLayoutCache()
    private struct Key: Hashable {
        var words: [String]
        var reveal: String
        var growth: String
        var family: String
        var fontSize: Double
        var width: Double
        var height: Double
    }
    private let lock = NSLock()
    private var layouts: [Key: CaptionTextLayout] = [:]
    func layout(_ caption: CoreCaptionEvaluation, fontSize: Double, family: RenderTextFontFamily, size: CGSize) throws -> CaptionTextLayout {
        let words = caption.reveal == .line ? [caption.fullText] : caption.words.filter { caption.growth == .full || $0.visible }.map(\.text)
        let key = Key(words: words, reveal: caption.reveal.rawValue, growth: caption.growth.rawValue, family: family.rawValue,
                      fontSize: fontSize, width: size.width, height: size.height)
        return try lock.withLock {
            if let layout = layouts[key] { return layout }
            let layout = try CaptionTextLayout(caption: caption, fontSize: fontSize, family: family, size: size)
            if layouts.count >= 16 { layouts.removeAll() }
            layouts[key] = layout
            return layout
        }
    }
}
