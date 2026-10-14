@preconcurrency import AVFoundation
import Metal
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public final class Exporter: @unchecked Sendable {
    private let project: any RenderProjectSource
    private let settings: ExportSettings
    private let destination: URL
    private let lock = NSLock()
    private var running = false
    private var completedMetrics: ExportMetrics?
    public var metrics: ExportMetrics? { lock.withLock { completedMetrics } }
    public init(project: any RenderProjectSource, settings: ExportSettings, destination: URL) throws {
        self.project = try project.renderSnapshot()
        self.settings = settings; self.destination = destination
        _ = try settings.validatedRange(duration: self.project.durationNs)
        guard destination.isFileURL else { throw RenderError.invalidSettings("Export destination must be a local file") }
    }
    public func run(progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        guard lock.withLock({ if running { return false }; running = true; return true }) else { throw RenderError.write("This exporter is already running") }
        defer { lock.withLock { running = false } }
        try Task.checkCancellation()
        let startTime = ProcessInfo.processInfo.systemUptime
        let range = try settings.validatedRange(duration: project.durationNs)
        let first = try project.frame(atNs: range.lowerBound)
        let width = try settings.outputWidth(canvasWidth: first.canvas_w, canvasHeight: first.canvas_h)
        let count = Int(ceil(Double(range.count) / 1e9 * Double(settings.fps)))
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw RenderError.write("Destination already exists; choose a new filename") }
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".yapcam-export-\(UUID().uuidString).\(settings.format.rawValue)")
        defer { if FileManager.default.fileExists(atPath: partial.path) { try? FileManager.default.removeItem(at: partial) } }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw RenderError.metal("Metal unavailable") }
        let compositor = try FrameCompositor(device: device, project: project)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { throw RenderError.metal("Export texture cache unavailable") }
        progress(0)
        if settings.format == .gif {
            try await writeGIF(partial, range: range, count: count, width: width, compositor: compositor, queue: queue, cache: cache, progress: progress)
        } else {
            try await writeVideo(partial, range: range, count: count, width: width, compositor: compositor, queue: queue, cache: cache, progress: progress)
        }
        try Task.checkCancellation()
        // Same-directory move is atomic and never exposes a partial export as the final file.
        try FileManager.default.moveItem(at: partial, to: destination)
        lock.withLock { completedMetrics = ExportMetrics(frames: count, elapsedSeconds: ProcessInfo.processInfo.systemUptime - startTime, mediaSeconds: Double(range.count)/1e9) }
        progress(1)
        return destination
    }
    private func makePool(width: Int) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: settings.outputHeight, kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else { throw RenderError.metal("Cannot allocate export pixel pool") }
        return pool
    }
    private func render(index: Int, range: Range<Int64>, pool: CVPixelBufferPool, compositor: FrameCompositor, queue: MTLCommandQueue, cache: CVMetalTextureCache) throws -> CVPixelBuffer {
        let timestamp = range.lowerBound + Int64((Double(index) * 1e9 / Double(settings.fps)).rounded())
        let frame = try project.frame(atNs: min(timestamp, range.upperBound - 1))
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw RenderError.metal("Cannot allocate export frame") }
        let target = try TextureFrame(buffer: buffer, cache: cache, time: .zero)
        guard let cb = queue.makeCommandBuffer() else { throw RenderError.metal("Cannot create export command buffer") }
        try compositor.encode(frame, to: target.texture, in: cb)
        cb.commit(); cb.waitUntilCompleted()
        guard cb.status == .completed else { throw RenderError.metal(cb.error?.localizedDescription ?? "GPU export failed") }
        return buffer
    }
    private func ready(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw RenderError.write(writer.error?.localizedDescription ?? "Writer stopped") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private func writeVideo(_ url: URL, range: Range<Int64>, count: Int, width: Int, compositor: FrameCompositor, queue: MTLCommandQueue, cache: CVMetalTextureCache, progress: @Sendable (Double) -> Void) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: settings.format == .mp4 ? .mp4 : .mov)
        defer { if writer.status != .completed { writer.cancelWriting() } }
        let compression: [String: Any] = [AVVideoAverageBitRateKey: settings.videoBitrate(width: width), AVVideoExpectedSourceFrameRateKey: settings.fps, AVVideoMaxKeyFrameIntervalKey: settings.fps * 2, AVVideoAllowFrameReorderingKey: false]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: settings.codec == .h264 ? AVVideoCodecType.h264 : .hevc, AVVideoWidthKey: width, AVVideoHeightKey: settings.outputHeight, AVVideoCompressionPropertiesKey: compression, AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        video.expectsMediaDataInRealTime = false
        guard writer.canAdd(video) else { throw RenderError.write("Requested video codec is unavailable") }
        writer.add(video)
        let pool = try makePool(width: width)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        let timeline = settings.includeAudio ? try AudioTimeline(project: project, range: range) : nil
        let audioReader = try timeline?.reader(rangeDuration: Int64(range.count))
        defer { audioReader?.0.cancelReading() }
        var audio: AVAssetWriterInput?
        if audioReader != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw RenderError.write("AAC audio encoding unavailable") }
            writer.add(input); audio = input
        }
        guard writer.startWriting() else { throw RenderError.write(writer.error?.localizedDescription ?? "Cannot start writer") }
        writer.startSession(atSourceTime: .zero)
        var nextAudio = audioReader?.1.copyNextSampleBuffer()
        for index in 0..<count {
            try Task.checkCancellation()
            let time = CMTime(value: Int64(index), timescale: Int32(settings.fps))
            // Feed interleaved audio/video so neither writer input waits on the other.
            while let sample = nextAudio, CMSampleBufferGetPresentationTimeStamp(sample) <= time, let audio {
                try await ready(audio, writer: writer)
                guard audio.append(sample) else { throw RenderError.write(writer.error?.localizedDescription ?? "Cannot append audio") }
                nextAudio = audioReader?.1.copyNextSampleBuffer()
            }
            try await ready(video, writer: writer)
            let buffer = try autoreleasepool { try render(index: index, range: range, pool: pool, compositor: compositor, queue: queue, cache: cache) }
            guard adaptor.append(buffer, withPresentationTime: time) else { throw RenderError.write(writer.error?.localizedDescription ?? "Cannot append video") }
            progress(Double(index + 1) / Double(count) * 0.95)
        }
        video.markAsFinished()
        while let sample = nextAudio, let audio {
            try Task.checkCancellation(); try await ready(audio, writer: writer)
            guard audio.append(sample) else { throw RenderError.write(writer.error?.localizedDescription ?? "Cannot append trailing audio") }
            nextAudio = audioReader?.1.copyNextSampleBuffer()
        }
        if audioReader?.0.status == .failed { throw RenderError.decode(audioReader?.0.error?.localizedDescription ?? "Audio decode failed") }
        audio?.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(count), timescale: Int32(settings.fps)))
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw RenderError.write(writer.error?.localizedDescription ?? "Export did not finish") }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videos = try await asset.loadTracks(withMediaType: .video), audios = try await asset.loadTracks(withMediaType: .audio)
        guard videos.count == 1, audios.count == (audio == nil ? 0 : 1), abs(duration.seconds - Double(range.count)/1e9) <= 1 / Double(settings.fps) + 0.000_001 else { throw RenderError.verification("Export duration or track count differs from the requested timeline") }
        let size = try await videos[0].load(.naturalSize)
        guard Int(size.width) == width, Int(size.height) == settings.outputHeight else { throw RenderError.verification("Export dimensions differ from settings") }
    }
    private func writeGIF(_ url: URL, range: Range<Int64>, count: Int, width: Int, compositor: FrameCompositor, queue: MTLCommandQueue, cache: CVMetalTextureCache, progress: @Sendable (Double) -> Void) async throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else { throw RenderError.write("Cannot create GIF") }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let context = CIContext(mtlDevice: compositor.device)
        let colors = CGColorSpace(name: CGColorSpace.sRGB)!
        let pool = try makePool(width: width)
        for index in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                let buffer = try render(index: index, range: range, pool: pool, compositor: compositor, queue: queue, cache: cache)
                let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colors])
                guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colors) else { throw RenderError.write("Cannot convert GIF frame") }
                CGImageDestinationAddImage(destination, cg, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / Double(settings.fps), kCGImagePropertyGIFUnclampedDelayTime: 1 / Double(settings.fps)]] as CFDictionary)
            }
            progress(Double(index+1)/Double(count)*0.95)
        }
        guard CGImageDestinationFinalize(destination), let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == count else { throw RenderError.verification("GIF finalization or frame count verification failed") }
        var duration = 0.0
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any], let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any], let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] ?? gif[kCGImagePropertyGIFDelayTime]) as? Double else { throw RenderError.verification("GIF frame delay missing") }
            duration += delay
        }
        guard abs(duration - Double(range.count)/1e9) <= 1/Double(settings.fps)+0.000_001 else { throw RenderError.verification("GIF timing differs from requested duration") }
    }
}
