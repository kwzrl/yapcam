import Vision
import CoreVideo
import Metal

/// Vision consumes the decoder's pixel buffer directly; the segmentation output is mapped to Metal.
final class CameraEffects {
    private let segmentation = VNGeneratePersonSegmentationRequest()
    private let faces = VNDetectFaceRectanglesRequest()
    private let cache: CVMetalTextureCache
    private var previous: ObjectIdentifier?
    private var previousBuffer: CVPixelBuffer?
    private var previousTime: CMTime?
    private var previousOptions: (Bool,Bool)?
    private var previousCrop: SIMD4<Float>?
    private var matte: TextureFrame?
    private var crop = SIMD4<Float>(0,0,1,1)
    init(cache: CVMetalTextureCache) {
        self.cache = cache; segmentation.qualityLevel = .accurate; segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }
    func invalidate() { previous=nil; previousBuffer=nil; previousTime=nil; previousOptions=nil; previousCrop=nil; matte=nil }
    func evaluate(_ frame: TextureFrame, removeBackground: Bool, faceFraming: Bool, baseCrop: SIMD4<Float> = SIMD4(0,0,1,1)) throws -> (TextureFrame?, SIMD4<Float>) {
        let identity = ObjectIdentifier(frame.pixelBuffer as AnyObject)
        if previous == identity, previousTime == frame.time, previousOptions?.0 == removeBackground, previousOptions?.1 == faceFraming, previousCrop == baseCrop { return (matte,crop) }
        var requests: [VNRequest] = []
        if removeBackground { requests.append(segmentation) }
        if faceFraming { requests.append(faces) }
        if !removeBackground { matte=nil }
        guard !requests.isEmpty else { invalidate(); return (nil,baseCrop) }
        try VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer,orientation: .up,options: [:]).perform(requests)
        if removeBackground {
            guard let output = segmentation.results?.first?.pixelBuffer else { throw RenderError.unavailable("Vision did not produce a camera segmentation mask") }
            matte = try TextureFrame(buffer: output,cache: cache,time: frame.time,pixelFormat: .r8Unorm)
        }
        crop = baseCrop
        let selected=CGRect(x: CGFloat(baseCrop.x),y: CGFloat(baseCrop.y),width: CGFloat(baseCrop.z),height: CGFloat(baseCrop.w))
        // Only faces inside the selected source region may drive framing.
        let visibleFaces=faces.results?.filter { face in
            let r=face.boundingBox
            let displayed=frame.geometry.displayRect(fromNativeNormalized: CGRect(x: r.minX,y: 1-r.maxY,width: r.width,height: r.height))
            return selected.contains(CGPoint(x: displayed.midX,y: displayed.midY))
        }
        if faceFraming, let face = visibleFaces?.max(by: { $0.boundingBox.width*$0.boundingBox.height < $1.boundingBox.width*$1.boundingBox.height }) {
            let faceRect = face.boundingBox
            let width = min(1,faceRect.width*3), height = min(1,faceRect.height*3)
            let native=CGRect(x: min(max(faceRect.midX-width/2,0),1-width),y: min(max(1-faceRect.midY-height/2,0),1-height),width: width,height: height)
            let displayed=frame.geometry.displayRect(fromNativeNormalized: native).intersection(selected)
            crop=SIMD4(Float(displayed.minX),Float(displayed.minY),Float(displayed.width),Float(displayed.height))
        }
        // Retain the identity's buffer so allocator reuse cannot produce a false cache hit.
        previous = identity; previousBuffer=frame.pixelBuffer; previousTime = frame.time; previousOptions = (removeBackground,faceFraming); previousCrop=baseCrop; return (matte,crop)
    }
}
