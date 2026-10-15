import Foundation
import CoreGraphics

/// Compatible cold bridge: Core evaluates geometry/timing for highlights and UTF-8 payloads.
/// Highlights and final fade are included here; never draw a second extras prefix alongside it.
struct CoreDrawingLayer: Decodable {
    let kind: String
    let rect: [Double]
    let cornerRadius: Float
    let opacity: Float
    let dimOpacity: Float
    let fill: [Float]
    let stroke: [Float]
    let strokeWidth: Float
    let text: String?
    let fontSize: Double?
    let fontFamily: RenderTextFontFamily?
    let color: [Float]?
    func drawingLayer() throws -> RenderLayer {
        guard rect.count==4,rect.allSatisfy({ $0.isFinite }),rect[2]>0,rect[3]>0 else { throw RenderError.invalidSettings("Core drawing layer has invalid geometry") }
        func rgba(_ values: [Float]) throws -> SIMD4<Float> {
            guard values.count==4,values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw RenderError.invalidSettings("Core drawing layer has invalid color") }
            return SIMD4(values[0],values[1],values[2],values[3])
        }
        let content: RenderLayer.Content
        switch kind {
        case "highlight": content = .highlight(dimOpacity: dimOpacity,fill: try rgba(fill),stroke: try rgba(stroke),strokeWidth: strokeWidth)
        case "text":
            guard let text,let fontSize,let color,fontSize.isFinite,fontSize>0 else { throw RenderError.invalidSettings("Core text drawing instruction is incomplete") }
            content = .text(text,fontSize: fontSize,color: try rgba(color))
        default: throw RenderError.unavailable("Unsupported Core drawing layer kind: \(kind)")
        }
        return RenderLayer(content: content,rect: CGRect(x: rect[0],y: rect[1],width: rect[2],height: rect[3]),cornerRadius: cornerRadius,opacity: opacity,
                           textFontFamily: fontFamily ?? .sans)
    }
}
