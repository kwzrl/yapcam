import Foundation

public struct CameraColorPreset: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let warmth: Float
    public let contrast: Float
    public let colorIntensity: Float
    public let lift: Float
    public let gamma: Float
}

/// Authored here from simple color transforms. No imported LUT packs or reference assets.
public enum CameraColorLibrary {
    private static func preset(_ id: String, _ name: String, _ w: Float, _ c: Float, _ s: Float, _ l: Float = 0, _ g: Float = 1) -> CameraColorPreset {
        CameraColorPreset(id: id,name: name,warmth: w,contrast: c,colorIntensity: s,lift: l,gamma: g)
    }
    public static let presets: [CameraColorPreset] = [
        preset("balanced","Balanced",0,0.08,0.04),
        preset("honey","Honey",0.28,0.05,0.06,0.01),
        preset("winter","Winter",-0.22,0.08,-0.04),
        preset("porcelain","Porcelain",0.08,-0.14,-0.08,0.035,1.02),
        preset("dusk","Dusk",-0.10,0.18,-0.12,-0.02,0.95),
        preset("meadow","Meadow",-0.05,0.05,0.22),
        preset("cobalt","Cobalt",-0.30,0.16,0.10,-0.01,1.03),
        preset("ochre","Ochre",0.38,0.20,-0.10,0,0.98),
        preset("graphite","Graphite",0,0.15,-1),
        preset("charcoal","Charcoal",0.02,0.32,-1,-0.015,1.01),
        preset("pastel","Pastel",0.10,-0.25,-0.12,0.06,1.08),
        preset("vivid","Vivid",0.02,0.24,0.36,-0.01)
    ]
    public static func preset(id: String) -> CameraColorPreset? { presets.first { $0.id == id } }
}

public struct CameraColorSettings: Sendable, Equatable, Codable {
    public var presetID: String?
    /// Use CubeLUT.importFile to make an immutable project-local copy first.
    public var lutURL: URL?
    public var intensity: Float
    public var warmth: Float
    public var contrast: Float
    public var colorIntensity: Float
    public var sharpen: Float
    public var grain: Float
    public init(presetID: String? = nil, lutURL: URL? = nil, intensity: Float = 1,
                warmth: Float = 0, contrast: Float = 0, colorIntensity: Float = 0, sharpen: Float = 0, grain: Float = 0) {
        self.presetID = presetID; self.lutURL = lutURL; self.intensity = intensity
        self.warmth = warmth; self.contrast = contrast; self.colorIntensity = colorIntensity
        self.sharpen = sharpen; self.grain = grain
    }
    public var isEnabled: Bool { presetID != nil || lutURL != nil || warmth != 0 || contrast != 0 || colorIntensity != 0 || sharpen != 0 || grain != 0 }
    public func validate() throws {
        guard [warmth,contrast,colorIntensity].allSatisfy({ (-1...1).contains($0) }),
              [intensity,sharpen,grain].allSatisfy({ (0...1).contains($0) }), lutURL?.isFileURL != false,
              presetID == nil || CameraColorLibrary.preset(id: presetID!) != nil,
              presetID == nil || lutURL == nil else { throw RenderError.invalidSettings("Camera color settings or preset are invalid") }
    }
    func uniforms() throws -> (SIMD4<Float>,SIMD4<Float>) {
        try validate()
        let p = presetID.flatMap { CameraColorLibrary.preset(id: $0) }
        return (SIMD4(min(1,max(-1,warmth+(p?.warmth ?? 0))),min(1,max(-1,contrast+(p?.contrast ?? 0))),min(1,max(-1,colorIntensity+(p?.colorIntensity ?? 0))),p?.lift ?? 0),
                SIMD4(p?.gamma ?? 1,intensity,sharpen,grain))
    }
    /// CPU oracle for authored tone transforms, in encoded sRGB (before optional LUT).
    public func transform(_ rgb: SIMD3<Float>) throws -> SIMD3<Float> {
        guard (0..<3).allSatisfy({ rgb[$0].isFinite }) else { throw RenderError.invalidSettings("Invalid camera color sample") }
        let (a,b) = try uniforms()
        var c = rgb+SIMD3(a.x*0.09,a.x*0.01,-a.x*0.09)
        c = (c-SIMD3(repeating: 0.5))*(1+a.y)+SIMD3(repeating: 0.5+a.w)
        let luma = c.x*0.2126+c.y*0.7152+c.z*0.0722
        c = SIMD3(repeating: luma)+(c-SIMD3(repeating: luma))*(1+a.z)
        for i in 0..<3 { c[i] = min(1,max(0,pow(max(0,c[i]),1/b.x))) }
        return rgb+(c-rgb)*intensity
    }
}
