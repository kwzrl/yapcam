import Foundation

/// Original spatial processing of the recorded screen; camera/text/cursor stay
/// separate. nil on RenderConfiguration preserves the legacy sampling path.
public struct ScreenQualitySettings: Sendable, Equatable, Codable {
    public enum Upscaling: String, Sendable, Codable, CaseIterable { case off, fast, quality }
    public var improveQuality: Float
    public var upscaling: Upscaling
    public init(improveQuality: Float = 0.5, upscaling: Upscaling = .quality) {
        self.improveQuality=improveQuality; self.upscaling=upscaling
    }
    public func validate() throws {
        guard (0...1).contains(improveQuality) else { throw RenderError.invalidSettings("Screen quality amount must be 0...1") }
    }
    private enum CodingKeys: String,CodingKey { case improveQuality, upscaling }
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy: CodingKeys.self)
        self.init(improveQuality: try c.decodeIfPresent(Float.self,forKey: .improveQuality) ?? 0.5,
                  upscaling: try c.decodeIfPresent(Upscaling.self,forKey: .upscaling) ?? .quality)
        try validate()
    }
    var uniforms: SIMD4<Float> { SIMD4(improveQuality,upscaling == .off ? 0 : upscaling == .fast ? 1 : 2,1,0) }
}
