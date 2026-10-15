import Metal

struct CameraLUTTexture {
    let texture: MTLTexture
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>
    init(_ lut: CubeLUT, device: MTLDevice) throws {
        let n = lut.dimension
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D; descriptor.pixelFormat = .rgba32Float
        descriptor.width = n; descriptor.height = n; descriptor.depth = n
        descriptor.mipmapLevelCount = 1; descriptor.usage = .shaderRead; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.metal("Cannot allocate camera LUT") }
        lut.rgba.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake3D(0,0,0,n,n,n),mipmapLevel: 0,slice: 0,withBytes: bytes.baseAddress!,bytesPerRow: n*16,bytesPerImage: n*n*16)
        }
        self.texture = texture; self.minimum = lut.domainMinimum; self.maximum = lut.domainMaximum
    }
}
