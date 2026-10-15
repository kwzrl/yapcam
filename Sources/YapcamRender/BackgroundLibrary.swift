import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import YapcamCore

public struct BackgroundPreset: Identifiable, Sendable, Equatable {
    public enum Category: String, CaseIterable, Sendable, Codable { case gradients, landscapes, geometry }
    public enum Artwork: Sendable { case gradient, aurora, strata, orbit }
    public let id: String
    public let title: String
    public let category: Category
    public let artwork: Artwork
    public let colors: [SIMD3<Float>]
    public let angleDegrees: Float
}

/// Original palettes and analytic artwork. No bundled photographs or third-party assets.
public enum BackgroundLibrary {
    /// Stable picker metadata; the same id resolves through preset(id:) and apply(_:to:).
    public struct Entry: Identifiable, Sendable, Equatable, Codable {
        public let id: String
        public let category: BackgroundPreset.Category
        public let name: String
    }
    private static let thumbnails = BackgroundThumbnailCache()
    private static func color(_ hex: UInt32) -> SIMD3<Float> { SIMD3(Float((hex>>16)&255),Float((hex>>8)&255),Float(hex&255))/255 }
    private static func preset(_ id: String,_ title: String,_ category: BackgroundPreset.Category,_ artwork: BackgroundPreset.Artwork,_ a: UInt32,_ b: UInt32,_ c: UInt32,_ angle: Float = 45) -> BackgroundPreset {
        BackgroundPreset(id: id,title: title,category: category,artwork: artwork,colors: [color(a),color(b),color(c)],angleDegrees: angle)
    }
    public static let presets: [BackgroundPreset] = [
        preset("quiet-dawn","Quiet Dawn",.gradients,.gradient,0xF2D6BC,0x7599BD,0xFFFFFF,-20),
        preset("deep-slate","Deep Slate",.gradients,.gradient,0x182B42,0x706988,0xFFFFFF,115),
        preset("soft-sage","Soft Sage",.gradients,.gradient,0xC4D5BE,0x466D63,0xFFFFFF,35),
        preset("clear-lagoon","Clear Lagoon",.gradients,.gradient,0x0B5967,0x79C8BD,0xFFFFFF,80),
        preset("warm-ember","Warm Ember",.gradients,.gradient,0x3D253E,0xD99569,0xFFFFFF,20),
        preset("evening-violet","Evening Violet",.gradients,.gradient,0x3A376A,0xC4ACC9,0xFFFFFF,135),
        preset("boreal-glow","Boreal Glow",.landscapes,.aurora,0x163544,0x237E79,0xA0B894),
        preset("rose-light","Rose Light",.landscapes,.aurora,0x463455,0x996C8C,0xE1B58D),
        preset("sediment","Sediment",.landscapes,.strata,0x443B39,0xB8A38B,0xD5C5A4),
        preset("blue-hills","Blue Hills",.landscapes,.strata,0x273E59,0x8AA5BD,0xD0DEDE),
        preset("golden-rings","Golden Rings",.geometry,.orbit,0x2D363F,0xAA8758,0xD9C7A3),
        preset("cool-rings","Cool Rings",.geometry,.orbit,0x233544,0x527F91,0xAEC7C6)
    ]
    /// Original library in display order. nil includes all categories; no media I/O.
    public static func catalog(category: BackgroundPreset.Category? = nil) -> [Entry] {
        presets.filter { category == nil || $0.category == category }.map {
            Entry(id: $0.id, category: $0.category, name: $0.title)
        }
    }
    public static func preset(id: String) -> BackgroundPreset? { presets.first { $0.id==id } }
    /// Our authored calm dark starting point; never a system/vendor wallpaper.
    public static var defaultPreset: BackgroundPreset { preset(id: "deep-slate")! }
    /// CPU-only, sRGB thumbnails generated away from MainActor. Safe to await in a
    /// SwiftUI .task; concurrent requests reuse the same image. Sizes are pixels,
    /// 16...512 per edge (e.g. 320x200 for a 160x100 point cell at 2x).
    /// The shared LRU holds at most 48 images and 8MiB of pixel data, with no disk I/O.
    public static func thumbnail(id: String, width: Int = 160, height: Int = 100) async throws -> CGImage {
        try Task.checkCancellation()
        guard let preset = preset(id: id) else { throw RenderError.invalidSettings("Unknown wallpaper: \(id)") }
        guard (16...512).contains(width), (16...512).contains(height) else { throw RenderError.invalidSettings("Wallpaper thumbnail dimensions must be 16…512 pixels") }
        let result = try await thumbnails.image(for: preset, width: width, height: height)
        try Task.checkCancellation()
        return result
    }
    /// Same analytic artwork for small picker thumbnails and full-resolution imports.
    public static func image(for preset: BackgroundPreset,width: Int = 3840,height: Int = 2160) throws -> CGImage {
        guard width>=16, height>=16, width<=8192, height<=8192, width*height<=33_554_432 else { throw RenderError.invalidSettings("Wallpaper dimensions must be 16…8192 with at most 32 megapixels") }
        func linear(_ x: Float) -> Float { x<=0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4) }
        func encoded(_ x: Float) -> Float { x<=0.0031308 ? x*12.92 : 1.055*pow(max(0,x),1/2.4)-0.055 }
        let colors=preset.colors.map { SIMD3(linear($0.x),linear($0.y),linear($0.z)) }
        let angle=preset.angleDegrees*Float.pi/180, dx=cos(angle), dy=sin(angle)
        let denominator=abs(dx)*Float(width)+abs(dy)*Float(height)
        var pixels=[UInt8](repeating: 255,count: width*height*4)
        for y in 0..<height {
            if y%32==0 { try Task.checkCancellation() }
            let v=(Float(y)+0.5)/Float(height)
            for x in 0..<width {
                let u=(Float(x)+0.5)/Float(width)
                var t: Float, accent: Float=0
                switch preset.artwork {
                case .gradient: t=((u-0.5)*Float(width)*dx+(v-0.5)*Float(height)*dy)/denominator+0.5
                case .aurora:
                    t=0.5+0.22*sin(5*u+3*v)+0.18*cos(9*u-4*v)
                    accent=0.45*exp(-((u-0.68)*(u-0.68)+(v-0.27)*(v-0.27))/0.06)
                case .strata:
                    let terrain=v+0.12*sin(5*u)+0.04*cos(11*u)
                    t=min(1,max(0,floor(terrain*8)/8)); accent=max(0,terrain-0.65)*0.35
                case .orbit:
                    let px=(u-0.55)*Float(width)/Float(height), py=v-0.55
                    let radius=sqrt(px*px+py*py)
                    t=0.5+0.3*cos(radius*24); accent=max(0,1-radius)*0.15
                }
                t=min(1,max(0,t))
                let rgb=(colors[0]*(1-t)+colors[1]*t)*(1-accent)+colors[2]*accent
                var hash=UInt32(truncatingIfNeeded: x+y*width)&*747_796_405&+2_891_336_453
                hash=(hash^(hash>>16))&*2_246_822_519
                let dither=(Float(hash&255)/255-0.5)/255
                let offset=(y*width+x)*4
                for channel in 0..<3 { pixels[offset+channel]=UInt8((min(1,max(0,encoded(rgb[channel])+dither))*255).rounded()) }
            }
        }
        guard let provider=CGDataProvider(data: Data(pixels) as CFData),let space=CGColorSpace(name: CGColorSpace.sRGB),
              let image=CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,space: space,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),provider: provider,decode: nil,shouldInterpolate: true,intent: .defaultIntent) else { throw RenderError.write("Cannot create original wallpaper") }
        return image
    }
    /// Gradient settings use one undo step; artwork is generated off-main and imported atomically.
    @discardableResult public static func apply(_ preset: BackgroundPreset,to project: Project,width: Int = 3840,height: Int = 2160) async throws -> ChangeSet {
        try Task.checkCancellation()
        if preset.artwork == .gradient {
            func rgba(_ c: SIMD3<Float>) -> JSONValue { .array([Double(c.x),Double(c.y),Double(c.z),1].map(JSONValue.number)) }
            return try project.apply(.batch([
                .set(path: "canvas.background.kind",value: .string("gradient")),
                .set(path: "canvas.background.color",value: rgba(preset.colors[0])),
                .set(path: "canvas.background.color2",value: rgba(preset.colors[1])),
                .set(path: "canvas.background.angle_deg",value: .number(Double(preset.angleDegrees)))
            ]))
        }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-wallpaper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url=directory.appendingPathComponent("background.png")
        let generation=Task.detached(priority: .userInitiated) {
            let image=try image(for: preset,width: width,height: height)
            guard let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { throw RenderError.write("Cannot encode original wallpaper") }
            CGImageDestinationAddImage(destination,image,nil)
            guard CGImageDestinationFinalize(destination) else { throw RenderError.write("Wallpaper encoding failed") }
        }
        try await withTaskCancellationHandler { try await generation.value } onCancel: { generation.cancel() }
        try Task.checkCancellation()
        return try project.importBackgroundImage(url)
    }
}
