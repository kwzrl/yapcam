import Foundation

enum MotionBlurPolicy {
    /// Shared scale for global blur and our retained per-kind overrides. Export
    /// rates and the fixed preview refresh target are all at most 60 fps.
    static func strengths(frame: YcFrame, configuration c: RenderConfiguration,
                          framesPerSecond: Int, enabled: Bool) -> SIMD3<Float> {
        guard enabled else { return .zero }
        let rate=Float(framesPerSecond)/60
        return SIMD3(c.zoomMotionBlur ?? frame.motion_blur,
                     c.panMotionBlur ?? frame.motion_blur,c.cursorMotionBlur)*rate
    }
}
