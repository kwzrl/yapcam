import CoreImage
import CoreVideo
import Metal

public extension FrameCompositor {
    /// Exact shared-compositor image for clipboard/still-frame actions. Call from a worker task.
    func image(_ frame: YcFrame, size: CGSize? = nil) throws -> CGImage {
        try image(frame,from: nil,size: size)
    }
    internal func image(_ frame: YcFrame,from source: (any RenderProjectSource)?,size: CGSize? = nil) throws -> CGImage {
        let requested=size ?? CGSize(width: Int(frame.canvas_w),height: Int(frame.canvas_h))
        guard requested.width.isFinite, requested.height.isFinite, requested.width>=1, requested.height>=1, requested.width<=8192, requested.height<=8192 else { throw RenderError.invalidSettings("Still image dimensions must be 1…8192") }
        let width=Int(requested.width.rounded()), height=Int(requested.height.rounded())
        var buffer: CVPixelBuffer?, cache: CVMetalTextureCache?
        let attributes: [String: Any]=[kCVPixelBufferMetalCompatibilityKey as String: true,kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,attributes as CFDictionary,&buffer)==kCVReturnSuccess,let buffer,
              CVMetalTextureCacheCreate(nil,nil,device,[kCVMetalTextureUsage as String: MTLTextureUsage([.shaderRead,.renderTarget]).rawValue] as CFDictionary,&cache)==kCVReturnSuccess,let cache,
              let commandBuffer=device.makeCommandQueue()?.makeCommandBuffer() else { throw RenderError.metal("Cannot allocate still image surface") }
        let surface=try TextureFrame(buffer: buffer,cache: cache,time: .zero,usage: [.shaderRead,.renderTarget])
        if let source { try encode(frame,from: source,to: surface.texture,in: commandBuffer) }
        else { try encode(frame,to: surface.texture,in: commandBuffer) }
        withExtendedLifetime(surface) { commandBuffer.commit(); commandBuffer.waitUntilCompleted() }
        guard commandBuffer.status == .completed else { throw RenderError.metal(commandBuffer.error?.localizedDescription ?? "Still render failed") }
        let colorSpace=CGColorSpace(name: CGColorSpace.sRGB)!
        let image=CIImage(cvPixelBuffer: buffer,options: [.colorSpace: colorSpace])
        guard let result=CIContext(mtlDevice: device).createCGImage(image,from: image.extent,format: .RGBA8,colorSpace: colorSpace) else { throw RenderError.write("Cannot create composited image") }
        return result
    }
}

@MainActor public extension PreviewPlayer {
    func currentImage() async throws -> CGImage {
        let source=renderProject, frame=try source.frame(atNs: currentNs), compositor=compositor
        // The C frame is a value; its unchecked carrier crosses only Swift worker tasks.
        let request=StillRequest(frame: frame)
        return try await Task.detached(priority: .userInitiated) { try compositor.image(request.frame,from: source) }.value
    }
}

private final class StillRequest: @unchecked Sendable {
    let frame: YcFrame
    init(frame: YcFrame) { self.frame=frame }
}
