import CoreGraphics
import Foundation

public struct CursorSetDescriptor: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case recorded, touch, vector }
    public let id: String
    public let name: String
    public let category: VectorCursorSet.Category
    public let kind: Kind
}
public struct CursorVariantDescriptor: Sendable, Equatable, Identifiable {
    public let id: VectorCursorVariant
    public let name: String
}

public extension VectorCursorLibrary {
    static func placement(sizePoints: CGSize,hotspot: CGPoint,at point: CGPoint,scale: CGFloat = 1) -> CGRect {
        CGRect(x: point.x-hotspot.x*scale,y: point.y-hotspot.y*scale,width: sizePoints.width*scale,height: sizePoints.height*scale)
    }
    /// Picker order. Original needs recording media; its generic thumbnail is not a captured cursor.
    static let catalog: [CursorSetDescriptor] = [
        .init(id: "original",name: "Original",category: .essential,kind: .recorded),
        .init(id: "touch",name: "Touch",category: .essential,kind: .touch)
    ] + presets.map { .init(id: $0.id,name: $0.title,category: $0.category,kind: .vector) }

    static func variants(for style: VectorCursorStyle) -> [CursorVariantDescriptor] {
        let names: (String,String)
        switch style {
        case .arrow: names = ("Arrow","Pen tip")
        case .pointer: names = ("Pointing hand","Slim pointing hand")
        case .text: names = ("I-beam","Compact I-beam")
        case .resizeHorizontal,.resizeVertical,.resizeDiagonalNWSE,.resizeDiagonalNESW: names = ("Joined arrows","Split chevrons")
        case .openHand: names = ("Spread hand","Compact hand")
        case .closedHand: names = ("Fist","Compact grip")
        case .crosshair: names = ("Cross","Separated cross")
        case .notAllowed: names = ("Circle","Octagon")
        case .touch: names = ("Soft disc","Concentric tap")
        }
        return [.init(id: .standard,name: names.0),.init(id: .alternate,name: names.1)]
    }

    /// Exact point height 16…128; raster density 1…8 is independent of the hotspot/size.
    static func artwork(_ style: VectorCursorStyle,setID: String,heightPoints: CGFloat,rasterScale: CGFloat = 2,
                        variant: VectorCursorVariant = .standard,pressed: Bool = false) throws -> VectorCursorArtwork {
        if setID == "original" { throw RenderError.missingMedia("Original cursor artwork requires the recording's cursor sidecar") }
        guard let preset = preset(id: setID) else { throw RenderError.invalidSettings("Unknown original cursor set: \(setID)") }
        return try artwork(setID == "touch" ? .touch : style,preset: preset,scale: rasterScale,variant: variant,pressed: pressed,heightPoints: heightPoints)
    }

    /// CPU-only picker thumbnail. Original optionally draws the actual recorded glyph;
    /// without it an authored image-frame pictogram indicates missing preview media.
    static func thumbnail(setID: String,size: CGSize = CGSize(width: 160,height: 100),
                          style: VectorCursorStyle = .arrow,variant: VectorCursorVariant = .standard,
                          recorded: VectorCursorArtwork? = nil) throws -> CGImage {
        guard catalog.contains(where: { $0.id == setID }),size.width.isFinite,size.height.isFinite,
              (32...512).contains(size.width),(32...512).contains(size.height),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,width: Int(size.width),height: Int(size.height),bitsPerComponent: 8,bytesPerRow: Int(size.width)*4,
                  space: space,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw RenderError.invalidSettings("Invalid cursor thumbnail selection or dimensions")
        }
        context.setFillColor(CGColor(srgbRed: 0.12,green: 0.15,blue: 0.2,alpha: 1)); context.fill(CGRect(origin: .zero,size: size))
        let art: VectorCursorArtwork?
        if setID == "original" { art = recorded }
        else { art = try artwork(style,setID: setID,heightPoints: min(48,size.height*0.58),rasterScale: 2,variant: variant) }
        if let art {
            let factor = min((size.width-16)/art.sizePoints.width,(size.height-16)/art.sizePoints.height,1)
            let dest = CGSize(width: art.sizePoints.width*factor,height: art.sizePoints.height*factor)
            context.draw(art.image,in: CGRect(x: (size.width-dest.width)/2,y: (size.height-dest.height)/2,width: dest.width,height: dest.height))
        } else {
            let rect = CGRect(x: size.width/2-18,y: size.height/2-13,width: 36,height: 26)
            context.setStrokeColor(CGColor(gray: 0.8,alpha: 1)); context.setLineWidth(1.5); context.stroke(rect)
            context.move(to: CGPoint(x: rect.minX+4,y: rect.minY+4)); context.addLine(to: CGPoint(x: rect.midX-3,y: rect.midY+3)); context.addLine(to: CGPoint(x: rect.midX+3,y: rect.minY+8)); context.addLine(to: CGPoint(x: rect.maxX-4,y: rect.midY+7)); context.strokePath()
            context.fillEllipse(in: CGRect(x: rect.minX+6,y: rect.maxY-9,width: 4,height: 4))
        }
        guard let result = context.makeImage() else { throw RenderError.write("Cannot rasterize cursor thumbnail") }
        return result
    }
}

extension VectorCursorArtwork {
    /// Canvas placement shared with the compositor. The action point is invariant
    /// under logical size, raster density, project scale, and rotation about it.
    public func rect(at point: CGPoint,scale: CGFloat = 1) -> CGRect {
        VectorCursorLibrary.placement(sizePoints: sizePoints,hotspot: hotspot,at: point,scale: scale)
    }
}
