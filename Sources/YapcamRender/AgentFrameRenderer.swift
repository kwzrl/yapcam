import CoreImage
import CoreVideo
import Metal
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

    public func capture(atNs ns: Int64, fitting size: CGSize) throws -> CGImage {
        let frame = try project.frame(atNs: ns)
        let scale = min(1, size.width / CGFloat(frame.canvas_w), size.height / CGFloat(frame.canvas_h))
        return try compositor.image(frame, size: CGSize(width: max(1, (CGFloat(frame.canvas_w) * scale).rounded()),
                                                        height: max(1, (CGFloat(frame.canvas_h) * scale).rounded())))
    }

    /// Core resolves cuts, speed and clip boundaries. Track offsets are then
    /// resolved independently of camera visibility/layout in the composition.
    public func grab(atNs ns: Int64, source: String) throws -> CGImage {
        let location = try sourceLocation(atNs: ns, source: source)
        if sources[location.path] == nil {
            if sources.count >= 3 { sources.removeAll() }
            sources[location.path] = try FrameSource(url: packageMediaURL(location.path, root: project.packageURL.appendingPathComponent("recording")), cache: cache)
        }
        let reader = sources[location.path]!
        guard source != "camera" || !reader.hasEnded(atNs: location.fileNs) else { throw RenderError.missingMedia("Camera has ended at this timeline time") }
        let decoded = try reader.frame(atNs: location.fileNs)
        let image = CIImage(cvPixelBuffer: decoded.pixelBuffer).transformed(by: decoded.geometry.transform)
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw RenderError.decode("Cannot read source pixels")
        }
        return result
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
