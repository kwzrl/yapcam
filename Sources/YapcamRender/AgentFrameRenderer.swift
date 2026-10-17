import CoreImage
import CoreVideo
import Metal
import Accelerate
import YapcamCore

/// Worker-owned, immutable export evaluator and decoders. Never use on the UI thread.
public final class AgentFrameRenderer {
    private let project: Project
    private let compositor: FrameCompositor
    private let manifest: RecordingManifest
    private let cache: CVMetalTextureCache
    private let context: CIContext
    private var sources: [String: FrameSource] = [:]

    public init(snapshot: Project) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.metal("Metal unavailable") }
        project = snapshot
        compositor = try FrameCompositor(device: device, project: snapshot)
        manifest = try RecordingManifest.load(package: snapshot.packageURL)
        context = CIContext(mtlDevice: device)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw RenderError.metal("Cannot allocate source image cache")
        }
        self.cache = cache
    }

    public func capture(atNs ns: Int64, fitting size: CGSize, crop: AgentCaptureCrop = .frame) throws -> CGImage {
        let frame = try project.frame(atNs: ns)
        let canvas = CGSize(width: Int(frame.canvas_w), height: Int(frame.canvas_h))
        let area = try crop.area(canvas: canvas, recording: CGRect(x: frame.screen_dest.x, y: frame.screen_dest.y,
                                                                  width: frame.screen_dest.w, height: frame.screen_dest.h),
                                 recordingVisible: frame.screen.present != 0)
        // Size for the cropped picture, not the surrounding canvas. Bound the
        // intermediate texture even for a tiny recording on a very large canvas.
        let scale = min(1, size.width / area.width, size.height / area.height, 4096 / max(canvas.width, canvas.height))
        let rendered = try compositor.image(frame, size: CGSize(width: max(1, (canvas.width * scale).rounded()),
                                                               height: max(1, (canvas.height * scale).rounded())))
        if crop == .frame { return rendered }
        let pixels = CGRect(x: area.minX * CGFloat(rendered.width) / canvas.width,
                            y: area.minY * CGFloat(rendered.height) / canvas.height,
                            width: area.width * CGFloat(rendered.width) / canvas.width,
                            height: area.height * CGFloat(rendered.height) / canvas.height).integral
        guard let result = rendered.cropping(to: pixels) else { throw RenderError.decode("Cannot crop the recording area") }
        return result
    }

    /// Core resolves cuts, speed and clip boundaries. Track offsets are then
    /// resolved independently of camera visibility/layout in the composition.
    public func grab(atNs ns: Int64, source: String) throws -> CGImage {
        let image = try sourceImage(atNs: ns, source: source)
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw RenderError.decode("Cannot read source pixels")
        }
        return result
    }

    /// Compare small source signatures; editor zoom/cursor/background cannot
    /// masquerade as a view change in the recorded screen.
    public func signature(atNs ns: Int64) throws -> AgentFrameSignature {
        let decoded = try sourceFrame(atNs: ns, source: "screen")
        return try AgentFrameSignature(pixelBuffer: decoded.pixelBuffer)
    }

    private func sourceImage(atNs ns: Int64, source: String) throws -> CIImage {
        let decoded = try sourceFrame(atNs: ns, source: source)
        return CIImage(cvPixelBuffer: decoded.pixelBuffer).transformed(by: decoded.geometry.transform)
    }

    private func sourceFrame(atNs ns: Int64, source: String) throws -> TextureFrame {
        let location = try sourceLocation(atNs: ns, source: source)
        if sources[location.path] == nil {
            if sources.count >= 3 { sources.removeAll() }
            sources[location.path] = try FrameSource(url: packageMediaURL(location.path, root: project.packageURL.appendingPathComponent("recording")), cache: cache)
        }
        let reader = sources[location.path]!
        guard source != "camera" || !reader.hasEnded(atNs: location.fileNs) else { throw RenderError.missingMedia("Camera has ended at this timeline time") }
        return try reader.frame(atNs: location.fileNs)
    }

    // Internal for mapping regression tests, including hidden camera tracks.
    func sourceLocation(atNs ns: Int64, source: String) throws -> (path: String, fileNs: Int64) {
        guard ["screen", "camera"].contains(source) else { throw RenderError.invalidSettings("source must be screen or camera") }
        let src = try project.frame(atNs: ns).screen.src_ns
        guard let segment = manifest.segments.last(where: { $0.srcStartNs <= src }),
              src < segment.srcStartNs + segment.durationNs,
              let path = segment.files[source] else { throw RenderError.missingMedia("No \(source) at this timeline time") }
        let fileNs = src - segment.srcStartNs - (segment.trackStartNs[source] ?? 0)
        guard fileNs >= 0 else { throw RenderError.missingMedia("\(source) has not started at this timeline time") }
        return (path, fileNs)
    }
}

public enum AgentCaptureCrop: String, Sendable {
    case frame, content

    /// Core's destination is already in top-left canvas pixels, including any
    /// side-by-side layout. Intersect before scaling to handle slide animations.
    func area(canvas: CGSize, recording: CGRect, recordingVisible: Bool = true) throws -> CGRect {
        guard self == .frame || recordingVisible else { throw RenderError.invalidSettings("Recording is hidden by this layout; use crop:frame") }
        let bounds = CGRect(origin: .zero, size: canvas)
        let area = self == .frame ? bounds : recording.intersection(bounds)
        guard !area.isNull, !area.isEmpty else { throw RenderError.invalidSettings("No recording area is visible; use crop:frame") }
        return area
    }
}

public struct AgentFrameSignature: Sendable {
    private let rgba: [UInt8]
    init(rgba: [UInt8]) { self.rgba = rgba }

    /// FrameSource decodes BGRA. Mean RGB difference is channel-order and
    /// orientation invariant, so no GPU transform/readback is needed here.
    init(pixelBuffer: CVPixelBuffer) throws {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            throw RenderError.decode("Cannot read source frame for comparison")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw RenderError.decode("Missing source pixels") }
        var input = vImage_Buffer(data: address, height: vImagePixelCount(CVPixelBufferGetHeight(pixelBuffer)),
                                  width: vImagePixelCount(CVPixelBufferGetWidth(pixelBuffer)), rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
        var bytes = [UInt8](repeating: 0, count: 64 * 40 * 4)
        let status = bytes.withUnsafeMutableBytes { buffer in
            var output = vImage_Buffer(data: buffer.baseAddress!, height: 40, width: 64, rowBytes: 64 * 4)
            return vImageScale_ARGB8888(&input, &output, nil, vImage_Flags(kvImageNoFlags))
        }
        guard status == kvImageNoError else { throw RenderError.decode("Cannot downsample source frame (\(status))") }
        rgba = bytes
    }

    /// Normalized mean absolute RGB difference (0…1), ignoring alpha.
    public func difference(from other: Self) -> Double {
        guard !rgba.isEmpty, rgba.count == other.rgba.count, rgba.count.isMultiple(of: 4) else { return 1 }
        var total = 0
        for i in stride(from: 0, to: rgba.count, by: 4) {
            for channel in 0..<3 { total += abs(Int(rgba[i + channel]) - Int(other.rgba[i + channel])) }
        }
        return Double(total) / Double(rgba.count / 4 * 3 * 255)
    }
}
