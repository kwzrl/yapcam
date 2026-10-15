import Foundation

/// Original circular magnifier over the full screen image. Radius is a fraction
/// of the shorter displayed screen edge; focus/magnification use the shared crop.
public struct GlassLoupeSettings: Sendable, Equatable, Codable {
    public var radius: Float
    public var bevel: Float
    public var chromaticAberration: Float
    /// The user's source crop before zoom, so the lens never exposes cropped-out pixels.
    public var baseCrop: SIMD4<Float>
    public init(radius: Float = 0.35, bevel: Float = 0.2, chromaticAberration: Float = 0.5, baseCrop: SIMD4<Float> = SIMD4(0,0,1,1)) {
        self.radius = radius; self.bevel = bevel; self.chromaticAberration = chromaticAberration
        self.baseCrop = baseCrop
    }
    public func validate() throws {
        guard (0.25...0.75).contains(radius), (0...1).contains(bevel), (0...1).contains(chromaticAberration),
              (0..<4).allSatisfy({ baseCrop[$0].isFinite }), baseCrop.x >= 0, baseCrop.y >= 0, baseCrop.z > 0, baseCrop.w > 0,
              baseCrop.x+baseCrop.z <= 1.000001, baseCrop.y+baseCrop.w <= 1.000001 else { throw RenderError.invalidSettings("Glass magnifier settings are outside their supported ranges") }
    }
    private enum CodingKeys: String, CodingKey { case radius, bevel, chromaticAberration, baseCrop }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(radius: try c.decodeIfPresent(Float.self,forKey: .radius) ?? 0.35,
                  bevel: try c.decodeIfPresent(Float.self,forKey: .bevel) ?? 0.2,
                  chromaticAberration: try c.decodeIfPresent(Float.self,forKey: .chromaticAberration) ?? 0.5,
                  baseCrop: try c.decodeIfPresent(SIMD4<Float>.self,forKey: .baseCrop) ?? SIMD4(0,0,1,1))
        try validate()
    }
    func geometry(_ frame: YcFrame) -> (radius: Float, focus: SIMD2<Float>, scale: Float, opacity: Float) {
        let crop = frame.screen_crop
        guard crop.w > 0, crop.h > 0 else { return (0,SIMD2(0.5,0.5),1,0) }
        let focus = SIMD2(Float(crop.x+crop.w/2),Float(crop.y+crop.h/2))
        let scale = max(1,min(baseCrop.z/Float(crop.w),baseCrop.w/Float(crop.h)))
        return (radius*Float(min(frame.screen_dest.w,frame.screen_dest.h)),focus,scale,min(1,max(0,(scale-1)/0.08)))
    }
}
