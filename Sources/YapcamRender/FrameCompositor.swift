import Foundation
import Metal
import MetalKit
import CYapcamCore

public final class FrameCompositor: @unchecked Sendable {
    public let device: MTLDevice
    private let project: any RenderProjectSource
    private let manifest: RecordingManifest
    private let cache: CVMetalTextureCache
    private let pipeline: MTLRenderPipelineState
    private let loader: MTKTextureLoader
    private let layerRenderer: LayerRenderer
    private let backgroundBlur: BackgroundBlur
    private let cameraEffects: CameraEffects
    private var cameraMatteProcessor: CameraMatteProcessor?
    private let lock = NSLock()
    private let invalidationLock = NSLock()
    private var needsInvalidation = false
    private var needsVisualInvalidation = false
    private var totalSourceOpens = 0
    private var motionBlurEnabled = true
    private let framesPerSecond: Int
    private var sources: [String: FrameSource] = [:]
    private var images: [String: MTLTexture] = [:]
    private var cursorMetadata: [UInt32: [String: Cursor]] = [:]
    private struct CursorTextureKey: Hashable { let style: VectorCursorStyle; let set: String; let size: VectorCursorSize; let scale: Int }
    private var vectorCursors: [CursorTextureKey: VectorCursorTexture] = [:]
    private let identityLUT: CameraLUTTexture
    private var cameraLUTs: [URL: CameraLUTTexture] = [:]
    private let empty: MTLTexture

    public init(device: MTLDevice, project: any RenderProjectSource, framesPerSecond: Int = 60) throws {
        guard (1...60).contains(framesPerSecond) else { throw RenderError.invalidSettings("Compositor frame rate must be 1...60") }
        self.framesPerSecond=framesPerSecond
        self.device = device; self.project = project
        identityLUT = try CameraLUTTexture(CubeLUT.identity(), device: device)
        manifest = try RecordingManifest.load(package: project.packageURL)
        loader = MTKTextureLoader(device: device)
        layerRenderer = try LayerRenderer(device: device)
        backgroundBlur = try BackgroundBlur(device: device)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, [kCVMetalTextureUsage as String: MTLTextureUsage.shaderRead.rawValue] as CFDictionary, &cache) == kCVReturnSuccess, let cache else { throw RenderError.metal("Metal texture cache unavailable") }
        self.cache = cache
        cameraEffects = CameraEffects(cache: cache)
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vertexMain")
        desc.fragmentFunction = library.makeFunction(name: "fragmentMain")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        pipeline = try device.makeRenderPipelineState(descriptor: desc)
        let textureDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 1, height: 1, mipmapped: false)
        guard let empty = device.makeTexture(descriptor: textureDesc) else { throw RenderError.metal("Cannot allocate fallback texture") }
        var zero: UInt32 = 0
        empty.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        self.empty = empty
    }
    /// Mark media caches stale without waiting for an in-flight decode on the UI thread.
    public func invalidateSources() { invalidationLock.withLock { needsInvalidation = true } }
    /// Refresh authored assets while retaining the unchanged recording's decoders.
    func invalidateVisualAssets() { invalidationLock.withLock { needsVisualInvalidation = true } }
    var sourceOpenCount: Int { lock.withLock { totalSourceOpens } }
    /// Cheap preview-only switch; does not rebuild audio, snapshots or decoders.
    public func setMotionBlurEnabled(_ enabled: Bool) { invalidationLock.withLock { motionBlurEnabled=enabled } }
    private func decoded(_ sample: YcSample, track: String) throws -> TextureFrame? {
        guard sample.present != 0 else { return nil }
        guard let segment = manifest.segment(at: sample.segment), let path = segment.files[track] else { throw RenderError.missingMedia("Missing \(track) in segment \(sample.segment)") }
        if sources[path] == nil {
            if sources.count >= 3 { sources.removeAll() }
            sources[path] = try FrameSource(url: packageMediaURL(path, root: project.packageURL.appendingPathComponent("recording")), cache: cache)
            totalSourceOpens += 1 }
        if track=="camera", sources[path]!.hasEnded(atNs: sample.file_ns) { return nil }
        return try sources[path]!.frame(atNs: sample.file_ns)
    }
    private func image(_ url: URL) throws -> MTLTexture {
        if let cached = images[url.path] { return cached }
        let texture = try loader.newTexture(URL: url, options: [.SRGB: true, .textureUsage: MTLTextureUsage.shaderRead.rawValue])
        if images.count >= 8 { images.removeAll() }
        images[url.path] = texture; return texture
    }
    struct Cursor: Decodable { var file: String; var hotspot: [Double]; var sizePoints: [Double]; enum CodingKeys: String, CodingKey { case file, hotspot, sizePoints = "size_points" } }
    public func encode(_ frame: YcFrame, to target: MTLTexture, in cb: MTLCommandBuffer) throws {
        try encode(frame,from: project,to: target,in: cb)
    }
    /// A preview generation supplies its frozen source so edits cannot mix frame/effects.
    func encode(_ frame: YcFrame,from project: any RenderProjectSource,to target: MTLTexture,in cb: MTLCommandBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        let (invalidate,visuals,blurEnabled) = invalidationLock.withLock {
            let value=(needsInvalidation,needsVisualInvalidation,motionBlurEnabled)
            needsInvalidation=false; needsVisualInvalidation=false; return value
        }
        if invalidate { sources.removeAll(); cameraEffects.invalidate(); CVMetalTextureCacheFlush(cache,0) }
        if invalidate || visuals { images.removeAll(); cameraLUTs.removeAll(); cursorMetadata.removeAll(); layerRenderer.invalidate() }
        guard target.pixelFormat == .bgra8Unorm_srgb, frame.canvas_w > 0, frame.canvas_h > 0 else { throw RenderError.metal("Compositor requires an sRGB BGRA target and nonzero canvas") }
        let effects = try project.renderEffects(atNs: frame.tl_ns,canvasSize: CGSize(width: Int(frame.canvas_w),height: Int(frame.canvas_h)))
        let options = effects.configuration
        try validateFrame(frame,configuration: options,layers: effects.layers)
        let screen = try decoded(frame.screen, track: "screen")
        let camera = try decoded(frame.camera, track: "camera")
        var matte: TextureFrame?
        var cameraCrop = options.cameraCrop
        let needsCameraMask=options.cameraBackgroundRemoval || options.cameraBackgroundPop>0 || options.cameraBackgroundBlur>0
        if let camera { (matte,cameraCrop) = try cameraEffects.evaluate(camera,removeBackground: needsCameraMask,faceFraming: options.cameraFaceFraming,baseCrop: cameraCrop) }
        var matteTexture=matte?.texture
        if options.cameraBackgroundRemoval, let matte, let camera, let settings=options.cameraMatte, frame.camera_dest.w>0, frame.camera_dest.h>0 {
            if cameraMatteProcessor==nil { cameraMatteProcessor=try CameraMatteProcessor(device: device) }
            let g=camera.geometry
            let steps=CameraMatteProcessor.steps(displaySize: SIMD2(Float(g.displaySize.width),Float(g.displaySize.height)),rowX: g.rowX,rowY: g.rowY,
                                                 crop: cameraCrop,destination: SIMD2(Float(frame.camera_dest.w),Float(frame.camera_dest.h)),mirrored: frame.camera_mirror != 0)
            matteTexture=try cameraMatteProcessor!.encode(matte.texture,settings: settings,steps: steps,in: cb)
        }
        var blurredCamera: MTLTexture?
        if options.cameraBackgroundBlur>0, let camera, frame.camera_dest.w>0, frame.camera_dest.h>0 {
            let size=SIMD2(Float(frame.camera_dest.w),Float(frame.camera_dest.h))
            blurredCamera=try backgroundBlur.encode(source: camera,canvas: size,radius: min(size.x,size.y)*0.04*options.cameraBackgroundBlur,crop: cameraCrop,in: cb)
        }
        let colorSettings = options.cameraColor
        var colorLUT = identityLUT
        if let url = colorSettings.lutURL, colorSettings.intensity > 0, camera != nil {
            if cameraLUTs[url] == nil {
                if cameraLUTs.count >= 4 { cameraLUTs.removeAll() }
                cameraLUTs[url] = try CameraLUTTexture(CubeLUT(contentsOf: url), device: device)
            }
            colorLUT = cameraLUTs[url]!
        }
        var cursorTexture = empty
        var cursorRect = SIMD4<Float>.zero
        if options.cursorSetID == nil, options.cursorStyle == .recorded, frame.cursor_visible != 0, frame.cursor_opacity > 0, let segment = manifest.segment(at: frame.screen.segment), let path = segment.files["cursors"] {
            let root = project.packageURL.appendingPathComponent("recording")
            let metadataURL = try packageMediaURL(path, root: root)
            if cursorMetadata[segment.index] == nil {
                if cursorMetadata.count >= 8 { cursorMetadata.removeAll() }
                cursorMetadata[segment.index] = try JSONDecoder().decode([String: Cursor].self, from: Data(contentsOf: metadataURL))
            }
            let cursors = cursorMetadata[segment.index]!
            if let cursor = cursors[String(frame.cursor_id)], cursor.hotspot.count == 2, cursor.sizePoints.count == 2 {
                cursorTexture = try image(packageMediaURL(cursor.file, root: metadataURL.deletingLastPathComponent()))
                let scale = Double(frame.cursor_scale)
                cursorRect = SIMD4(Float(frame.cursor_x - cursor.hotspot[0] * scale), Float(frame.cursor_y - cursor.hotspot[1] * scale), Float(cursor.sizePoints[0] * scale), Float(cursor.sizePoints[1] * scale))
            }
        }
        if frame.cursor_visible != 0 && (options.cursorSetID != nil || options.cursorStyle != .recorded || cursorTexture === empty) {
            let style: VectorCursorStyle
            switch options.cursorStyle {
            case .recorded,.arrow: style = .arrow
            case .pointer: style = .pointer
            case .touch: style = .touch
            case .text: style = .text
            case .resizeHorizontal: style = .resizeHorizontal
            case .resizeVertical: style = .resizeVertical
            case .resizeDiagonalNWSE: style = .resizeDiagonalNWSE
            case .resizeDiagonalNESW: style = .resizeDiagonalNESW
            case .openHand: style = .openHand
            case .closedHand: style = .closedHand
            }
            let preset=VectorCursorLibrary.preset(id: options.cursorSetID ?? "classic")!
            let pixelsPerPoint=max(Double(target.width)/Double(frame.canvas_w),Double(target.height)/Double(frame.canvas_h))*Double(frame.cursor_scale)
            let rasterScale=Int(ceil(min(8,max(2,pixelsPerPoint))))
            let key=CursorTextureKey(style: style,set: preset.id,size: options.cursorSize,scale: rasterScale)
            if vectorCursors[key]==nil {
                if vectorCursors.count>=48 { vectorCursors.removeAll() }
                vectorCursors[key]=try VectorCursorTexture(style: style,preset: preset,size: options.cursorSize,scale: CGFloat(rasterScale),device: device)
            }
            let cursor=vectorCursors[key]!, scale=Double(frame.cursor_scale)
            cursorTexture=cursor.texture
            cursorRect=SIMD4(Float(frame.cursor_x-Double(cursor.hotspot.x)*scale),Float(frame.cursor_y-Double(cursor.hotspot.y)*scale),Float(Double(cursor.size.width)*scale),Float(Double(cursor.size.height)*scale))
        }
        var background = empty
        if frame.background_kind == 2 { background = try image(project.renderBackgroundAsset(index: frame.background_asset)) }
        if frame.background_kind == 3, frame.background_blur>0, let screen { background = try backgroundBlur.encode(source: screen,canvas: SIMD2(Float(frame.canvas_w),Float(frame.canvas_h)),radius: frame.background_blur,in: cb) }
        func rect(_ r: YcRect) -> SIMD4<Float> { SIMD4(Float(r.x), Float(r.y), Float(r.w), Float(r.h)) }
        func color(_ c: (Float, Float, Float, Float)) -> SIMD4<Float> { SIMD4(c.0, c.1, c.2, c.3) }
        let crop = rect(frame.screen_crop)
        // Fixed shutter interval makes blur deterministic for seek, preview and export.
        let strengths=MotionBlurPolicy.strengths(frame: frame,configuration: options,framesPerSecond: framesPerSecond,enabled: blurEnabled)
        let zoomBlur=strengths.x, panBlur=strengths.y, cursorBlur=strengths.z
        let prior=(zoomBlur>0 || panBlur>0 || cursorBlur>0) && frame.tl_ns>0
            ? try project.frame(atNs: max(0,frame.tl_ns-16_666_667)) : frame
        let previous=rect(prior.screen_crop)
        var uniforms: [SIMD4<Float>] = [
            SIMD4(Float(frame.canvas_w), Float(frame.canvas_h), Float(frame.background_kind), frame.motion_blur),
            color(frame.background_color), color(frame.background_color2),
            SIMD4(frame.background_angle_deg * .pi / 180, frame.background_blur, screen == nil ? 0 : 1, 0),
            rect(frame.screen_dest), crop,
            SIMD4(frame.screen_corner_radius, frame.shadow_radius, frame.shadow_opacity, frame.shadow_offset_y),
            color(frame.inset_color), cursorRect,
            SIMD4(frame.cursor_visible != 0 ? frame.cursor_opacity : 0, frame.click_progress,options.cursorRotationRadians,0),
            SIMD4(Float(frame.click_x), Float(frame.click_y), 0, 0), rect(frame.camera_dest),
            SIMD4(frame.camera_corner_radius, Float(frame.camera_shape), camera == nil ? 0 : frame.camera_opacity, Float(frame.camera_mirror)),
            previous, SIMD4(frame.inset_width, options.screenShadowOffsetX, options.screenInsetOrigin.x, options.screenInsetOrigin.y),
            SIMD4(options.backgroundNoise,options.windowChrome ? 1 : 0, options.cameraShadowRadius, options.cameraBackgroundRemoval && matte != nil ? 1 : 0),
            SIMD4(zoomBlur,cursorBlur,options.cursorSpotlightRadius,panBlur),
            SIMD4(Float(frame.cursor_x),Float(frame.cursor_y),Float(frame.cursor_x),Float(frame.cursor_y)), cameraCrop,
            screen?.geometry.rowX ?? SIMD4(1,0,0,0), screen?.geometry.rowY ?? SIMD4(0,1,0,0),
            camera?.geometry.rowX ?? SIMD4(1,0,0,0), camera?.geometry.rowY ?? SIMD4(0,1,0,0),
            SIMD4(Float(screen?.geometry.displaySize.width ?? 1),Float(screen?.geometry.displaySize.height ?? 1),Float(camera?.geometry.displaySize.width ?? 1),Float(camera?.geometry.displaySize.height ?? 1)), rect(prior.screen_dest)
        ]
        if let loupe = options.glassLoupe {
            let g = loupe.geometry(frame)
            let base=loupe.samplingBase(frame)
            let span=SIMD2(base.z,base.w)/g.scale
            let lensCrop=loupe.instruction == nil ? crop : SIMD4(g.focus.x-span.x*0.5,g.focus.y-span.y*0.5,span.x,span.y)
            uniforms.append(SIMD4(loupe.instruction == nil ? 1 : 2,g.radius,loupe.bevel,loupe.chromaticAberration))
            uniforms.append(SIMD4(g.focus.x,g.focus.y,g.scale,g.opacity))
            uniforms.append(lensCrop)
            uniforms.append(base)
            uniforms[5] = base; uniforms[13] = base
            uniforms[16].x = 0 // The underlying screen stays unzoomed.
        } else {
            uniforms.append(.zero); uniforms.append(SIMD4(0.5,0.5,1,0)); uniforms.append(crop); uniforms.append(SIMD4(0,0,1,1))
        }
        let (tone, processing) = try colorSettings.uniforms()
        uniforms.append(tone) // 29: warmth, contrast, color intensity, lift
        uniforms.append(processing) // 30: gamma, grade blend, sharpness, grain
        uniforms.append(SIMD4(colorLUT.minimum, colorSettings.lutURL == nil ? 0 : 1))
        uniforms.append(SIMD4(colorLUT.maximum, colorSettings.isEnabled ? 1 : 0))
        uniforms.append(SIMD4(Float(frame.tl_ns % 1_000_000_000)/1e9,0,0,0))
        uniforms.append(options.screenQuality?.uniforms ?? .zero) // 34: improve, upscale, enabled
        uniforms.append(SIMD4(Float(target.width)/Float(frame.canvas_w),Float(target.height)/Float(frame.canvas_h),0,0))
        uniforms.append(SIMD4(options.cameraBackgroundPop,matte == nil ? 0 : 1,blurredCamera == nil ? 0 : 1,0)) // 36
        let center=options.glassLoupe?.instruction?.center ?? .zero
        uniforms.append(SIMD4(center.x,center.y,0,0)) // 37: evaluated local-lens center
        if cursorBlur > 0 && frame.tl_ns > 0 {
            uniforms[17].z = Float(prior.cursor_x); uniforms[17].w = Float(prior.cursor_y)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
        guard let encoder = cb.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.metal("Cannot create render encoder") }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: uniforms.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
        for (index, texture) in [screen?.texture ?? empty, camera?.texture ?? empty, cursorTexture, background, matteTexture ?? empty].enumerated() { encoder.setFragmentTexture(texture, index: index) }
        encoder.setFragmentTexture(colorLUT.texture, index: 5)
        encoder.setFragmentTexture(blurredCamera ?? empty,index: 6)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
        try layerRenderer.encode(effects.layers, canvas: SIMD2(Float(frame.canvas_w),Float(frame.canvas_h)), project: project, target: target, cb: cb)
        // CVMetalTexture and its IOSurface must survive until GPU completion.
        let retainedMatte = matte, retainedMatteTexture=matteTexture, retainedColorLUT = colorLUT, retainedBlurredCamera=blurredCamera
        cb.addCompletedHandler { _ in _ = screen; _ = camera; _ = retainedMatte; _ = retainedMatteTexture; _ = retainedColorLUT; _ = retainedBlurredCamera }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex vertexMain(uint id [[vertex_id]]) {
        float2 uv = float2((id << 1) & 2, id & 2);
        Vertex v; v.position = float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1); v.uv = uv; return v;
    }
    float3 linearRGB(float3 c) { return select(c / 12.92, pow((c + .055) / 1.055, float3(2.4)), c > .04045); }
    float rounded(float2 p, float4 r, float radius) {
        float2 q = abs(p - r.xy - r.zw * .5) - r.zw * .5 + radius;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    }
    float4 over(float4 base, float4 top) { float a = clamp(top.a, 0.0, 1.0); return float4(mix(base.rgb, top.rgb, a), a + base.a * (1-a)); }
    float2 coverUV(float2 uv, float2 target, float2 source) {
        float a = target.x / target.y, b = source.x / source.y;
        return (uv-.5) * (a > b ? float2(1,b/a) : float2(a/b,1)) + .5;
    }
    float2 sourceUV(float2 uv,float4 rowX,float4 rowY) { return float2(dot(uv,rowX.xy)+rowX.z,dot(uv,rowY.xy)+rowY.z); }
    float4 cameraSample(texture2d<float> tex,sampler s,float2 point,float4 crop,float2 size,float4 rowX,float4 rowY) {
        float2 inset=min(.5/size,crop.zw*.5);
        return tex.sample(s,sourceUV(clamp(point,crop.xy+inset,crop.xy+crop.zw-inset),rowX,rowY));
    }
    float cubicWeight(float value) {
        float x=abs(value);
        return x<=1 ? (1.5*x-2.5)*x*x+1 : x<2 ? ((-.5*x+2.5)*x-4)*x+2 : 0;
    }
    float4 screenSample(texture2d<float> tex,sampler s,float2 uv,float4 bounds,float2 dimensions,
                        float4 rowX,float4 rowY,float4 quality,float scale) {
        if(quality.z==0 || (quality.x==0 && (quality.y==0 || scale<=1))) return tex.sample(s,sourceUV(uv,rowX,rowY));
        float2 inset=min(.5/dimensions,bounds.zw*.5);
        float2 minimum=bounds.xy+inset, maximum=bounds.xy+bounds.zw-inset;
        float2 centerUV=clamp(uv,minimum,maximum);
        float4 center=tex.sample(s,sourceUV(centerUV,rowX,rowY)), color=center;
        if(scale>1 && quality.y>1) {
            float2 coordinate=centerUV*dimensions-.5, base=floor(coordinate), fraction=coordinate-base;
            float4 sum=0; float weights=0;
            for(int y=-1;y<=2;y++) for(int x=-1;x<=2;x++) {
                float w=cubicWeight(fraction.x-x)*cubicWeight(fraction.y-y);
                float2 point=clamp((base+float2(x,y)+.5)/dimensions,minimum,maximum);
                sum+=tex.sample(s,sourceUV(point,rowX,rowY))*w; weights+=w;
            }
            color=clamp(sum/max(weights,.000001),0.0,1.0);
        } else if(scale>1 && quality.y>0) {
            float3 cross=0;
            for(int i=0;i<4;i++) {
                float2 d=i==0 ? float2(1,0) : i==1 ? float2(-1,0) : i==2 ? float2(0,1) : float2(0,-1);
                cross+=tex.sample(s,sourceUV(clamp(centerUV+d/dimensions,minimum,maximum),rowX,rowY)).rgb*.25;
            }
            color.rgb=clamp(center.rgb+(center.rgb-cross)*.25,0.0,1.0);
        }
        if(quality.x>0) {
            float3 sum=0; float weights=0;
            for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
                float3 neighbor=tex.sample(s,sourceUV(clamp(centerUV+float2(x,y)/dimensions,minimum,maximum),rowX,rowY)).rgb;
                float3 delta=neighbor-center.rgb;
                float w=exp(-dot(delta,delta)*80)/(1+x*x+y*y);
                sum+=neighbor*w; weights+=w;
            }
            color.rgb=mix(color.rgb,sum/max(weights,.000001),quality.x*.6);
            // Stable, sub-LSB spatial noise reduces visible quantization steps;
            // it never changes source files or introduces temporal flicker.
            float dither=fract(sin(dot(floor(centerUV*dimensions),float2(37.19,71.43)))*21917.17)-.5;
            color.rgb=clamp(color.rgb+dither*quality.x/2048,0.0,1.0);
        }
        return color;
    }
    fragment float4 fragmentMain(Vertex v [[stage_in]], constant float4 *u [[buffer(0)]], texture2d<float> screen [[texture(0)]], texture2d<float> cam [[texture(1)]], texture2d<float> cursor [[texture(2)]], texture2d<float> bg [[texture(3)]], texture2d<float> matte [[texture(4)]], texture3d<float> cameraLUT [[texture(5)]], texture2d<float> cameraBlur [[texture(6)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 p = v.uv * u[0].xy;
        float4 result = float4(linearRGB(u[1].rgb),u[1].a);
        if (u[0].z == 1) {
            float2 direction = float2(cos(u[3].x), sin(u[3].x));
            float t = clamp(dot((v.uv-.5)*u[0].xy,direction) / dot(abs(direction),u[0].xy) + .5,0.0,1.0);
            result = float4(mix(linearRGB(u[1].rgb),linearRGB(u[2].rgb),t),mix(u[1].a,u[2].a,t));
        } else if (u[0].z == 2) result = bg.sample(s,coverUV(v.uv,u[0].xy,float2(bg.get_width(),bg.get_height())));
        else if (u[0].z == 3 && u[3].z > 0) {
            if(u[3].y<=0) result=screen.sample(s,sourceUV(coverUV(v.uv,u[0].xy,u[23].xy),u[19],u[20]));
            else result=bg.sample(s,coverUV(v.uv,u[0].xy,float2(bg.get_width(),bg.get_height())));
        }
        float noise=fract(sin(dot(floor(p),float2(12.9898,78.233)))*43758.5453)-.5;
        result.rgb=clamp(result.rgb+noise*u[15].x,0.0,1.0);
        float4 currentDest=u[4];
        if (u[3].z > 0 && all(currentDest.zw > 0)) {
            int taps=(u[16].x>0 || u[16].w>0) ? 8 : 1;
            float4 accumulated=0;
            for(int sample=0;sample<taps;sample++) {
                float shutter=taps>1 ? float(sample)/float(taps-1) : 0;
                // Zoom changes spans; pan changes centers. The two shutter strengths are independent.
                float2 destSize=mix(currentDest.zw,u[24].zw,u[16].x*shutter);
                float2 destCenter=mix(currentDest.xy+currentDest.zw*.5,u[24].xy+u[24].zw*.5,u[16].w*shutter);
                float4 dest=float4(destCenter-destSize*.5,destSize);
                float2 cropSize=mix(u[5].zw,u[13].zw,u[16].x*shutter);
                float2 cropCenter=mix(u[5].xy+u[5].zw*.5,u[13].xy+u[13].zw*.5,u[16].w*shutter);
                float4 sampleResult=result;
                float radius=clamp(u[6].x,0.0,min(dest.z,dest.w)*.5);
                float4 shadowRect=dest; shadowRect.xy+=float2(u[14].y,u[6].w);
                float sd=rounded(p,shadowRect,radius);
                float shadow=exp(-max(sd,0.0)*max(sd,0.0)/(2*max(u[6].y*u[6].y,1.0)))*u[6].z;
                sampleResult=over(sampleResult,float4(0,0,0,shadow));
                float mask=1-smoothstep(-.5,.5,rounded(p,dest,radius));
                float2 uv=(p-dest.xy)/max(dest.zw,float2(.000001));
                float scale=min(dest.z*u[35].x/(u[23].x*cropSize.x),dest.w*u[35].y/(u[23].y*cropSize.y));
                float4 tex=screenSample(screen,s,cropCenter-cropSize*.5+uv*cropSize,float4(cropCenter-cropSize*.5,cropSize),u[23].xy,u[19],u[20],u[34],scale);
                float inset=clamp(u[14].x,0.0,min(dest.z,dest.w)*.5);
                float4 inner=float4(dest.xy+inset*(1-u[14].zw),dest.zw-2*inset);
                float border=inset>0 ? smoothstep(-.5,.5,rounded(p,inner,max(0.0,radius-inset))) : 0;
                tex=over(tex,float4(linearRGB(u[7].rgb),u[7].a*border));
                tex.a*=mask; sampleResult=over(sampleResult,tex);
                if(u[15].y>0) {
                    float4 titleRect=float4(dest.x,dest.y-26,dest.z,26);
                    float titleMask=1-smoothstep(-.5,.5,rounded(p,titleRect,min(radius,13.0)));
                    float4 title=float4(.08,.08,.09,titleMask);
                    for(int i=0;i<3;i++) {
                        float dotMask=1-smoothstep(4,5,length(p-float2(dest.x+14+18*i,dest.y-13)));
                        float3 dotColor=i==0 ? float3(.95,.2,.2) : i==1 ? float3(.95,.65,.1) : float3(.2,.75,.3);
                        title=over(title,float4(dotColor,dotMask));
                    }
                    sampleResult=over(sampleResult,title);
                }
                accumulated+=sampleResult/float(taps);
            }
            result=accumulated;
        }
        float2 cursorPoint=p;
        if (u[25].x>0 && u[3].z>0 && all(u[4].zw>0) && u[25].y>0) {
            float2 center=u[25].x>1 ? u[37].xy : u[4].xy+(u[26].xy-u[28].xy)/u[28].zw*u[4].zw;
            float2 delta=p-center;
            float distance=length(delta), radius=u[25].y;
            float radial=clamp(distance/radius,0.0,1.0);
            float refraction=1-u[25].z*.15*pow(radial,4.0);
            float2 uv=u[26].xy+delta/u[4].zw*u[27].zw*refraction;
            float2 fringe=delta/u[4].zw*u[25].w*.006*pow(radial,4.0);
            float2 inset=min(.5/u[23].xy,u[28].zw*.5);
            float2 cropMin=u[28].xy+inset, cropMax=u[28].xy+u[28].zw-inset;
            float scale=min(u[4].z*u[35].x/(u[23].x*u[27].z),u[4].w*u[35].y/(u[23].y*u[27].w));
            float4 lens=screenSample(screen,s,clamp(uv,cropMin,cropMax),u[28],u[23].xy,u[19],u[20],u[34],scale);
            lens.r=screenSample(screen,s,clamp(uv+fringe,cropMin,cropMax),u[28],u[23].xy,u[19],u[20],u[34],scale).r;
            lens.b=screenSample(screen,s,clamp(uv-fringe,cropMin,cropMax),u[28],u[23].xy,u[19],u[20],u[34],scale).b;
            float rim=u[25].z*.25*pow(radial,12.0);
            lens.rgb=mix(lens.rgb,float3(1),rim);
            float mask=(1-smoothstep(-.5,.5,distance-radius))*u[26].w;
            float shadow=exp(-pow(max(distance-radius,0.0),2.0)/max(1.0,radius*.2))*.22*u[26].w;
            result=over(result,float4(0,0,0,shadow));
            lens.a*=mask; result=over(result,lens);
            // Reproject the evaluated classic cursor into the unzoomed base or
            // lens. It uses the same source position, scale and rotation there.
            float2 baseUV=u[28].xy+(p-u[4].xy)/u[4].zw*u[28].zw;
            if(u[25].x>1) {
                // Core supplies cursor/click coordinates in the unzoomed base.
                if(distance<radius) cursorPoint=center+delta/u[26].z*refraction;
            } else {
                cursorPoint=u[4].xy+(baseUV-u[27].xy)/u[27].zw*u[4].zw;
                if(distance<radius) cursorPoint=u[4].xy+u[4].zw*.5+delta*refraction;
            }
        }
        if (u[9].y >= 0 && u[9].y <= 1) {
            float radius=8+32*u[9].y; float ring=1-smoothstep(1,3,abs(length(cursorPoint-u[10].xy)-radius));
            result=over(result,float4(.25,.55,1,ring*(1-u[9].y)*.65));
        }
        if (u[16].z>0 && u[9].x>0) {
            float glow=1-smoothstep(0,u[16].z,length(cursorPoint-u[17].xy)); result=over(result,float4(1,1,1,glow*.3));
        }
        if (all(u[8].zw>0) && u[9].x>0) {
            float4 sprite=0;
            for(int i=0;i<8;i++) {
                float2 offset=(u[17].zw-u[17].xy)*u[16].y*float(i)/7;
                float2 delta=cursorPoint-offset-u[17].xy;
                float cosine=cos(u[9].z), sine=sin(u[9].z);
                float2 unrotated=float2(cosine*delta.x+sine*delta.y,-sine*delta.x+cosine*delta.y)+u[17].xy;
                float2 uv=(unrotated-u[8].xy)/u[8].zw;
                float4 tex=0;
                if (all(uv>=0)&&all(uv<=1)) {
                    tex=cursor.sample(s,uv);
                }
                // Accumulate premultiplied samples, then recover straight alpha for over().
                sprite.rgb+=tex.rgb*tex.a/8; sprite.a+=tex.a/8;
            }
            if(sprite.a>0) sprite.rgb/=sprite.a; sprite.a*=u[9].x; result=over(result,sprite);
        }
        if (all(u[11].zw>0) && u[12].z>0) {
            float2 uv=(p-u[11].xy)/u[11].zw; float d;
            if (u[12].y == 1) d=(length((uv-.5)*2)-1)*min(u[11].z,u[11].w)*.5;
            else if (u[12].y == 2) d=(pow(pow(abs(uv.x-.5)*2,4.0)+pow(abs(uv.y-.5)*2,4.0),.25)-1)*min(u[11].z,u[11].w)*.5;
            else d=rounded(p,u[11],clamp(u[12].x,0.0,min(u[11].z,u[11].w)*.5));
            if(u[15].z>0) { float shadow=exp(-max(d,0.0)*max(d,0.0)/(2*u[15].z*u[15].z))*.3; result=over(result,float4(0,0,0,shadow)); }
            uv=coverUV(uv,u[11].zw,u[23].zw*u[18].zw); if(u[12].w>0) uv.x=1-uv.x;
            float2 selectedUV=u[18].xy+uv*u[18].zw, nativeUV=sourceUV(selectedUV,u[21],u[22]);
            float foreground=u[36].y>0 ? matte.sample(s,nativeUV).r : 1;
            float4 tex=cameraSample(cam,s,selectedUV,u[18],u[23].zw,u[21],u[22]);
            if(u[36].z>0) tex.rgb=mix(cameraBlur.sample(s,uv).rgb,tex.rgb,foreground);
            if(u[32].w>0) {
                if(u[30].z>0) {
                    float2 pixel=1/u[23].zw;
                    float3 adjacent=(cameraSample(cam,s,selectedUV+float2(pixel.x,0),u[18],u[23].zw,u[21],u[22]).rgb+cameraSample(cam,s,selectedUV-float2(pixel.x,0),u[18],u[23].zw,u[21],u[22]).rgb+cameraSample(cam,s,selectedUV+float2(0,pixel.y),u[18],u[23].zw,u[21],u[22]).rgb+cameraSample(cam,s,selectedUV-float2(0,pixel.y),u[18],u[23].zw,u[21],u[22]).rgb)*.25;
                    tex.rgb=clamp(tex.rgb+(tex.rgb-adjacent)*u[30].z*2,0.0,1.0);
                }
                if(u[30].y>0) {
                    float3 encoded=select(tex.rgb*12.92,1.055*pow(max(tex.rgb,0.0),float3(1/2.4))-.055,tex.rgb>.0031308);
                    float3 adjusted=encoded+float3(u[29].x*.09,u[29].x*.01,-u[29].x*.09);
                    adjusted=(adjusted-.5)*(1+u[29].y)+.5+u[29].w;
                    float luma=dot(adjusted,float3(.2126,.7152,.0722));
                    adjusted=luma+(adjusted-luma)*(1+u[29].z);
                    adjusted=clamp(pow(max(adjusted,0.0),float3(1/u[30].x)),0.0,1.0);
                    if(u[31].w>0) {
                        float3 coordinate=clamp((adjusted-u[31].xyz)/(u[32].xyz-u[31].xyz),0.0,1.0);
                        float size=float(cameraLUT.get_width());
                        adjusted=cameraLUT.sample(s,(coordinate*(size-1)+.5)/size).rgb;
                    }
                    tex.rgb=linearRGB(clamp(mix(encoded,adjusted,u[30].y),0.0,1.0));
                }
                if(u[30].w>0) {
                    float grain=fract(sin(dot(floor(nativeUV*float2(cam.get_width(),cam.get_height()))+u[33].x*61,float2(29.17,47.73)))*19731.37)-.5;
                    tex.rgb=clamp(tex.rgb+grain*u[30].w*.025,0.0,1.0);
                }
            }
            if(u[36].x>0) {
                float luma=dot(tex.rgb,float3(.2126,.7152,.0722));
                float3 subdued=mix(float3(luma),tex.rgb,.55)*.86;
                tex.rgb=mix(tex.rgb,subdued,(1-foreground)*u[36].x);
            }
            if(u[15].w>0) tex.a*=foreground; tex.a*=u[12].z*(1-smoothstep(-.5,.5,d)); result=over(result,tex);
        }
        // Deterministic sub-LSB dithering prevents gradient banding at the sRGB sink.
        float3 encoded=select(result.rgb*12.92,1.055*pow(max(result.rgb,0.0),float3(1/2.4))-.055,result.rgb>.0031308);
        result.rgb=linearRGB(clamp(encoded+noise/255,0.0,1.0));
        return result;
    }
    """
}

public extension RenderProjectSource {
    func renderBackgroundAsset(index: UInt32) throws -> URL { throw RenderError.unavailable("Background image asset \(index) is not resolved by this project source") }
}
