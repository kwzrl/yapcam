import Foundation
import CoreGraphics
import YapcamCore

/// Compatible cold bridge: Core evaluates geometry/timing for highlights and UTF-8 payloads.
/// Highlights and final fade are included here; never draw a second extras prefix alongside it.
struct CoreDrawingLayer: Decodable {
    let id: String?
    let purpose: RenderLayer.Purpose?
    let kind: String
    let rect: [Double]
    let cornerRadius: Float
    let blurRadius: Double?
    let opacity: Float
    let dimOpacity: Float
    let fill: [Float]
    let stroke: [Float]
    let strokeWidth: Float
    let text: String?
    let fontSize: Double?
    let fontFamily: RenderTextFontFamily?
    let caption: CoreCaptionEvaluation?
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
        case "blur":
            let radius=blurRadius ?? 32
            guard radius.isFinite,(0...128).contains(radius) else { throw RenderError.invalidSettings("Core mask blur radius must be 0...128 canvas pixels") }
            content = .blur(radius: Float(radius))
        case "text":
            guard let text,let fontSize,let color,fontSize.isFinite,fontSize>0 else { throw RenderError.invalidSettings("Core text drawing instruction is incomplete") }
            content = .text(text,fontSize: fontSize,color: try rgba(color))
        default: throw RenderError.unavailable("Unsupported Core drawing layer kind: \(kind)")
        }
        if let caption { try validateCaption(caption) }
        // Preserve the exact old raster path for line/full captions, including
        // line fade/slide that Core has already applied to opacity/geometry.
        let advanced = caption.flatMap { $0.reveal == .word || $0.growth != .full ? $0 : nil }
        let layer=RenderLayer(content: content,rect: CGRect(x: rect[0],y: rect[1],width: rect[2],height: rect[3]),cornerRadius: cornerRadius,opacity: opacity,
                           textFontFamily: fontFamily ?? caption.flatMap { RenderTextFontFamily(rawValue: $0.fontFamily.rawValue) } ?? .sans,
                           caption: advanced,purpose: purpose ?? .unspecified)
        try layer.validatePurpose()
        return layer
    }
}

func coreDrawingLayers(_ rows: [CoreDrawingLayer]) throws -> [RenderLayer] {
    var layers = try rows.map { try $0.drawingLayer() }
    // Core's paired background precedes its text. Match explicit IDs, so an
    // unrelated highlight or final fade is never resized by caption growth.
    var backgrounds: [String: Int] = [:]
    for (index,row) in rows.enumerated() {
        if row.kind == "highlight", let id = row.id { backgrounds[id] = index }
        guard let caption = layers[index].caption, let id = row.id,
              case .text(_,let size,_) = layers[index].content,
              let background = backgrounds[id + ":background"] else { continue }
        let layout = try CaptionLayoutCache.shared.layout(caption,fontSize: size,family: layers[index].textFontFamily,size: layers[index].rect.size)
        layers[background].rect = layout.fittedRect(layers[background].rect,growth: caption.growth)
    }
    return layers
}

func validateCaption(_ caption: CoreCaptionEvaluation) throws {
    func normalized(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
    let full = normalized(caption.fullText)
    let joined = normalized(caption.words.map(\.text).joined(separator: " "))
    let visible = caption.reveal == .line ? full : normalized(caption.words.filter(\.visible).map(\.text).joined(separator: " "))
    guard !full.isEmpty, full == joined, normalized(caption.visibleText) == visible,
          caption.lineOpacity.isFinite, (0...1).contains(caption.lineOpacity),
          caption.lineOffsetY.isFinite, (0...0.25).contains(caption.lineOffsetY),
          caption.words.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
              $0.progress.isFinite && (0...1).contains($0.progress) &&
              $0.opacity.isFinite && (0...1).contains($0.opacity) &&
              $0.offsetY.isFinite && (0...0.25).contains($0.offsetY) }) else {
        throw RenderError.invalidSettings("Invalid evaluated caption instruction")
    }
}
