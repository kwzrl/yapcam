import Metal

/// Original bounded erosion/feather pass over Vision's own person mask.
final class CameraMatteProcessor {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    init(device: MTLDevice) throws {
        self.device=device
        let library=try device.makeLibrary(source: Self.shader,options: nil)
        guard let function=library.makeFunction(name: "matteEdges") else { throw RenderError.metal("Missing camera matte kernel") }
        pipeline=try device.makeComputePipelineState(function: function)
    }
    /// Native UV displacement per canvas pixel, accounting for cover crop,
    /// face framing, mirror and track orientation. Erosion remains isotropic in
    /// the displayed camera even when the mask is a different resolution.
    static func steps(displaySize: SIMD2<Float>,rowX: SIMD4<Float>,rowY: SIMD4<Float>,
                      crop: SIMD4<Float>,destination: SIMD2<Float>,mirrored: Bool) -> SIMD4<Float> {
        let a=destination.x/destination.y, b=displaySize.x*crop.z/(displaySize.y*crop.w)
        let cover=a>b ? SIMD2<Float>(1,b/a) : SIMD2<Float>(a/b,1)
        let dx=crop.z*cover.x/destination.x*(mirrored ? -1 : 1), dy=crop.w*cover.y/destination.y
        return SIMD4(rowX.x*dx,rowY.x*dx,rowX.y*dy,rowY.y*dy)
    }
    func encode(_ source: MTLTexture,settings: CameraMatteSettings,steps: SIMD4<Float>,in cb: MTLCommandBuffer) throws -> MTLTexture {
        try settings.validate()
        guard (0..<4).allSatisfy({ steps[$0].isFinite }) else { throw RenderError.invalidSettings("Invalid camera matte geometry") }
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,width: source.width,height: source.height,mipmapped: false)
        desc.usage=[.shaderRead,.shaderWrite]; desc.storageMode = .private
        guard let output=device.makeTexture(descriptor: desc), let encoder=cb.makeComputeCommandEncoder() else { throw RenderError.metal("Cannot allocate camera matte pass") }
        encoder.label="Camera cutout edge pass"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source,index: 0); encoder.setTexture(output,index: 1)
        var uniforms=[SIMD4(settings.edgeSoftness,settings.edgeInsetPixels,0,0),steps]
        encoder.setBytes(&uniforms,length: uniforms.count*MemoryLayout<SIMD4<Float>>.stride,index: 0)
        encoder.dispatchThreads(MTLSize(width: source.width,height: source.height,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
        encoder.endEncoding()
        return output
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void matteEdges(texture2d<float> source [[texture(0)]],texture2d<float,access::write> output [[texture(1)]],
                           constant float4 *u [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
        if(gid.x>=output.get_width() || gid.y>=output.get_height()) return;
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
        float2 uv=(float2(gid)+.5)/float2(output.get_width(),output.get_height());
        float coverage=source.sample(s,uv).r;
        if(u[0].y>0) {
            int reach=int(ceil(u[0].y));
            for(int y=-reach;y<=reach;y++) for(int x=-reach;x<=reach;x++) {
                if(x*x+y*y>u[0].y*u[0].y) continue;
                coverage=min(coverage,source.sample(s,uv+float(x)*u[1].xy+float(y)*u[1].zw).r);
            }
            // Sample the fractional boundary too; integer-only erosion would
            // turn the 0.1px control into visible one-pixel steps.
            for(int i=0;i<16;i++) {
                float angle=float(i)*6.28318530718/16;
                float2 delta=(cos(angle)*u[1].xy+sin(angle)*u[1].zw)*u[0].y;
                coverage=min(coverage,source.sample(s,uv+delta).r);
            }
        }
        float alpha=u[0].x>0 ? smoothstep(.5-u[0].x*.5,.5+u[0].x*.5,coverage) : step(.5,coverage);
        output.write(float4(alpha),gid);
    }
    """
}
