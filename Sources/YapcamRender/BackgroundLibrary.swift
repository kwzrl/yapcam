import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import YapcamCore

public struct BackgroundPreset: Identifiable, Sendable, Equatable {
    public enum Category: String, CaseIterable, Sendable, Codable {
        case gradients, landscapes, dusk, geometry, currents, pearlescent, midnight, glass, rays
    }
    public enum Artwork: Sendable { case gradient, aurora, strata, orbit, dunes, ribbons, prism, stars, panes, rays }
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
    private static let originalPresets: [BackgroundPreset] = [
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
    /// Nine authored collections, 182 choices. Existing IDs and their pixels are
    /// stable. Each collection has its own analytic composition and palette range;
    /// there are no system wallpapers, photographs, downloads or vendor assets.
    public static let presets: [BackgroundPreset] = {
        let collections: [(BackgroundPreset.Category,Int,String,BackgroundPreset.Artwork,Float)] = [
            (.gradients,18,"Quiet",.gradient,0.59),(.landscapes,24,"Horizon",.strata,0.36),
            (.dusk,21,"Afterglow",.dunes,0.96),(.geometry,20,"Contour",.orbit,0.11),
            (.currents,23,"Current",.ribbons,0.53),(.pearlescent,17,"Luster",.prism,0.75),
            (.midnight,18,"Nightfall",.stars,0.65),(.glass,10,"Pane",.panes,0.48),
            (.rays,31,"Radiance",.rays,0.08)
        ]
        func hsv(_ h: Float,_ s: Float,_ v: Float) -> SIMD3<Float> {
            let hue=(h-floor(h))*6, sector=Int(hue), f=hue-Float(sector)
            let p=v*(1-s),q=v*(1-s*f),t=v*(1-s*(1-f))
            switch sector { case 0: return SIMD3(v,t,p); case 1: return SIMD3(q,v,p)
            case 2: return SIMD3(p,v,t); case 3: return SIMD3(p,q,v)
            case 4: return SIMD3(t,p,v); default: return SIMD3(v,p,q) }
        }
        return collections.flatMap { category,count,name,artwork,hue -> [BackgroundPreset] in
            let legacy=originalPresets.filter { $0.category == category }
            return legacy+(legacy.count..<count).map { index in
                let phase=Float(index)/Float(count), dark=category == .midnight
                let saturation: Float=category == .pearlescent || category == .glass ? 0.28 : 0.58
                return BackgroundPreset(id: "\(category.rawValue)-\(index+1)",title: "\(name) \(index+1)",category: category,artwork: artwork,
                    colors: [hsv(hue+phase*0.35,saturation,dark ? 0.07+phase*0.1 : 0.25+phase*0.16),
                             hsv(hue+phase*0.35+0.16,saturation*0.68,dark ? 0.22+phase*0.16 : 0.72+phase*0.22),
                             hsv(hue+phase*0.35+0.32,saturation*0.3,dark ? 0.65 : 0.98)],
                    angleDegrees: phase*170-70)
            }
        }
    }()
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
                case .dunes:
                    let ridge=v+0.16*sin(4*u+angle)+0.05*sin(9*u-angle)
                    t=min(1,max(0,ridge)); accent=0.35*exp(-pow(ridge-0.55,2)/0.012)
                case .ribbons:
                    let wave=sin(7*u+4*v+angle)+0.35*sin(13*v-3*u)
                    t=0.5+0.32*wave; accent=0.3*exp(-pow(wave-0.6,2)/0.08)
                case .prism:
                    t=0.5+0.25*sin(4*u+angle)+0.2*cos(5*v-angle)
                    accent=0.45*pow(max(0,sin(8*(u+v)+angle)),3)
                case .stars:
                    t=0.25+0.45*exp(-pow(v-0.6-0.15*sin(u*4+angle),2)/0.035)
                    let cellX=floor(u*29),cellY=floor(v*19)
                    let seed=sin(cellX*127.1+cellY*311.7+angle*3)*43758.55
                    if seed-floor(seed)>0.94 {
                        let x=u*29-cellX-0.5,y=v*19-cellY-0.5
                        accent=0.7*exp(-(x*x+y*y)/0.003)
                    }
                case .panes:
                    let diagonal=u*1.2+v*0.7+angle*0.2
                    t=0.3+0.5*v
                    let stripe=diagonal-floor(diagonal*3)/3
                    accent=0.28*exp(-pow(stripe-0.025,2)/0.0009)+0.15*max(0,1-stripe*3)
                case .rays:
                    let x=u-0.22,y=v-0.15
                    let direction=atan2(y,x),distance=sqrt(x*x+y*y)
                    t=min(1,distance*0.9)
                    accent=0.4*pow(max(0,cos(direction*7+angle)),8)*exp(-distance*1.5)
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
        return try await applyWallpaper(preset,to: project,width: width,height: height)
    }
    /// A wallpaper choice always becomes an imported image, including analytic
    /// gradients. This keeps Wallpaper selected and enables its blur control.
    /// The original apply API retains its gradient-settings behavior for callers.
    @discardableResult public static func applyWallpaper(_ preset: BackgroundPreset,to project: Project,
                                                        width: Int = 3840,height: Int = 2160) async throws -> ChangeSet {
        try Task.checkCancellation()
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-wallpaper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        defer { print("Cleanup render wallpaper import: \(directory.path)"); try? FileManager.default.removeItem(at: directory) }
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
