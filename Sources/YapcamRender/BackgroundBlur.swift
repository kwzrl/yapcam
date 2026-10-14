import Metal
import MetalPerformanceShaders

/// Linear-light, GPU-only Gaussian background blur. Each command buffer owns its
/// intermediates, so preview and still rendering can use separate queues safely.
final class BackgroundBlur {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private var kernels: [Float: MPSImageGaussianBlur] = [:]
    init(device: MTLDevice) throws {
        self.device=device
        let library=try device.makeLibrary(source: Self.shader,options: nil)
        let descriptor=MTLRenderPipelineDescriptor()
        descriptor.vertexFunction=library.makeFunction(name: "blurVertex")
        descriptor.fragmentFunction=library.makeFunction(name: "blurFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline=try device.makeRenderPipelineState(descriptor: descriptor)
    }
    func encode(source: TextureFrame,canvas: SIMD2<Float>,radius: Float,in cb: MTLCommandBuffer) throws -> MTLTexture {
        let display=source.geometry.displaySize
        let scale=min(1,512/max(display.width,display.height))
        let width=max(1,Int((display.width*scale).rounded())), height=max(1,Int((display.height*scale).rounded()))
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,width: width,height: height,mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = [.renderTarget,.shaderRead,.shaderWrite]
        guard let linear=device.makeTexture(descriptor: descriptor) else { throw RenderError.metal("Cannot allocate background blur surface") }
        let pass=MTLRenderPassDescriptor(); pass.colorAttachments[0].texture=linear; pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
        guard let encoder=cb.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.metal("Cannot encode background downsample") }
        var transform=[source.geometry.rowX,source.geometry.rowY]
        encoder.setRenderPipelineState(pipeline); encoder.setFragmentTexture(source.texture,index: 0)
        encoder.setFragmentBytes(&transform,length: 2*MemoryLayout<SIMD4<Float>>.stride,index: 0)
        encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3); encoder.endEncoding()
        guard radius>0 else { return linear }
        let coverScale=max(canvas.x/Float(width),canvas.y/Float(height))
        let sigma=max(0.1,radius/coverScale)
        guard sigma<=512 else { throw RenderError.invalidSettings("Background blur radius is too large at this canvas size") }
        if kernels[sigma] == nil {
            if kernels.count>=4 { kernels.removeAll() }
            let kernel=MPSImageGaussianBlur(device: device,sigma: sigma); kernel.edgeMode = .clamp; kernels[sigma]=kernel
        }
        guard let blurred=device.makeTexture(descriptor: descriptor) else { throw RenderError.metal("Cannot allocate Gaussian output") }
        kernels[sigma]!.encode(commandBuffer: cb,sourceTexture: linear,destinationTexture: blurred)
        return blurred
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 p [[position]]; float2 uv; };
    vertex V blurVertex(uint id [[vertex_id]]) { float2 uv=float2((id<<1)&2,id&2); V v; v.p=float4(uv.x*2-1,1-uv.y*2,0,1); v.uv=uv; return v; }
    fragment float4 blurFragment(V v [[stage_in]],constant float4 *rows [[buffer(0)]],texture2d<float> source [[texture(0)]]) {
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
        float2 uv=float2(dot(v.uv,rows[0].xy)+rows[0].z,dot(v.uv,rows[1].xy)+rows[1].z);
        return source.sample(s,uv);
    }
    """
}
