import Foundation
import YapcamCore

extension RenderConfiguration {
    mutating func applyCameraStyle(_ style: CameraStyle, package: URL) throws {
        let grade=style.preset != "original" && style.preset != "lut"
        cameraColor=CameraColorSettings(
            lutURL: try style.preset == "lut" ? style.lutPath.map { try packageMediaURL($0,root: package) } : nil,
            intensity: Float(style.intensity),warmth: grade ? Float(style.warmth) : 0,
            contrast: grade ? Float(style.contrast) : 0,colorIntensity: grade ? Float(style.colorIntensity) : 0,
            sharpen: Float(style.sharpen),grain: Float(style.grain))
        guard style.crop.count==4 else { throw RenderError.invalidSettings("Camera crop must have four components") }
        cameraCrop=SIMD4(Float(style.crop[0]),Float(style.crop[1]),Float(style.crop[2]),Float(style.crop[3]))
        cameraBackgroundPop=grade ? Float(style.backgroundPop*style.intensity) : 0
        cameraBackgroundBlur=Float(style.backgroundBlur)
        try cameraColor.validate(); try validateCameraGeometry()
    }
    func validateCameraGeometry() throws {
        let r=cameraCrop
        guard (0...1).contains(cameraBackgroundPop), (0...1).contains(cameraBackgroundBlur),
              [r.x,r.y,r.z,r.w].allSatisfy(\.isFinite), r.x>=0, r.y>=0, r.z>0, r.w>0,
              r.x+r.z<=1.000001, r.y+r.w<=1.000001 else { throw RenderError.invalidSettings("Camera crop or background controls are invalid") }
    }
}
