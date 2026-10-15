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
    private let lock = NSLock()
    private let invalidationLock = NSLock()
    private var needsInvalidation = false
    private var sources: [String: FrameSource] = [:]
    private var images: [String: MTLTexture] = [:]
    private var cursorMetadata: [UInt32: [String: Cursor]] = [:]
    private struct CursorTextureKey: Hashable { let style: VectorCursorStyle; let set: String; let size: VectorCursorSize; let scale: Int }
    private var vectorCursors: [CursorTextureKey: VectorCursorTexture] = [:]
    private let empty: MTLTexture

    public init(device: MTLDevice, project: any RenderProjectSource) throws {
        self.device = device; self.project = project
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
    private func decoded(_ sample: YcSample, track: String) throws -> TextureFrame? {
        guard sample.present != 0 else { return nil }
        guard let segment = manifest.segment(at: sample.segment), let path = segment.files[track] else { throw RenderError.missingMedia("Missing \(track) in segment \(sample.segment)") }
        if sources[path] == nil {
            if sources.count >= 3 { sources.removeAll() }
            sources[path] = try FrameSource(url: packageMediaURL(path, root: project.packageURL.appendingPathComponent("recording")), cache: cache) }
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
        let invalidate = invalidationLock.withLock { let value=needsInvalidation; needsInvalidation=false; return value }
        if invalidate { sources.removeAll(); images.removeAll(); cursorMetadata.removeAll(); cameraEffects.invalidate(); layerRenderer.invalidate(); CVMetalTextureCacheFlush(cache,0) }
        guard target.pixelFormat == .bgra8Unorm_srgb, frame.canvas_w > 0, frame.canvas_h > 0 else { throw RenderError.metal("Compositor requires an sRGB BGRA target and nonzero canvas") }
        let effects = try project.renderEffects(atNs: frame.tl_ns,canvasSize: CGSize(width: Int(frame.canvas_w),height: Int(frame.canvas_h)))
        let options = effects.configuration
        try validateFrame(frame,configuration: options)
        let screen = try decoded(frame.screen, track: "screen")
        let camera = try decoded(frame.camera, track: "camera")
        var matte: TextureFrame?
        var cameraCrop = SIMD4<Float>(0,0,1,1)
        if let camera { (matte,cameraCrop) = try cameraEffects.evaluate(camera,removeBackground: options.cameraBackgroundRemoval,faceFraming: options.cameraFaceFraming) }
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
        let zoomBlur=options.zoomMotionBlur ?? frame.motion_blur
        let panBlur=options.panMotionBlur ?? frame.motion_blur
        let prior=(zoomBlur>0 || panBlur>0 || options.cursorMotionBlur>0) && frame.tl_ns>0
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
            previous, SIMD4(frame.inset_width, 0, 0, 0),
            SIMD4(options.backgroundNoise,options.windowChrome ? 1 : 0, options.cameraShadowRadius, matte == nil ? 0 : 1),
            SIMD4(zoomBlur,options.cursorMotionBlur,options.cursorSpotlightRadius,panBlur),
            SIMD4(Float(frame.cursor_x),Float(frame.cursor_y),Float(frame.cursor_x),Float(frame.cursor_y)), cameraCrop,
            screen?.geometry.rowX ?? SIMD4(1,0,0,0), screen?.geometry.rowY ?? SIMD4(0,1,0,0),
            camera?.geometry.rowX ?? SIMD4(1,0,0,0), camera?.geometry.rowY ?? SIMD4(0,1,0,0),
            SIMD4(Float(screen?.geometry.displaySize.width ?? 1),Float(screen?.geometry.displaySize.height ?? 1),Float(camera?.geometry.displaySize.width ?? 1),Float(camera?.geometry.displaySize.height ?? 1)), rect(prior.screen_dest)
        ]
        if let loupe = options.glassLoupe {
            let g = loupe.geometry(frame)
            uniforms.append(SIMD4(1,g.radius,loupe.bevel,loupe.chromaticAberration))
            uniforms.append(SIMD4(g.focus.x,g.focus.y,g.scale,g.opacity))
            uniforms.append(crop)
            uniforms[5] = SIMD4(0,0,1,1); uniforms[13] = SIMD4(0,0,1,1)
            uniforms[16].x = 0 // The underlying screen stays unzoomed.
        } else {
            uniforms.append(.zero); uniforms.append(SIMD4(0.5,0.5,1,0)); uniforms.append(crop)
        }
        if options.cursorMotionBlur > 0 && frame.tl_ns > 0 {
            uniforms[17].z = Float(prior.cursor_x); uniforms[17].w = Float(prior.cursor_y)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
        guard let encoder = cb.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.metal("Cannot create render encoder") }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: uniforms.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
        for (index, texture) in [screen?.texture ?? empty, camera?.texture ?? empty, cursorTexture, background, matte?.texture ?? empty].enumerated() { encoder.setFragmentTexture(texture, index: index) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
        try layerRenderer.encode(effects.layers, canvas: SIMD2(Float(frame.canvas_w),Float(frame.canvas_h)), project: project, target: target, cb: cb)
        // CVMetalTexture and its IOSurface must survive until GPU completion.
        let retainedMatte = matte
        cb.addCompletedHandler { _ in _ = screen; _ = camera; _ = retainedMatte }
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
    fragment float4 fragmentMain(Vertex v [[stage_in]], constant float4 *u [[buffer(0)]], texture2d<float> screen [[texture(0)]], texture2d<float> cam [[texture(1)]], texture2d<float> cursor [[texture(2)]], texture2d<float> bg [[texture(3)]], texture2d<float> matte [[texture(4)]]) {
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
                float4 shadowRect=dest; shadowRect.y+=u[6].w;
                float sd=rounded(p,shadowRect,radius);
                float shadow=exp(-max(sd,0.0)*max(sd,0.0)/(2*max(u[6].y*u[6].y,1.0)))*u[6].z;
                sampleResult=over(sampleResult,float4(0,0,0,shadow));
                float mask=1-smoothstep(-.5,.5,rounded(p,dest,radius));
                float2 uv=(p-dest.xy)/max(dest.zw,float2(.000001));
                float4 tex=screen.sample(s,sourceUV(cropCenter-cropSize*.5+uv*cropSize,u[19],u[20]));
                float inset=clamp(u[14].x,0.0,min(dest.z,dest.w)*.5);
                float4 inner=float4(dest.xy+inset,dest.zw-2*inset);
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
            float2 center=u[4].xy+u[26].xy*u[4].zw;
            float2 delta=p-center;
            float distance=length(delta), radius=u[25].y;
            float radial=clamp(distance/radius,0.0,1.0);
            float refraction=1-u[25].z*.15*pow(radial,4.0);
            float2 uv=u[26].xy+delta/u[4].zw/u[26].z*refraction;
            float2 fringe=delta/u[4].zw*u[25].w*.006*pow(radial,4.0);
            float4 lens=screen.sample(s,sourceUV(uv,u[19],u[20]));
            lens.r=screen.sample(s,sourceUV(uv+fringe,u[19],u[20])).r;
            lens.b=screen.sample(s,sourceUV(uv-fringe,u[19],u[20])).b;
            float rim=u[25].z*.25*pow(radial,12.0);
            lens.rgb=mix(lens.rgb,float3(1),rim);
            float mask=(1-smoothstep(-.5,.5,distance-radius))*u[26].w;
            float shadow=exp(-pow(max(distance-radius,0.0),2.0)/max(1.0,radius*.2))*.22*u[26].w;
            result=over(result,float4(0,0,0,shadow));
            lens.a*=mask; result=over(result,lens);
            // Reproject the evaluated classic cursor into the unzoomed base or
            // lens. It uses the same source position, scale and rotation there.
            float2 baseUV=(p-u[4].xy)/u[4].zw;
            cursorPoint=u[4].xy+(baseUV-u[27].xy)/u[27].zw*u[4].zw;
            if(distance<radius) cursorPoint=u[4].xy+u[4].zw*.5+delta*refraction;
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
            uv=coverUV(uv,u[11].zw,u[23].zw*u[18].zw); if(u[12].w>0) uv.x=1-uv.x; uv=sourceUV(u[18].xy+uv*u[18].zw,u[21],u[22]);
            float4 tex=cam.sample(s,uv); if(u[15].w>0) tex.a*=matte.sample(s,uv).r; tex.a*=u[12].z*(1-smoothstep(-.5,.5,d)); result=over(result,tex);
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
