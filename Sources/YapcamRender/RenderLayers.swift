import Foundation
import CoreGraphics
import CoreText
import MetalKit
import YapcamCore

/// Additional drawing instructions evaluated by the project, in the same canvas pixels as YcFrame.
public struct RenderLayer: Sendable, Equatable {
    /// Explicit evaluator metadata, never inferred from an id, color or a
    /// neighboring text layer. Old/custom sources retain conservative checks.
    public enum Purpose: String, Sendable, Codable {
        case unspecified
        case privacyMask = "privacy_mask"
        case textBackground = "text_background"
    }
    public enum Content: Sendable, Equatable {
        case text(String, fontSize: Double, color: SIMD4<Float>)
        case image(relativePath: String)
        case highlight(dimOpacity: Float, fill: SIMD4<Float>, stroke: SIMD4<Float>, strokeWidth: Float)
        /// Gaussian standard deviation in canonical canvas pixels (0...128).
        /// Replaces the underlying composition inside rect; no fill/stroke/dim.
        case blur(radius: Float)
    }
    public var content: Content
    public var rect: CGRect
    public var cornerRadius: Float
    public var opacity: Float
    public var purpose: Purpose
    /// Applies to text only. Sans preserves the original Helvetica rendering.
    public var textFontFamily: RenderTextFontFamily
    /// Evaluated Core caption instructions. Line opacity/slide already reside in
    /// opacity/rect; only glyph growth and per-word animation are applied here.
    public var caption: CoreCaptionEvaluation?
    public init(content: Content, rect: CGRect, cornerRadius: Float = 0, opacity: Float = 1,
                textFontFamily: RenderTextFontFamily = .sans, caption: CoreCaptionEvaluation? = nil,
                purpose: Purpose = .unspecified) {
        self.content = content; self.rect = rect; self.cornerRadius = cornerRadius; self.opacity = opacity
        self.textFontFamily = textFontFamily
        self.caption = caption
        self.purpose = purpose
    }
    func validatePurpose() throws {
        switch purpose {
        case .unspecified: break
        case .textBackground:
            guard case .highlight(let dim,_,_,_) = content,dim == 0 else {
                throw RenderError.invalidSettings("Text background purpose requires an undimmed background layer")
            }
        case .privacyMask:
            switch content {
            case .highlight, .blur: break
            default: throw RenderError.invalidSettings("Privacy mask purpose requires a cover, highlight or blur mask")
            }
        }
    }
}

/// Supplemental render features supplied through Core extras/motion or custom source hooks.
/// Defaults preserve the frame description exactly; the project supplies explicit selections.
public struct RenderConfiguration: Sendable, Equatable {
    public enum CursorStyle: Sendable {
        case recorded, arrow, pointer, touch, text
        case resizeHorizontal, resizeVertical, resizeDiagonalNWSE, resizeDiagonalNESW
        case openHand, closedHand
        case crosshair, notAllowed
    }
    public var cursorStyle: CursorStyle = .recorded
    /// Selecting an original set replaces recorded PNG artwork; nil keeps recorded/default behavior.
    public var cursorSetID: String? = nil
    public var cursorSize: VectorCursorSize = .regular
    /// Per Core shape id; absent entries select the standard authored geometry.
    public var cursorVariants: [String: VectorCursorVariant] = [:]
    /// Evaluated button/pulse state independent of the optional click-ring effect.
    /// nil preserves older Core's click_progress feedback when available.
    public var cursorPressed: Bool? = nil
    /// Replace only positively identified, enlarged low-resolution standard art.
    /// Unknown/custom recorded cursors remain untouched.
    public var cursorUseDefaultIfAppHasLowResolution = true
    /// Explicit evaluated override; separate from legacy style for Original art.
    public var cursorAlwaysUseDefault = false
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
    private var maskBlur: MaskBlur?
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
    func intermediateIfNeeded(_ layers: [RenderLayer],target: MTLTexture) throws -> MTLTexture? {
        guard layers.contains(where: { if case .blur(let radius) = $0.content { return radius>0 && $0.opacity>0 }; return false }) else { return nil }
        if maskBlur == nil { maskBlur=try MaskBlur(device: device) }
        return try maskBlur!.compositionTexture(width: target.width,height: target.height)
    }
    func resolve(_ source: MTLTexture,to target: MTLTexture,in cb: MTLCommandBuffer) throws {
        guard let maskBlur else { throw RenderError.metal("Missing blur-mask resolver") }
        try maskBlur.copy(source,to: target,in: cb)
    }
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
        var activeEncoder: MTLRenderCommandEncoder?
        var blurWorkspace: MaskBlur.Workspace?
        defer { activeEncoder?.endEncoding() }
        func overlayEncoder() throws -> MTLRenderCommandEncoder {
            if let activeEncoder { return activeEncoder }
            let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store
            guard let encoder = cb.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.metal("Cannot create overlay encoder") }
            encoder.setRenderPipelineState(pipeline); activeEncoder=encoder
            return encoder
        }
        for layer in layers {
            var r = layer.rect
            guard [r.minX,r.minY,r.width,r.height].allSatisfy({ $0.isFinite }), r.width > 0, r.height > 0, layer.opacity.isFinite, (0...1).contains(layer.opacity), layer.cornerRadius.isFinite, layer.cornerRadius>=0 else { throw RenderError.invalidSettings("Invalid overlay rectangle") }
            if case .blur(let radius) = layer.content {
                let sigma=try MaskBlur.scaledSigma(radius: radius,canvas: canvas,width: target.width,height: target.height)
                guard sigma > 0,layer.opacity > 0 else { continue }
                activeEncoder?.endEncoding(); activeEncoder=nil
                if maskBlur == nil { maskBlur=try MaskBlur(device: device) }
                if blurWorkspace == nil {
                    let workspace=try maskBlur!.workspace(width: target.width,height: target.height)
                    blurWorkspace=workspace
                    cb.addCompletedHandler { _ in _ = workspace }
                }
                try maskBlur!.encode(layer,canvas: canvas,sigma: sigma,target: target,workspace: blurWorkspace!,in: cb)
                continue
            }
            var captionLayout: CaptionTextLayout?
            if let caption = layer.caption, case .text(_,let size,_) = layer.content {
                try validateCaption(caption)
                captionLayout = try CaptionLayoutCache.shared.layout(caption,fontSize: size,family: layer.textFontFamily,size: r.size)
                r = captionLayout!.fittedRect(r,growth: caption.growth)
            }
            var texture = solid
            var uniforms: [SIMD4<Float>] = [SIMD4(canvas.x,canvas.y,0,0), SIMD4(Float(r.minX),Float(r.minY),Float(r.width),Float(r.height)), SIMD4(layer.cornerRadius,layer.opacity,0,0), .zero, .zero]
            switch layer.content {
            case .text(let value, let size, let color):
                let scale=max(1,max(Double(target.width)/Double(canvas.x),Double(target.height)/Double(canvas.y)))
                if let layout = captionLayout, let caption = layer.caption {
                    texture = try generatedSRGBTexture(layout.image(caption: caption,color: color,scale: scale),device: device)
                } else {
                    texture = try text(value,fontSize: size*scale,family: layer.textFontFamily,color: color,size: CGSize(width: r.width*scale,height: r.height*scale))
                }
                uniforms[2].z = 1
            case .image(let path):
                if images[path] == nil {
                    if images.count >= 8 { images.removeAll() }
                    images[path] = try loader.newTexture(URL: packageMediaURL(path,root: project.packageURL),options: [.SRGB: true])
                }
                texture=images[path]!; uniforms[2].z = 1
            case .highlight(let dim, let fill, let stroke, let width):
                guard [dim,fill.x,fill.y,fill.z,fill.w,stroke.x,stroke.y,stroke.z,stroke.w].allSatisfy({ $0.isFinite && (0...1).contains($0) }), width.isFinite, width>=0 else { throw RenderError.invalidSettings("Invalid highlight styling") }
                uniforms[0].z = dim; uniforms[2].w = width; uniforms[3] = fill; uniforms[4] = stroke
            case .blur: continue
            }
            let encoder=try overlayEncoder()
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
