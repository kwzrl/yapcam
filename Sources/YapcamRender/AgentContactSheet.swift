import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct AgentSheetLayout: Sendable {
    public let columns: Int, rows: Int, cellWidth: Int, cellHeight: Int
    public let gutter = 8
    public let labelHeight = 24
    public var width: Int { columns * cellWidth + (columns - 1) * gutter }
    public var height: Int { rows * cellHeight + (rows - 1) * gutter }
    public var imageSize: CGSize { CGSize(width: cellWidth, height: cellHeight - labelHeight) }
    public init(count: Int) throws {
        guard (1...12).contains(count) else { throw RenderError.invalidSettings("A contact sheet needs 1…12 frames") }
        switch count {
        case 1: (columns, cellWidth, cellHeight) = (1, 1920, 1080)
        case 2...4: (columns, cellWidth, cellHeight) = (2, 1280, 720)
        case 5...9: (columns, cellWidth, cellHeight) = (3, 850, 478)
        default: (columns, cellWidth, cellHeight) = (4, 636, 357)
        }
        rows = (count + columns - 1) / columns
    }
    public func cell(at index: Int) -> CGRect {
        CGRect(x: (index % columns) * (cellWidth + gutter),
               y: height - cellHeight - (index / columns) * (cellHeight + gutter), width: cellWidth, height: cellHeight)
    }
    public static func timecode(_ ns: Int64) -> String {
        let hundredths = max(0, ns) / 10_000_000
        return String(format: "%lld:%02lld.%02lld", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
    }
}

public enum AgentContactSheet {
    /// Draw one frame at a time so a 48-frame request never retains 48 full-size images.
    public static func make(times: [Int64], frame: (Int64, CGSize) throws -> CGImage) throws -> CGImage {
        let layout = try AgentSheetLayout(count: times.count)
        let ctx = try context(width: layout.width, height: layout.height)
        ctx.setFillColor(gray: 0.24, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
        for (index, time) in times.enumerated() {
            try autoreleasepool {
                let cell = layout.cell(at: index)
                let image = try frame(time, layout.imageSize)
                let area = CGRect(x: cell.minX, y: cell.minY + CGFloat(layout.labelHeight), width: cell.width, height: cell.height - CGFloat(layout.labelHeight))
                let scale = min(area.width / CGFloat(image.width), area.height / CGFloat(image.height))
                let rect = CGRect(x: area.midX - CGFloat(image.width) * scale / 2, y: area.midY - CGFloat(image.height) * scale / 2,
                                  width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                ctx.interpolationQuality = .high
                ctx.draw(image, in: rect)
                let font = CTFontCreateWithName("Menlo" as CFString, 16, nil)
                let text = NSAttributedString(string: AgentSheetLayout.timecode(time), attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
                ])
                ctx.textPosition = CGPoint(x: cell.minX + 8, y: cell.minY + 6)
                CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
            }
        }
        guard let image = ctx.makeImage() else { throw RenderError.write("Cannot create contact sheet") }
        return image
    }

    /// PNG only: shrink difficult/noisy images until even their base64 payload is <= 1 MB.
    public static func png(_ original: CGImage) throws -> Data {
        var image = original
        while true {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw RenderError.write("PNG encoder unavailable") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw RenderError.write("PNG encoding failed") }
            if data.length <= 750_000 { return data as Data }
            let width = max(1, Int(Double(image.width) * 0.8)), height = max(1, Int(Double(image.height) * 0.8))
            let ctx = try context(width: width, height: height)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let smaller = ctx.makeImage() else { throw RenderError.write("Cannot resize contact sheet") }
            image = smaller
        }
    }
    private static func context(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw RenderError.write("Cannot allocate contact sheet") }
        return context
    }
}
