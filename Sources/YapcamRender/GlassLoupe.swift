import Foundation

/// Evaluated local lens over an unzoomed frame. Coordinates are canvas pixels
/// for center/radius and normalized full-source coordinates for sourceCenter.
public struct GlassLoupeInstruction: Sendable, Equatable, Codable {
    public var center: SIMD2<Float>
    public var sourceCenter: SIMD2<Float>
    public var scale: Float
    public var radiusPixels: Float
    public var opacity: Float
    public init(center: SIMD2<Float>,sourceCenter: SIMD2<Float>,scale: Float,radiusPixels: Float,opacity: Float) {
        self.center=center; self.sourceCenter=sourceCenter; self.scale=scale; self.radiusPixels=radiusPixels; self.opacity=opacity
    }
    func validate() throws {
        guard center.x.isFinite,center.y.isFinite,(0...1).contains(sourceCenter.x),(0...1).contains(sourceCenter.y),
              scale.isFinite,scale>=1,radiusPixels.isFinite,radiusPixels>0,(0...1).contains(opacity) else {
            throw RenderError.invalidSettings("Evaluated lens geometry is invalid")
        }
    }
}

/// Original circular magnifier over the full screen image. Radius is a fraction
/// of the shorter displayed screen edge; focus/magnification use the shared crop.
public struct GlassLoupeSettings: Sendable, Equatable, Codable {
    public var radius: Float
    public var bevel: Float
    public var chromaticAberration: Float
    /// The user's source crop before zoom, so the lens never exposes cropped-out pixels.
    public var baseCrop: SIMD4<Float>
    public var instruction: GlassLoupeInstruction?
    public init(radius: Float = 0.35, bevel: Float = 0.2, chromaticAberration: Float = 0.5, baseCrop: SIMD4<Float> = SIMD4(0,0,1,1),instruction: GlassLoupeInstruction? = nil) {
        self.radius = radius; self.bevel = bevel; self.chromaticAberration = chromaticAberration
        self.baseCrop = baseCrop
        self.instruction=instruction
    }
    public func validate() throws {
        try instruction?.validate()
        guard (0.25...0.75).contains(radius), (0...1).contains(bevel), (0...1).contains(chromaticAberration),
              (0..<4).allSatisfy({ baseCrop[$0].isFinite }), baseCrop.x >= 0, baseCrop.y >= 0, baseCrop.z > 0, baseCrop.w > 0,
              baseCrop.x+baseCrop.z <= 1.000001, baseCrop.y+baseCrop.w <= 1.000001 else { throw RenderError.invalidSettings("Glass magnifier settings are outside their supported ranges") }
    }
    private enum CodingKeys: String, CodingKey { case radius, bevel, chromaticAberration, baseCrop, instruction }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(radius: try c.decodeIfPresent(Float.self,forKey: .radius) ?? 0.35,
                  bevel: try c.decodeIfPresent(Float.self,forKey: .bevel) ?? 0.2,
                  chromaticAberration: try c.decodeIfPresent(Float.self,forKey: .chromaticAberration) ?? 0.5,
                  baseCrop: try c.decodeIfPresent(SIMD4<Float>.self,forKey: .baseCrop) ?? SIMD4(0,0,1,1),
                  instruction: try c.decodeIfPresent(GlassLoupeInstruction.self,forKey: .instruction))
        try validate()
    }
    func geometry(_ frame: YcFrame) -> (radius: Float, focus: SIMD2<Float>, scale: Float, opacity: Float) {
        if let instruction { return (instruction.radiusPixels,instruction.sourceCenter,instruction.scale,instruction.opacity) }
        let crop = frame.screen_crop
        guard crop.w > 0, crop.h > 0 else { return (0,SIMD2(0.5,0.5),1,0) }
        let focus = SIMD2(Float(crop.x+crop.w/2),Float(crop.y+crop.h/2))
        let scale = max(1,min(baseCrop.z/Float(crop.w),baseCrop.w/Float(crop.h)))
        return (radius*Float(min(frame.screen_dest.w,frame.screen_dest.h)),focus,scale,min(1,max(0,(scale-1)/0.08)))
    }
    func samplingBase(_ frame: YcFrame) -> SIMD4<Float> {
        instruction == nil ? baseCrop : SIMD4(Float(frame.screen_crop.x),Float(frame.screen_crop.y),Float(frame.screen_crop.w),Float(frame.screen_crop.h))
    }
}
