import Foundation
import CoreGraphics
import CoreText
import MetalKit

/// Additional drawing instructions evaluated by the project, in the same canvas pixels as YcFrame.
public struct RenderLayer: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case text(String, fontSize: Double, color: SIMD4<Float>)
        case image(relativePath: String)
        case highlight(dimOpacity: Float, fill: SIMD4<Float>, stroke: SIMD4<Float>, strokeWidth: Float)
    }
    public var content: Content
    public var rect: CGRect
    public var cornerRadius: Float
    public var opacity: Float
    /// Applies to text only. Sans preserves the original Helvetica rendering.
    public var textFontFamily: RenderTextFontFamily
    public init(content: Content, rect: CGRect, cornerRadius: Float = 0, opacity: Float = 1,
                textFontFamily: RenderTextFontFamily = .sans) {
        self.content = content; self.rect = rect; self.cornerRadius = cornerRadius; self.opacity = opacity
        self.textFontFamily = textFontFamily
    }
}

/// Supplemental render features supplied through Core extras/motion or custom source hooks.
/// Defaults preserve the frame description exactly; the project supplies explicit selections.
public struct RenderConfiguration: Sendable, Equatable {
    public enum CursorStyle: Sendable {
        case recorded, arrow, pointer, touch, text
        case resizeHorizontal, resizeVertical, resizeDiagonalNWSE, resizeDiagonalNESW
        case openHand, closedHand
    }
    public var cursorStyle: CursorStyle = .recorded
    /// Selecting an original set replaces recorded PNG artwork; nil keeps recorded/default behavior.
    public var cursorSetID: String? = nil
    public var cursorSize: VectorCursorSize = .regular
    public var cursorRotationRadians: Float = 0
    /// nil preserves custom-source legacy frame.motion_blur; Core supplies evaluated values.
    public var zoomMotionBlur: Float? = nil
    public var panMotionBlur: Float? = nil
    public var cursorMotionBlur: Float = 0
    public var cursorSpotlightRadius: Float = 0
    public var backgroundNoise: Float = 0
    public var windowChrome = false
    /// Core evaluates shadow radius/opacity/y in YcFrame; cold options supply x.
    public var screenShadowOffsetX: Float = 0
    /// -1...1: positive x/y weights the inset toward the right/bottom edge.
    public var screenInsetOrigin: SIMD2<Float> = .zero
    public var screenQuality: ScreenQualitySettings? = nil
    public var glassLoupe: GlassLoupeSettings? = nil
    public var cameraColor = CameraColorSettings()
    public var cameraCrop = SIMD4<Float>(0,0,1,1)
    public var cameraBackgroundPop: Float = 0
    public var cameraBackgroundBlur: Float = 0
    public var cameraMatte: CameraMatteSettings? = nil
    public var cameraBackgroundRemoval = false
    public var cameraFaceFraming = false
    public var cameraShadowRadius: Float = 0
    public init() {}
}

/// Supplemental drawing instructions evaluated at the primary frame's timestamp.
public struct RenderFrameEffects: Sendable, Equatable {
    public var configuration: RenderConfiguration
    public var layers: [RenderLayer]
    public init(configuration: RenderConfiguration = .init(), layers: [RenderLayer] = []) {
        self.configuration=configuration; self.layers=layers
    }
}

final class LayerRenderer {
    private let device: MTLDevice
    private let loader: MTKTextureLoader
    private let pipeline: MTLRenderPipelineState
    private let solid: MTLTexture
    private var texts: [String: MTLTexture] = [:]
    private var images: [String: MTLTexture] = [:]
    init(device: MTLDevice) throws {
        self.device = device; loader = MTKTextureLoader(device: device)
        let lib = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = lib.makeFunction(name: "layerVertex")
        descriptor.fragmentFunction = lib.makeFunction(name: "layerFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm_srgb; attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha; attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one; attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let solid = device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 1, height: 1, mipmapped: false)) else { throw RenderError.metal("Cannot create overlay texture") }
        var pixel: UInt32 = .max; solid.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4); self.solid = solid
    }
    func invalidate() { texts.removeAll(); images.removeAll() }
    private func text(_ value: String, fontSize: Double, family: RenderTextFontFamily, color: SIMD4<Float>, size: CGSize) throws -> MTLTexture {
        guard [color.x,color.y,color.z,color.w].allSatisfy({ $0.isFinite && (0...1).contains($0) }), size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0, size.width <= 8192, size.height <= 8192, fontSize.isFinite, fontSize > 0 else { throw RenderError.invalidSettings("Invalid text overlay size") }
        let key = "\(value)|\(fontSize)|\(family.rawValue)|\(color)|\(size)"
        if let texture = texts[key] { return texture }
        let width = Int(ceil(size.width)), height = Int(ceil(size.height))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { throw RenderError.write("Cannot rasterize text overlay") }
        let font = family.font(size: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(colorSpace: space, components: [CGFloat(color.x),CGFloat(color.y),CGFloat(color.z),CGFloat(color.w)])!]
        let text = NSAttributedString(string: value, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(x: 0,y: 0,width: width,height: height), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter,CFRange(location: 0,length: 0),path,nil),context)
        guard let image = context.makeImage() else { throw RenderError.write("Cannot create text image") }
        let texture = try generatedSRGBTexture(image,device: device)
        if texts.count >= 32 { texts.removeAll() }; texts[key] = texture
        return texture
    }
    func encode(_ layers: [RenderLayer], canvas: SIMD2<Float>, project: any RenderProjectSource, target: MTLTexture, cb: MTLCommandBuffer) throws {
        guard !layers.isEmpty else { return }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store
        guard let encoder = cb.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.metal("Cannot create overlay encoder") }
        defer { encoder.endEncoding() }
        encoder.setRenderPipelineState(pipeline)
        for layer in layers {
            let r = layer.rect
            guard [r.minX,r.minY,r.width,r.height].allSatisfy({ $0.isFinite }), r.width > 0, r.height > 0, layer.opacity.isFinite, (0...1).contains(layer.opacity), layer.cornerRadius.isFinite, layer.cornerRadius>=0 else { throw RenderError.invalidSettings("Invalid overlay rectangle") }
            var texture = solid
            var uniforms: [SIMD4<Float>] = [SIMD4(canvas.x,canvas.y,0,0), SIMD4(Float(r.minX),Float(r.minY),Float(r.width),Float(r.height)), SIMD4(layer.cornerRadius,layer.opacity,0,0), .zero, .zero]
            switch layer.content {
            case .text(let value, let size, let color):
                let scale=max(1,max(Double(target.width)/Double(canvas.x),Double(target.height)/Double(canvas.y)))
                texture = try text(value,fontSize: size*scale,family: layer.textFontFamily,color: color,size: CGSize(width: r.width*scale,height: r.height*scale)); uniforms[2].z = 1
            case .image(let path):
                if images[path] == nil {
                    if images.count >= 8 { images.removeAll() }
                    images[path] = try loader.newTexture(URL: packageMediaURL(path,root: project.packageURL),options: [.SRGB: true])
                }
                texture=images[path]!; uniforms[2].z = 1
            case .highlight(let dim, let fill, let stroke, let width):
                guard [dim,fill.x,fill.y,fill.z,fill.w,stroke.x,stroke.y,stroke.z,stroke.w].allSatisfy({ $0.isFinite && (0...1).contains($0) }), width.isFinite, width>=0 else { throw RenderError.invalidSettings("Invalid highlight styling") }
                uniforms[0].z = dim; uniforms[2].w = width; uniforms[3] = fill; uniforms[4] = stroke
            }
            encoder.setFragmentBytes(&uniforms,length: uniforms.count*MemoryLayout<SIMD4<Float>>.stride,index: 0)
            encoder.setFragmentTexture(texture,index: 0)
            encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
        }
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 p [[position]]; float2 uv; };
    vertex V layerVertex(uint id [[vertex_id]]) { float2 uv=float2((id<<1)&2,id&2); V v; v.p=float4(uv.x*2-1,1-uv.y*2,0,1); v.uv=uv; return v; }
    float sd(float2 p,float4 r,float radius) { float2 q=abs(p-r.xy-r.zw*.5)-r.zw*.5+radius; return length(max(q,0.0))+min(max(q.x,q.y),0.0)-radius; }
    float3 linearRGB(float3 c) { return select(c/12.92,pow((c+.055)/1.055,float3(2.4)),c>.04045); }
    float4 overPremultiplied(float4 base,float4 top) { return top+base*(1-top.a); }
    fragment float4 layerFragment(V v [[stage_in]],constant float4 *u [[buffer(0)]],texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
        float2 p=v.uv*u[0].xy; float2 uv=(p-u[1].xy)/u[1].zw;
        float d=sd(p,u[1],clamp(u[2].x,0.0,min(u[1].z,u[1].w)*.5)); float mask=1-smoothstep(-.5,.5,d);
        if(u[2].z>0) { if(any(uv<0)||any(uv>1)) return 0; float4 c=tex.sample(s,uv); c.a*=mask*u[2].y; return c; }
        float halfWidth=u[2].w*.5;
        float border=u[2].w>0 ? 1-smoothstep(max(0.0,halfWidth-.5),halfWidth+.5,abs(d)) : 0;
        // Compose dim, fill and centered stroke using premultiplied linear RGB.
        // The pipeline consumes straight alpha, so unpremultiply exactly once.
        float fillAlpha=u[3].a*mask, strokeAlpha=u[4].a*border;
        // Fill and outside dim occupy complementary coverage at the antialiased edge.
        float4 c=float4(linearRGB(u[3].rgb)*fillAlpha,fillAlpha+u[0].z*(1-mask));
        c=overPremultiplied(c,float4(linearRGB(u[4].rgb)*strokeAlpha,strokeAlpha));
        if(c.a>0) c.rgb/=c.a; c.a*=u[2].y; return c;
    }
    """
}
