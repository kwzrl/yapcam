import CoreGraphics
import Foundation
import Metal

public enum VectorCursorStyle: String, CaseIterable, Sendable { case arrow, pointer, touch }
public struct VectorCursorArtwork: @unchecked Sendable {
    public let image: CGImage
    public let sizePoints: CGSize
    public let hotspot: CGPoint
}
/// Original geometric artwork; no system/reference cursor image is copied into this library.
public enum VectorCursorLibrary {
    public static func artwork(_ style: VectorCursorStyle,scale: CGFloat = 2) throws -> VectorCursorArtwork {
        guard scale.isFinite, (1...8).contains(scale) else { throw RenderError.invalidSettings("Cursor raster scale must be 1…8") }
        let size: CGSize, hotspot: CGPoint
        switch style {
        case .arrow: size=CGSize(width: 24,height: 32); hotspot=CGPoint(x: 3,y: 3)
        case .pointer: size=CGSize(width: 28,height: 32); hotspot=CGPoint(x: 12,y: 3)
        case .touch: size=CGSize(width: 32,height: 32); hotspot=CGPoint(x: 16,y: 16)
        }
        let width=Int((size.width*scale).rounded()), height=Int((size.height*scale).rounded())
        guard let space=CGColorSpace(name: CGColorSpace.sRGB),let context=CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: space,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { throw RenderError.write("Cannot rasterize cursor artwork") }
        context.translateBy(x: 0,y: CGFloat(height)); context.scaleBy(x: scale,y: -scale)
        context.setShouldAntialias(true); context.setLineJoin(.round); context.setLineCap(.round)
        let path=CGMutablePath()
        switch style {
        case .arrow:
            path.move(to: CGPoint(x: 3,y: 3)); for point in [CGPoint(x: 3,y: 24),CGPoint(x: 8,y: 19),CGPoint(x: 12,y: 29),CGPoint(x: 16,y: 27),CGPoint(x: 12,y: 17),CGPoint(x: 21,y: 17)] { path.addLine(to: point) }; path.closeSubpath()
            context.addPath(path); context.setFillColor(CGColor(gray: 0.08,alpha: 1)); context.setStrokeColor(CGColor(gray: 1,alpha: 1)); context.setLineWidth(2); context.drawPath(using: .fillStroke)
        case .pointer:
            path.move(to: CGPoint(x: 12,y: 2))
            path.addCurve(to: CGPoint(x: 10,y: 6),control1: CGPoint(x: 10,y: 2),control2: CGPoint(x: 10,y: 4))
            path.addLine(to: CGPoint(x: 10,y: 16))
            path.addCurve(to: CGPoint(x: 4,y: 15),control1: CGPoint(x: 8,y: 14),control2: CGPoint(x: 6,y: 13))
            path.addCurve(to: CGPoint(x: 8,y: 24),control1: CGPoint(x: 2,y: 17),control2: CGPoint(x: 4,y: 20))
            for point in [CGPoint(x: 9,y: 29),CGPoint(x: 21,y: 29),CGPoint(x: 24,y: 19)] { path.addLine(to: point) }
            path.addCurve(to: CGPoint(x: 21,y: 16),control1: CGPoint(x: 24,y: 17),control2: CGPoint(x: 23,y: 16))
            path.addLine(to: CGPoint(x: 21,y: 13))
            path.addCurve(to: CGPoint(x: 17,y: 12),control1: CGPoint(x: 21,y: 11),control2: CGPoint(x: 18,y: 10))
            path.addLine(to: CGPoint(x: 17,y: 10))
            path.addCurve(to: CGPoint(x: 14,y: 10),control1: CGPoint(x: 17,y: 8),control2: CGPoint(x: 14,y: 8))
            path.addLine(to: CGPoint(x: 14,y: 5))
            path.addCurve(to: CGPoint(x: 12,y: 2),control1: CGPoint(x: 14,y: 3),control2: CGPoint(x: 14,y: 2)); path.closeSubpath()
            context.addPath(path); context.setFillColor(CGColor(gray: 1,alpha: 1)); context.setStrokeColor(CGColor(gray: 0.08,alpha: 1)); context.setLineWidth(1.4); context.drawPath(using: .fillStroke)
            context.move(to: CGPoint(x: 17,y: 13)); context.addLine(to: CGPoint(x: 17,y: 18)); context.move(to: CGPoint(x: 21,y: 16)); context.addLine(to: CGPoint(x: 21,y: 20)); context.setLineWidth(0.8); context.strokePath()
        case .touch:
            context.setFillColor(CGColor(gray: 1,alpha: 0.55)); context.fillEllipse(in: CGRect(x: 5,y: 5,width: 22,height: 22))
            context.setStrokeColor(CGColor(gray: 0.15,alpha: 0.7)); context.setLineWidth(1.5); context.strokeEllipse(in: CGRect(x: 4,y: 4,width: 24,height: 24))
        }
        guard let image=context.makeImage() else { throw RenderError.write("Cannot create vector cursor image") }
        return VectorCursorArtwork(image: image,sizePoints: size,hotspot: hotspot)
    }
}

struct VectorCursorTexture {
    let texture: MTLTexture
    let size: CGSize
    let hotspot: CGPoint
    init(style: VectorCursorStyle,device: MTLDevice) throws {
        let artwork=try VectorCursorLibrary.artwork(style)
        texture=try generatedSRGBTexture(artwork.image,device: device)
        size=artwork.sizePoints; hotspot=artwork.hotspot
    }
}
