import Foundation
import YapcamCore

/// Optional additions on the existing evaluated query. Old projects/Core return
/// no additions and retain classic zoom and unmodified camera pixels.
struct ProjectRenderOptions: Decodable {
    let base: CoreRenderOptions
    let glassLoupe: GlassLoupeSettings?
    let cameraColor: CameraColorQuery?
    private enum CodingKeys: String, CodingKey { case glassLoupe, cameraColor }
    init(from decoder: Decoder) throws {
        base = try CoreRenderOptions(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        glassLoupe = try c.decodeIfPresent(GlassLoupeSettings.self,forKey: .glassLoupe)
        cameraColor = try c.decodeIfPresent(CameraColorQuery.self,forKey: .cameraColor)
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
