import Foundation

/// Original circular magnifier over the full screen image. Radius is a fraction
/// of the shorter displayed screen edge; focus/magnification use the shared crop.
public struct GlassLoupeSettings: Sendable, Equatable, Codable {
    public var radius: Float
    public var bevel: Float
    public var chromaticAberration: Float
    public init(radius: Float = 0.35, bevel: Float = 0.2, chromaticAberration: Float = 0.5) {
        self.radius = radius; self.bevel = bevel; self.chromaticAberration = chromaticAberration
    }
    public func validate() throws {
        guard (0.25...0.75).contains(radius), (0...1).contains(bevel), (0...1).contains(chromaticAberration) else { throw RenderError.invalidSettings("Glass magnifier settings are outside their supported ranges") }
    }
    private enum CodingKeys: String, CodingKey { case radius, bevel, chromaticAberration }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(radius: try c.decodeIfPresent(Float.self,forKey: .radius) ?? 0.35,
                  bevel: try c.decodeIfPresent(Float.self,forKey: .bevel) ?? 0.2,
                  chromaticAberration: try c.decodeIfPresent(Float.self,forKey: .chromaticAberration) ?? 0.5)
        try validate()
    }
    func geometry(_ frame: YcFrame) -> (radius: Float, focus: SIMD2<Float>, scale: Float, opacity: Float) {
        let crop = frame.screen_crop
        let focus = SIMD2(Float(crop.x+crop.w/2),Float(crop.y+crop.h/2))
        let scale = max(1,1/Float(min(crop.w,crop.h)))
        return (radius*Float(min(frame.screen_dest.w,frame.screen_dest.h)),focus,scale,min(1,max(0,(scale-1)/0.08)))
    }
}
