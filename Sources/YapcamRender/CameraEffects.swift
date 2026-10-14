import Vision
import CoreVideo
import Metal

/// Vision consumes the decoder's pixel buffer directly; the segmentation output is mapped to Metal.
final class CameraEffects {
    private let segmentation = VNGeneratePersonSegmentationRequest()
    private let faces = VNDetectFaceRectanglesRequest()
    private let cache: CVMetalTextureCache
    private var previous: ObjectIdentifier?
    private var previousTime: CMTime?
    private var previousOptions: (Bool,Bool)?
    private var matte: TextureFrame?
    private var crop = SIMD4<Float>(0,0,1,1)
    init(cache: CVMetalTextureCache) {
        self.cache = cache; segmentation.qualityLevel = .accurate; segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }
    func evaluate(_ frame: TextureFrame, removeBackground: Bool, faceFraming: Bool) throws -> (TextureFrame?, SIMD4<Float>) {
        let identity = ObjectIdentifier(frame.pixelBuffer as AnyObject)
        if previous == identity, previousTime == frame.time, previousOptions?.0 == removeBackground, previousOptions?.1 == faceFraming { return (matte,crop) }
        var requests: [VNRequest] = []
        if removeBackground { requests.append(segmentation) }
        if faceFraming { requests.append(faces) }
        guard !requests.isEmpty else { return (nil,SIMD4(0,0,1,1)) }
        try VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer,orientation: .up,options: [:]).perform(requests)
        if removeBackground {
            guard let output = segmentation.results?.first?.pixelBuffer else { throw RenderError.unavailable("Vision did not produce a camera segmentation mask") }
            matte = try TextureFrame(buffer: output,cache: cache,time: frame.time,pixelFormat: .r8Unorm)
        }
        crop = SIMD4(0,0,1,1)
        if faceFraming, let face = faces.results?.max(by: { $0.boundingBox.width*$0.boundingBox.height < $1.boundingBox.width*$1.boundingBox.height }) {
            let faceRect = face.boundingBox
            let width = min(1,faceRect.width*3), height = min(1,faceRect.height*3)
            crop = SIMD4(Float(min(max(faceRect.midX-width/2,0),1-width)),Float(min(max(1-faceRect.midY-height/2,0),1-height)),Float(width),Float(height))
        }
        previous = identity; previousTime = frame.time; previousOptions = (removeBackground,faceFraming); return (matte,crop)
    }
}
