import CoreGraphics
import Metal
import Foundation

/// Only for our CGContext RGBA8/sRGB rasters; decoded video remains zero-copy IOSurface.
func generatedSRGBTexture(_ image: CGImage,device: MTLDevice) throws -> MTLTexture {
    guard image.bitsPerComponent==8,image.bitsPerPixel==32,image.alphaInfo == .premultipliedLast,
          image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Big,
          let provider=image.dataProvider,let data=provider.data else { throw RenderError.write("Generated image must have premultiplied RGBA8 pixels") }
    var pixels=Array(data as Data)
    for y in 0..<image.height { for x in 0..<image.width {
        let offset=y*image.bytesPerRow+x*4, alpha=Int(pixels[offset+3])
        if alpha>0 { for channel in 0..<3 { pixels[offset+channel]=UInt8(min(255,(Int(pixels[offset+channel])*255+alpha/2)/alpha)) } }
    } }
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,width: image.width,height: image.height,mipmapped: false)
    descriptor.usage = .shaderRead
    guard let texture=device.makeTexture(descriptor: descriptor) else { throw RenderError.metal("Cannot create generated sRGB texture") }
    texture.replace(region: MTLRegionMake2D(0,0,image.width,image.height),mipmapLevel: 0,withBytes: pixels,bytesPerRow: image.bytesPerRow)
    return texture
}
