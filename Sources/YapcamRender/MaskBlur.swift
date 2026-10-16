import Foundation
import Metal
import MetalPerformanceShaders

/// Ordered composition-space blur. Scratch textures belong to one command buffer,
/// and are reused by every mask in that frame (never one pair per mask).
final class MaskBlur {
    struct Workspace { let source: MTLTexture; let filtered: MTLTexture }
    private let device: MTLDevice
    private let snapshotPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let copyPipeline: MTLRenderPipelineState
    private var kernels: [Float: MPSImageGaussianBlur] = [:]

    static func validate(radius: Float) throws {
        guard radius.isFinite,(0...128).contains(radius) else {
            throw RenderError.invalidSettings("Mask blur radius must be 0...128 canvas pixels")
        }
    }
    static func scaledSigma(radius: Float,canvas: SIMD2<Float>,width: Int,height: Int) throws -> Float {
        try validate(radius: radius)
        guard canvas.x.isFinite,canvas.y.isFinite,canvas.x>0,canvas.y>0,width>0,height>0 else {
            throw RenderError.invalidSettings("Invalid blur-mask canvas or output")
        }
        // Preview/export preserve canvas aspect; use the larger scale to cover
        // the subpixel discrepancy introduced by even output dimensions.
        let sigma=radius*max(Float(width)/canvas.x,Float(height)/canvas.y)
        guard sigma.isFinite else { throw RenderError.invalidSettings("Mask blur output scale is not finite") }
        return sigma
    }
    init(device: MTLDevice) throws {
        self.device=device
        let library=try device.makeLibrary(source: Self.shader,options: nil)
        func pipeline(_ fragment: String,_ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let descriptor=MTLRenderPipelineDescriptor()
            descriptor.vertexFunction=library.makeFunction(name: "maskVertex")
            descriptor.fragmentFunction=library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat=format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        snapshotPipeline=try pipeline("maskSnapshot",.rgba16Float)
        compositePipeline=try pipeline("maskComposite",.bgra8Unorm_srgb)
        copyPipeline=try pipeline("maskCopy",.bgra8Unorm_srgb)
    }
    private func texture(width: Int,height: Int,format: MTLPixelFormat) throws -> MTLTexture {
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,width: width,height: height,mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = format == .rgba16Float ? [.renderTarget,.shaderRead,.shaderWrite] : [.renderTarget,.shaderRead]
        guard let texture=device.makeTexture(descriptor: descriptor) else { throw RenderError.metal("Cannot allocate blur-mask surface") }
        return texture
    }
    func compositionTexture(width: Int,height: Int) throws -> MTLTexture {
        try texture(width: width,height: height,format: .bgra8Unorm_srgb)
    }
    func workspace(width: Int,height: Int) throws -> Workspace {
        try Workspace(source: texture(width: width,height: height,format: .rgba16Float),
                      filtered: texture(width: width,height: height,format: .rgba16Float))
    }
    private func encoder(target: MTLTexture,pipeline: MTLRenderPipelineState,load: MTLLoadAction,in cb: MTLCommandBuffer) throws -> MTLRenderCommandEncoder {
        let pass=MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction=load; pass.colorAttachments[0].storeAction = .store
        guard let encoder=cb.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.metal("Cannot encode blur mask") }
        encoder.setRenderPipelineState(pipeline)
        return encoder
    }
    /// Resolve into even a framebuffer-only MTK drawable without sampling it.
    func copy(_ source: MTLTexture,to target: MTLTexture,in cb: MTLCommandBuffer) throws {
        let encoder=try encoder(target: target,pipeline: copyPipeline,load: .dontCare,in: cb)
        encoder.setFragmentTexture(source,index: 0)
        encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3); encoder.endEncoding()
    }
    func encode(_ layer: RenderLayer,canvas: SIMD2<Float>,sigma: Float,target: MTLTexture,workspace: Workspace,in cb: MTLCommandBuffer) throws {
        let snapshot=try encoder(target: workspace.source,pipeline: snapshotPipeline,load: .dontCare,in: cb)
        snapshot.setFragmentTexture(target,index: 0)
        snapshot.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3); snapshot.endEncoding()
        if kernels[sigma] == nil {
            if kernels.count>=4 { kernels.removeAll() }
            let kernel=MPSImageGaussianBlur(device: device,sigma: sigma); kernel.edgeMode = .clamp
            kernels[sigma]=kernel
        }
        kernels[sigma]!.encode(commandBuffer: cb,sourceTexture: workspace.source,destinationTexture: workspace.filtered)
        let composite=try encoder(target: target,pipeline: compositePipeline,load: .load,in: cb)
        var uniforms=[SIMD4(canvas.x,canvas.y,layer.cornerRadius,layer.opacity),
                      SIMD4(Float(layer.rect.minX),Float(layer.rect.minY),Float(layer.rect.width),Float(layer.rect.height))]
        composite.setFragmentBytes(&uniforms,length: uniforms.count*MemoryLayout<SIMD4<Float>>.stride,index: 0)
        composite.setFragmentTexture(workspace.source,index: 0); composite.setFragmentTexture(workspace.filtered,index: 1)
        composite.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3); composite.endEncoding()
    }
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 p [[position]]; float2 uv; };
    vertex V maskVertex(uint id [[vertex_id]]) {
        float2 uv=float2((id<<1)&2,id&2); V v;
        v.p=float4(uv.x*2-1,1-uv.y*2,0,1); v.uv=uv; return v;
    }
    fragment float4 maskCopy(V v [[stage_in]],texture2d<float> source [[texture(0)]]) {
        return source.read(uint2(v.p.xy));
    }
    fragment float4 maskSnapshot(V v [[stage_in]],texture2d<float> source [[texture(0)]]) {
        float4 c=source.read(uint2(v.p.xy)); c.rgb*=c.a; return c;
    }
    fragment float4 maskComposite(V v [[stage_in]],constant float4 *u [[buffer(0)]],
                                 texture2d<float> source [[texture(0)]],texture2d<float> filtered [[texture(1)]]) {
        float2 p=v.uv*u[0].xy, size=u[1].zw;
        float radius=clamp(u[0].z,0.0,min(size.x,size.y)*.5);
        float2 q=abs(p-u[1].xy-size*.5)-size*.5+radius;
        float d=length(max(q,0.0))+min(max(q.x,q.y),0.0)-radius;
        float coverage=(1-smoothstep(-.5,.5,d))*u[0].w;
        // Preserve pixels outside the antialiased rounded boundary exactly.
        if(coverage<=0) discard_fragment();
        uint2 position=uint2(v.p.xy);
        float4 c=mix(source.read(position),filtered.read(position),coverage);
        if(c.a>0) c.rgb/=c.a; return c;
    }
    """
}
