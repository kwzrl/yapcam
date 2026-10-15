import CoreVideo
import Darwin

/// Exact visible BGRA comparison, with one retained buffer and no hash collisions.
/// Padding bytes never affect identity. Last-frame submission preserves the
/// chosen frame-grid endpoint even when the final image is static.
struct ExactFrameDeduplicator {
    private var previous: CVPixelBuffer?
    mutating func shouldAppend(_ buffer: CVPixelBuffer, isLast: Bool) throws -> Bool {
        let append: Bool
        if isLast || previous == nil { append=true }
        else { append = try !Self.samePixels(previous!,buffer) }
        if append { previous=buffer }
        return append
    }
    private static func samePixels(_ a: CVPixelBuffer,_ b: CVPixelBuffer) throws -> Bool {
        guard CVPixelBufferGetPixelFormatType(a)==kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(b)==kCVPixelFormatType_32BGRA else { throw RenderError.invalidSettings("VFR comparison requires BGRA frames") }
        let width=CVPixelBufferGetWidth(a), height=CVPixelBufferGetHeight(a)
        guard width==CVPixelBufferGetWidth(b), height==CVPixelBufferGetHeight(b) else { return false }
        guard CVPixelBufferLockBaseAddress(a,.readOnly)==kCVReturnSuccess else { throw RenderError.write("Cannot read VFR frame") }
        defer { CVPixelBufferUnlockBaseAddress(a,.readOnly) }
        guard CVPixelBufferLockBaseAddress(b,.readOnly)==kCVReturnSuccess else { throw RenderError.write("Cannot read VFR frame") }
        defer { CVPixelBufferUnlockBaseAddress(b,.readOnly) }
        let strideA=CVPixelBufferGetBytesPerRow(a), strideB=CVPixelBufferGetBytesPerRow(b), rowBytes=width*4
        guard let bytesA=CVPixelBufferGetBaseAddress(a), let bytesB=CVPixelBufferGetBaseAddress(b), strideA>=rowBytes, strideB>=rowBytes else { throw RenderError.write("Invalid VFR frame storage") }
        for y in 0..<height {
            if memcmp(bytesA.advanced(by: y*strideA),bytesB.advanced(by: y*strideB),rowBytes) != 0 { return false }
        }
        return true
    }
}
