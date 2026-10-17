import CoreGraphics
import Foundation
import Metal

public enum VectorCursorStyle: String, CaseIterable, Sendable {
    case arrow, pointer, touch, text
    case resizeHorizontal, resizeVertical, resizeDiagonalNWSE, resizeDiagonalNESW
    case openHand, closedHand
    case crosshair, notAllowed
    public var shapeID: String {
        switch self {
        case .pointer: "pointing_hand"
        case .resizeHorizontal: "resize_horizontal"
        case .resizeVertical: "resize_vertical"
        case .resizeDiagonalNWSE: "resize_diagonal_nwse"
        case .resizeDiagonalNESW: "resize_diagonal_nesw"
        case .openHand: "open_hand"
        case .closedHand: "closed_hand"
        case .notAllowed: "not_allowed"
        default: rawValue
        }
    }
    public init?(shapeID: String) {
        guard let style = Self.allCases.first(where: { $0.shapeID == shapeID }) else { return nil }
        self = style
    }
}
public enum VectorCursorVariant: String, CaseIterable, Codable, Sendable { case standard, alternate }
/// Logical cursor size, independent of raster density and the project's animated scale.
public enum VectorCursorSize: String, CaseIterable, Sendable {
    case small, regular, large, extraLarge
    public var multiplier: CGFloat {
        switch self { case .small: 0.75; case .regular: 1; case .large: 1.5; case .extraLarge: 2 }
    }
}
public struct VectorCursorArtwork: @unchecked Sendable {
    public let image: CGImage
    public let sizePoints: CGSize
    public let hotspot: CGPoint
    public init(image: CGImage,sizePoints: CGSize,hotspot: CGPoint) { self.image=image; self.sizePoints=sizePoints; self.hotspot=hotspot }
}
/// Original geometric artwork; no system/reference cursor image is copied into this library.
public enum VectorCursorLibrary {
    public static func artwork(_ style: VectorCursorStyle,size: VectorCursorSize = .regular,scale: CGFloat = 2) throws -> VectorCursorArtwork {
        try artwork(style,preset: presets[0],size: size,scale: scale)
    }
    static func artwork(_ style: VectorCursorStyle,preset: VectorCursorSet,size cursorSize: VectorCursorSize = .regular,scale: CGFloat,
                        variant: VectorCursorVariant = .standard,pressed: Bool = false,heightPoints: CGFloat? = nil) throws -> VectorCursorArtwork {
        guard scale.isFinite, (1...8).contains(scale) else { throw RenderError.invalidSettings("Cursor raster scale must be 1…8") }
        let size: CGSize, hotspot: CGPoint
        switch style {
        case .arrow: size=CGSize(width: 24,height: 32); hotspot=CGPoint(x: 3,y: 3)
        case .pointer: size=CGSize(width: 28,height: 32); hotspot=CGPoint(x: 12,y: 3)
        case .text: size=CGSize(width: 24,height: 32); hotspot=CGPoint(x: 12,y: 16)
        case .touch,.resizeHorizontal,.resizeVertical,.resizeDiagonalNWSE,.resizeDiagonalNESW,.openHand,.closedHand,.crosshair,.notAllowed:
            size=CGSize(width: 32,height: 32); hotspot=CGPoint(x: 16,y: 16)
        }
        if let heightPoints { guard heightPoints.isFinite,(16...128).contains(heightPoints) else { throw RenderError.invalidSettings("Cursor height must be 16…128 points") } }
        let factor=heightPoints.map { $0/size.height } ?? cursorSize.multiplier
        let logicalSize=CGSize(width: size.width*factor,height: size.height*factor)
        let logicalHotspot=CGPoint(x: hotspot.x*factor,y: hotspot.y*factor)
        let width=Int((logicalSize.width*scale).rounded()), height=Int((logicalSize.height*scale).rounded())
        guard let space=CGColorSpace(name: CGColorSpace.sRGB),let context=CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: space,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { throw RenderError.write("Cannot rasterize cursor artwork") }
        context.translateBy(x: 0,y: CGFloat(height)); context.scaleBy(x: scale*factor,y: -scale*factor)
        context.setShouldAntialias(true); context.setLineJoin(.round); context.setLineCap(.round)
        func color(_ value: SIMD4<Float>) -> CGColor {
            CGColor(colorSpace: space,components: [CGFloat(value.x),CGFloat(value.y),CGFloat(value.z),CGFloat(value.w)])!
        }
        let classic=preset.id=="classic", weight=CGFloat(preset.weight)
        if !classic || variant != .standard || style == .crosshair || style == .notAllowed || (style == .touch && pressed) {
            drawAuthoredCursor(style,preset: preset,variant: variant,pressed: pressed,in: context,space: space)
            guard let image=context.makeImage() else { throw RenderError.write("Cannot create vector cursor image") }
            return VectorCursorArtwork(image: image,sizePoints: logicalSize,hotspot: logicalHotspot)
        }
        let path=CGMutablePath()
        switch style {
        case .arrow:
            path.move(to: CGPoint(x: 3,y: 3))
            switch preset.arrow {
            case .standard:
                for point in [CGPoint(x: 3,y: 24),CGPoint(x: 8,y: 19),CGPoint(x: 12,y: 29),CGPoint(x: 16,y: 27),CGPoint(x: 12,y: 17),CGPoint(x: 21,y: 17)] { path.addLine(to: point) }
            case .rounded:
                path.addLine(to: CGPoint(x: 3,y: 22.5))
                path.addQuadCurve(to: CGPoint(x: 4.7,y: 23.2),control: CGPoint(x: 3,y: 25))
                path.addLine(to: CGPoint(x: 8.3,y: 19.8)); path.addLine(to: CGPoint(x: 12.4,y: 28.5))
                path.addQuadCurve(to: CGPoint(x: 14,y: 29.1),control: CGPoint(x: 13,y: 30))
                path.addLine(to: CGPoint(x: 16,y: 28.1))
                path.addQuadCurve(to: CGPoint(x: 16.5,y: 26.5),control: CGPoint(x: 17,y: 28))
                path.addLine(to: CGPoint(x: 12.4,y: 17.6)); path.addLine(to: CGPoint(x: 20.2,y: 17.6))
                path.addQuadCurve(to: CGPoint(x: 20.5,y: 16),control: CGPoint(x: 22,y: 17))
            case .narrow:
                for point in [CGPoint(x: 3,y: 25),CGPoint(x: 7.5,y: 18.5),CGPoint(x: 11,y: 26),CGPoint(x: 14,y: 24.5),CGPoint(x: 10.7,y: 16),CGPoint(x: 20,y: 16)] { path.addLine(to: point) }
            }
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(classic ? CGColor(gray: 0.08,alpha: 1) : color(preset.arrowFill))
            context.setStrokeColor(classic ? CGColor(gray: 1,alpha: 1) : color(preset.outline))
            context.setLineWidth(weight); context.drawPath(using: .fillStroke)
        case .pointer:
            let tipY: CGFloat=cursorSize == .small ? 3 : 2
            path.move(to: CGPoint(x: 12,y: tipY))
            path.addCurve(to: CGPoint(x: 10,y: 6),control1: CGPoint(x: 10,y: tipY),control2: CGPoint(x: 10,y: 4))
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
            path.addCurve(to: CGPoint(x: 12,y: tipY),control1: CGPoint(x: 14,y: max(3,tipY)),control2: CGPoint(x: 14,y: tipY)); path.closeSubpath()
            context.addPath(path)
            context.setFillColor(classic ? CGColor(gray: 1,alpha: 1) : color(preset.handFill))
            context.setStrokeColor(classic ? CGColor(gray: 0.08,alpha: 1) : color(preset.handOutline))
            context.setLineWidth(weight*0.7); context.drawPath(using: .fillStroke)
            context.move(to: CGPoint(x: 17,y: 13)); context.addLine(to: CGPoint(x: 17,y: 18)); context.move(to: CGPoint(x: 21,y: 16)); context.addLine(to: CGPoint(x: 21,y: 20)); context.setLineWidth(weight*0.4); context.strokePath()
        case .text:
            // Our symmetrical I-beam: two opposing serif pairs and a central stem.
            path.move(to: CGPoint(x: 6,y: 4)); path.addLine(to: CGPoint(x: 9,y: 4))
            path.addQuadCurve(to: CGPoint(x: 12,y: 7),control: CGPoint(x: 12,y: 4))
            path.addQuadCurve(to: CGPoint(x: 15,y: 4),control: CGPoint(x: 12,y: 4))
            path.addLine(to: CGPoint(x: 18,y: 4))
            path.move(to: CGPoint(x: 12,y: 7)); path.addLine(to: CGPoint(x: 12,y: 25))
            path.move(to: CGPoint(x: 6,y: 28)); path.addLine(to: CGPoint(x: 9,y: 28))
            path.addQuadCurve(to: CGPoint(x: 12,y: 25),control: CGPoint(x: 12,y: 28))
            path.addQuadCurve(to: CGPoint(x: 15,y: 28),control: CGPoint(x: 12,y: 28))
            path.addLine(to: CGPoint(x: 18,y: 28))
            context.addPath(path); context.setStrokeColor(color(preset.outline))
            context.setLineWidth(weight+2.2); context.strokePath()
            context.addPath(path); context.setStrokeColor(color(preset.arrowFill))
            context.setLineWidth(max(1,weight*0.7)); context.strokePath()
        case .resizeHorizontal,.resizeVertical,.resizeDiagonalNWSE,.resizeDiagonalNESW:
            // Double-ended shaft, rotated about the action point. The contour and
            // outline are authored here; no NSCursor/system artwork is sampled.
            context.saveGState(); context.translateBy(x: 16,y: 16)
            let angle: CGFloat
            switch style {
            case .resizeVertical: angle = .pi/2
            case .resizeDiagonalNWSE: angle = .pi/4
            case .resizeDiagonalNESW: angle = -.pi/4
            default: angle = 0
            }
            context.rotate(by: angle); context.translateBy(x: -16,y: -16)
            path.move(to: CGPoint(x: 3,y: 16))
            for point in [CGPoint(x: 10,y: 9),CGPoint(x: 10,y: 13),CGPoint(x: 22,y: 13),
                          CGPoint(x: 22,y: 9),CGPoint(x: 29,y: 16),CGPoint(x: 22,y: 23),
                          CGPoint(x: 22,y: 19),CGPoint(x: 10,y: 19),CGPoint(x: 10,y: 23)] { path.addLine(to: point) }
            path.closeSubpath(); context.addPath(path)
            context.setFillColor(color(preset.arrowFill)); context.setStrokeColor(color(preset.outline))
            context.setLineWidth(weight*0.65); context.drawPath(using: .fillStroke)
            context.restoreGState()
        case .openHand,.closedHand:
            if style == .openHand {
                path.move(to: CGPoint(x: 8,y: 18)); path.addLine(to: CGPoint(x: 6,y: 14))
                path.addCurve(to: CGPoint(x: 3,y: 17),control1: CGPoint(x: 3,y: 11),control2: CGPoint(x: 1.5,y: 14))
                path.addLine(to: CGPoint(x: 8,y: 25)); path.addQuadCurve(to: CGPoint(x: 12,y: 29),control: CGPoint(x: 9,y: 28))
                path.addLine(to: CGPoint(x: 23,y: 29)); path.addQuadCurve(to: CGPoint(x: 28,y: 21),control: CGPoint(x: 27,y: 27))
                path.addLine(to: CGPoint(x: 29,y: 11)); path.addCurve(to: CGPoint(x: 25,y: 11),control1: CGPoint(x: 29,y: 7),control2: CGPoint(x: 25,y: 7))
                path.addLine(to: CGPoint(x: 24,y: 18)); path.addLine(to: CGPoint(x: 24,y: 6))
                path.addCurve(to: CGPoint(x: 20,y: 6),control1: CGPoint(x: 24,y: 2),control2: CGPoint(x: 20,y: 2))
                path.addLine(to: CGPoint(x: 19,y: 16)); path.addLine(to: CGPoint(x: 19,y: 4))
                path.addCurve(to: CGPoint(x: 15,y: 4),control1: CGPoint(x: 19,y: 2),control2: CGPoint(x: 15,y: 2))
                path.addLine(to: CGPoint(x: 14,y: 16)); path.addLine(to: CGPoint(x: 13,y: 7))
                path.addCurve(to: CGPoint(x: 9,y: 8),control1: CGPoint(x: 12,y: 3),control2: CGPoint(x: 8,y: 4))
                path.addLine(to: CGPoint(x: 10,y: 19))
            } else {
                path.move(to: CGPoint(x: 6,y: 16)); path.addLine(to: CGPoint(x: 5,y: 12))
                path.addCurve(to: CGPoint(x: 11,y: 10),control1: CGPoint(x: 4,y: 7),control2: CGPoint(x: 10,y: 6))
                path.addCurve(to: CGPoint(x: 16,y: 8),control1: CGPoint(x: 11,y: 5),control2: CGPoint(x: 16,y: 5))
                path.addCurve(to: CGPoint(x: 22,y: 9),control1: CGPoint(x: 18,y: 5),control2: CGPoint(x: 22,y: 6))
                path.addCurve(to: CGPoint(x: 27,y: 13),control1: CGPoint(x: 25,y: 7),control2: CGPoint(x: 28,y: 10))
                path.addLine(to: CGPoint(x: 27,y: 21)); path.addQuadCurve(to: CGPoint(x: 23,y: 28),control: CGPoint(x: 27,y: 26))
                path.addLine(to: CGPoint(x: 11,y: 28)); path.addQuadCurve(to: CGPoint(x: 7,y: 24),control: CGPoint(x: 8,y: 27))
                path.addLine(to: CGPoint(x: 3,y: 19)); path.addCurve(to: CGPoint(x: 6,y: 16),control1: CGPoint(x: 2,y: 16),control2: CGPoint(x: 3,y: 14))
                path.addLine(to: CGPoint(x: 12,y: 19))
            }
            path.closeSubpath(); context.addPath(path)
            context.setFillColor(color(preset.handFill)); context.setStrokeColor(color(preset.handOutline))
            context.setLineWidth(weight*0.7); context.drawPath(using: .fillStroke)
            context.setLineWidth(max(0.6,weight*0.35))
            if style == .closedHand {
                for x: CGFloat in [11,16,21] { context.move(to: CGPoint(x: x,y: 11)); context.addLine(to: CGPoint(x: x,y: 16)) }
            }
            context.move(to: CGPoint(x: 12,y: 22)); context.addQuadCurve(to: CGPoint(x: 22,y: 21),control: CGPoint(x: 18,y: 19))
            context.strokePath()
        case .touch:
            context.setFillColor(classic ? CGColor(gray: 1,alpha: 0.55) : color(preset.touchFill))
            context.setStrokeColor(classic ? CGColor(gray: 0.15,alpha: 0.7) : color(preset.touchOutline))
            context.setLineWidth(weight*0.75)
            if preset.touch == .disc { context.fillEllipse(in: CGRect(x: 5,y: 5,width: 22,height: 22)) }
            let ring=CGRect(x: 4,y: 4,width: 24,height: 24)
            if !classic {
                // An opposite-luminance halo keeps original touch marks legible on both canvases.
                let lightOutline=preset.touchOutline.x+preset.touchOutline.y+preset.touchOutline.z>1.5
                context.setStrokeColor(CGColor(gray: lightOutline ? 0.05 : 0.95,alpha: 0.65))
                context.setLineWidth(weight*0.75+1.5); context.strokeEllipse(in: ring)
                context.setStrokeColor(color(preset.touchOutline)); context.setLineWidth(weight*0.75)
            }
            context.strokeEllipse(in: ring)
            if preset.touch == .ring {
                context.setFillColor(color(preset.arrowFill)); context.fillEllipse(in: CGRect(x: 14,y: 14,width: 4,height: 4))
            } else if preset.touch == .target {
                let target=CGMutablePath()
                target.move(to: CGPoint(x: 8,y: 16)); target.addLine(to: CGPoint(x: 24,y: 16))
                target.move(to: CGPoint(x: 16,y: 8)); target.addLine(to: CGPoint(x: 16,y: 24))
                context.addPath(target); context.setStrokeColor(color(preset.outline)); context.setLineWidth(max(1,weight*0.6)+1.5); context.strokePath()
                context.addPath(target); context.setStrokeColor(color(preset.arrowFill)); context.setLineWidth(max(1,weight*0.6)); context.strokePath()
            }
        case .crosshair,.notAllowed: break // Authored above, including the classic set.
        }
        guard let image=context.makeImage() else { throw RenderError.write("Cannot create vector cursor image") }
        return VectorCursorArtwork(image: image,sizePoints: logicalSize,hotspot: logicalHotspot)
    }
}

struct VectorCursorTexture {
    let texture: MTLTexture
    let size: CGSize
    let hotspot: CGPoint
    init(style: VectorCursorStyle,preset: VectorCursorSet,size: VectorCursorSize,scale: CGFloat,variant: VectorCursorVariant = .standard,pressed: Bool = false,heightPoints: CGFloat? = nil,device: MTLDevice) throws {
        let artwork=try VectorCursorLibrary.artwork(style,preset: preset,size: size,scale: scale,variant: variant,pressed: pressed,heightPoints: heightPoints)
        texture=try generatedSRGBTexture(artwork.image,device: device)
        self.size=artwork.sizePoints; hotspot=artwork.hotspot
    }
}
