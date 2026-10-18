import Foundation
import YapcamCore

/// Optional additions on the existing evaluated query. Old projects/Core return
/// no additions and retain classic zoom and unmodified camera pixels.
struct ProjectRenderOptions: Decodable {
    let base: ProjectRenderBaseOptions
    let glassLoupe: GlassLoupeSettings?
    let cameraColor: CameraColorQuery?
    let insetOrigin: SIMD2<Float>?
    let screenQuality: ScreenQualitySettings?
    let cameraMatte: CameraMatteSettings?
    let cameraSourceCrop: SIMD4<Float>?
    let screenOpacity: Float?
    let cameraBlur: Float?
    let cursorClickEffect: RenderConfiguration.CursorClickEffect?
    let cursorClickDurationNs: Int64?
    private enum CodingKeys: String, CodingKey {
        case glassLoupe, cameraColor, cameraMatte, insetOrigin, screenQuality
        case cameraSourceCrop, screenOpacity, cameraBlur
        case cursorClickEffect, cursorClickDurationNs
    }
    init(from decoder: Decoder) throws {
        base = try ProjectRenderBaseOptions(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        glassLoupe = try c.decodeIfPresent(GlassLoupeSettings.self,forKey: .glassLoupe)
        cameraColor = try c.decodeIfPresent(CameraColorQuery.self,forKey: .cameraColor)
        insetOrigin = try c.decodeIfPresent([Double].self,forKey: .insetOrigin).map { values in
            guard values.count==2,values.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
                throw RenderError.invalidSettings("Core returned an invalid inset origin")
            }
            return SIMD2(Float(values[0]),Float(values[1]))
        }
        screenQuality = try c.decodeIfPresent(ProjectScreenQuality.self,forKey: .screenQuality).map { quality in
            guard quality.improveQuality.isFinite,(0...1).contains(quality.improveQuality) else {
                throw RenderError.invalidSettings("Core returned an invalid screen quality amount")
            }
            return ScreenQualitySettings(improveQuality: Float(quality.improveQuality),upscaling: quality.upscaling)
        }
        cameraMatte = try c.decodeIfPresent(CameraMatteSettings.self,forKey: .cameraMatte)
        cameraSourceCrop = try c.decodeIfPresent([Double].self,forKey: .cameraSourceCrop).map { values in
            guard values.count==4,values.allSatisfy(\.isFinite),
                  values[0]>=0,values[1]>=0,values[2]>0,values[3]>0,
                  values[0]+values[2]<=1.000_001,values[1]+values[3]<=1.000_001 else {
                throw RenderError.invalidSettings("Core returned an invalid camera source crop")
            }
            return SIMD4(Float(values[0]),Float(values[1]),Float(values[2]),Float(values[3]))
        }
        screenOpacity = try c.decodeIfPresent(Float.self,forKey: .screenOpacity)
        cameraBlur = try c.decodeIfPresent(Float.self,forKey: .cameraBlur)
        cursorClickEffect = try c.decodeIfPresent(RenderConfiguration.CursorClickEffect.self,forKey: .cursorClickEffect)
        cursorClickDurationNs = try c.decodeIfPresent(Int64.self,forKey: .cursorClickDurationNs)
        guard screenOpacity.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              cameraBlur.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              cursorClickDurationNs.map({ $0 > 0 && $0 <= 10_000_000_000 }) ?? true else {
            throw RenderError.invalidSettings("Core returned an invalid render transition or click effect")
        }
    }
}

/// Decode only consumed cold fields. A new optional Core field must not make an
/// older or partial query payload fail through Core's full synthesized decoder.
struct ProjectRenderBaseOptions: Decodable {
    let screenShadow: CoreRenderOptions.ScreenShadow?
    let cursorSetId: String?
    let cursorShape: String?
    let cursorVariants: [String: VectorCursorVariant]?
    let cursorPressed: Bool?
    let cursorUseDefaultIfAppHasLowResolution: Bool?
    let cursorAlwaysUseDefault: Bool?
    let cursorLogicalSize: CoreRenderOptions.CursorLogicalSize?
    let cameraStyle: CameraStyle?
    let cameraLayout: CoreCameraLayout?
    let zoomLens: CoreZoomLens?
}

private struct ProjectScreenQuality: Decodable {
    let improveQuality: Double
    let upscaling: ScreenQualitySettings.Upscaling
    private enum CodingKeys: String, CodingKey { case improveQuality, upscaling }
    init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy: CodingKeys.self)
        improveQuality=try c.decodeIfPresent(Double.self,forKey: .improveQuality) ?? 0.5
        upscaling=try c.decodeIfPresent(ScreenQualitySettings.Upscaling.self,forKey: .upscaling) ?? .quality
    }
}
struct CameraColorQuery: Decodable {
    let presetId: String?
    let lutPath: String?
    let intensity: Float?
    let warmth: Float?
    let contrast: Float?
    let colorIntensity: Float?
    let sharpen: Float?
    let grain: Float?
    func value(package: URL) throws -> CameraColorSettings {
        let url = try lutPath.map { try packageMediaURL($0,root: package) }
        let result = CameraColorSettings(presetID: presetId,lutURL: url,intensity: intensity ?? 1,warmth: warmth ?? 0,contrast: contrast ?? 0,colorIntensity: colorIntensity ?? 0,sharpen: sharpen ?? 0,grain: grain ?? 0)
        try result.validate(); return result
    }
}
