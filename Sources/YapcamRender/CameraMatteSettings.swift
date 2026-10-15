import Foundation

public struct CameraMatteSettings: Sendable, Equatable, Codable {
    public var edgeSoftness: Float
    /// Erode the person mask by 0...8 canvas pixels, before camera compositing.
    public var edgeInsetPixels: Float
    public init(edgeSoftness: Float = 0.2, edgeInsetPixels: Float = 0) {
        self.edgeSoftness=edgeSoftness; self.edgeInsetPixels=edgeInsetPixels
    }
    public func validate() throws {
        guard (0...1).contains(edgeSoftness), (0...8).contains(edgeInsetPixels) else { throw RenderError.invalidSettings("Camera matte softness/inset is outside its supported range") }
    }
    private enum CodingKeys: String,CodingKey { case edgeSoftness, edgeInsetPixels }
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy: CodingKeys.self)
        self.init(edgeSoftness: try c.decodeIfPresent(Float.self,forKey: .edgeSoftness) ?? 0.2,
                  edgeInsetPixels: try c.decodeIfPresent(Float.self,forKey: .edgeInsetPixels) ?? 0)
        try validate()
    }
    /// Confidence-ramp oracle independent of the native Vision segmentation.
    func alpha(_ confidence: Float) -> Float {
        if edgeSoftness==0 { return confidence>=0.5 ? 1 : 0 }
        let t=min(1,max(0,(confidence-(0.5-edgeSoftness*0.5))/edgeSoftness))
        return t*t*(3-2*t)
    }
}
