@preconcurrency import AVFoundation
import Metal
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

public final class Exporter: @unchecked Sendable {
    private static let scheduler = ExportScheduler()
    private let project: any RenderProjectSource
    private let settings: ExportSettings
    private let destination: URL
    private let lock = NSLock()
    private var running = false
    private var completedMetrics: ExportMetrics?
    private var completedOutputs: [URL] = []
    private var completedEncodedVideoFrames: Int?
    private var speechReports: [SpeechEnhancementReport] = []
    public var speechEnhancementReports: [SpeechEnhancementReport] { lock.withLock { speechReports } }
    public var metrics: ExportMetrics? { lock.withLock { completedMetrics } }
    /// Both-codec jobs return the H.264 URL from run and list both completed files here.
    public var outputURLs: [URL] { lock.withLock { completedOutputs } }
    /// Actual catalog settings, including normalization of older sheet/saved presets.
    public var effectiveSettings: ExportSettings { settings }
    /// Actual submitted video samples; metrics.frames still counts rendered grid
    /// evaluations. Both sums its two files; GIF has no encoded video track.
    public var encodedVideoFrames: Int? { lock.withLock { completedEncodedVideoFrames } }
    public init(project: any RenderProjectSource, settings: ExportSettings, destination: URL) throws {
        self.project = try project.renderSnapshot()
        guard settings.fps > 0, settings.outputHeight > 0 else { throw RenderError.invalidSettings("Export dimensions and frame rate must be positive") }
        self.settings = settings.closestValidPreset(); self.destination = destination
        _ = try self.settings.validatedRange(duration: self.project.durationNs)
        guard destination.isFileURL else { throw RenderError.invalidSettings("Export destination must be a local file") }
    }
    public func run(progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        try await run(progress: progress,status: { _ in })
    }
    /// Status callbacks may run off MainActor; waiting cancellation creates no file.
    public func run(progress: @Sendable @escaping (Double) -> Void,
                    status: @Sendable @escaping (ExportPhase) -> Void) async throws -> URL {
        guard lock.withLock({
            if running { return false }
            running=true; completedMetrics=nil; completedOutputs=[]; completedEncodedVideoFrames=nil; speechReports=[]
            return true
        }) else { throw RenderError.write("This exporter is already running") }
        defer { lock.withLock { running = false } }
        do {
            let result = try await Self.scheduler.run(waiting: { status(.waiting) }) {
                status(.preparing)
                let result = try await self.renderInSlot { value in
                    if value == 0 { status(.rendering) }
                    progress(value)
                }
                status(.completed)
                return result
            }
            return result
        } catch {
            if error is CancellationError { status(.cancelled) }
            else { status(.failed(error.localizedDescription)) }
            throw error
        }
    }
    // Both children inherit their parent's global slot; reacquiring would deadlock.
    private func renderInSlot(progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        let startTime = ProcessInfo.processInfo.systemUptime
        if settings.codec == .both { return try await runBoth(startTime: startTime, progress: progress) }
        let range = try settings.validatedRange(duration: project.durationNs)
        let first = try project.frame(atNs: range.lowerBound)
        let size = try settings.outputSize(canvasWidth: first.canvas_w, canvasHeight: first.canvas_h)
        let width = size.width, height = size.height
        let count = ExportTiming.frameCount(durationNs: Int64(range.count),fps: settings.fps)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw RenderError.write("Destination already exists; choose a new filename") }
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".yapcam-export-\(UUID().uuidString).\(settings.format.rawValue)")
        defer { if FileManager.default.fileExists(atPath: partial.path) { try? FileManager.default.removeItem(at: partial) } }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw RenderError.metal("Metal unavailable") }
        let compositor = try FrameCompositor(device: device, project: project, framesPerSecond: settings.fps)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, [kCVMetalTextureUsage as String: MTLTextureUsage([.shaderRead,.renderTarget]).rawValue] as CFDictionary, &cache) == kCVReturnSuccess, let cache else { throw RenderError.metal("Export texture cache unavailable") }
        progress(0)
        if settings.format == .gif {
            try await writeGIF(partial, range: range, count: count, width: width, height: height, compositor: compositor, queue: queue, cache: cache, progress: progress)
        } else {
            try await writeVideo(partial, range: range, count: count, width: width, height: height, compositor: compositor, queue: queue, cache: cache, progress: progress)
        }
        try Task.checkCancellation()
        // Same-directory move is atomic and never exposes a partial export as the final file.
        try FileManager.default.moveItem(at: partial, to: destination)
        lock.withLock { completedMetrics = ExportMetrics(frames: count, elapsedSeconds: ProcessInfo.processInfo.systemUptime - startTime, mediaSeconds: Double(range.count)/1e9) }
        lock.withLock { completedOutputs = [destination] }
        progress(1)
        return destination
    }
    private func runBoth(startTime: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let companion = settings.destinations(for: destination)[1]
        guard !FileManager.default.fileExists(atPath: destination.path), !FileManager.default.fileExists(atPath: companion.path) else { throw RenderError.write("An export destination already exists") }
        let directory = destination.deletingLastPathComponent().appendingPathComponent(".yapcam-pair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var children: [Exporter] = []
        for (i,codec) in [ExportSettings.Codec.h264,.hevc].enumerated() {
            var options = settings; options.codec = codec
            let child = try Exporter(project: project,settings: options,destination: directory.appendingPathComponent("\(i).\(settings.format.rawValue)"))
            _ = try await child.renderInSlot { value in progress((Double(i)+value)/2) }
            children.append(child)
        }
        try Task.checkCancellation()
        let duration = try settings.validatedRange(duration: project.durationNs)
        try ExportPublication.publish([(children[0].destination,destination),(children[1].destination,companion)])
        lock.withLock {
            completedOutputs = [destination,companion]
            completedEncodedVideoFrames=children.reduce(0) { $0+($1.encodedVideoFrames ?? 0) }
            completedMetrics = ExportMetrics(frames: children.reduce(0) { $0+($1.metrics?.frames ?? 0) },elapsedSeconds: ProcessInfo.processInfo.systemUptime-startTime,mediaSeconds: Double(duration.count)/1e9)
        }
        progress(1); return destination
    }
    private func makePool(width: Int, height: Int) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else { throw RenderError.metal("Cannot allocate export pixel pool") }
        return pool
    }
    private func render(index: Int, range: Range<Int64>, pool: CVPixelBufferPool, compositor: FrameCompositor, queue: MTLCommandQueue, cache: CVMetalTextureCache) throws -> CVPixelBuffer {
        let offset = ExportTiming.offsetNs(index: index,fps: settings.fps)
        let timestamp = range.lowerBound + offset
        let frame = try project.frame(atNs: min(timestamp, range.upperBound - 1))
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw RenderError.metal("Cannot allocate export frame") }
        let target = try TextureFrame(buffer: buffer, cache: cache, time: .zero, usage: [.shaderRead,.renderTarget])
        guard let cb = queue.makeCommandBuffer() else { throw RenderError.metal("Cannot create export command buffer") }
        try compositor.encode(frame, to: target.texture, in: cb)
        withExtendedLifetime(target) { cb.commit(); cb.waitUntilCompleted() }
        guard cb.status == .completed else { throw RenderError.metal(cb.error?.localizedDescription ?? "GPU export failed") }
        return buffer
    }
    private func ready(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        let deadline=ProcessInfo.processInfo.systemUptime+30
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime<deadline else { throw RenderError.write("Timed out waiting for the \(input.mediaType.rawValue) encoder") }
            guard writer.status == .writing else { throw RenderError.write(writer.error?.localizedDescription ?? "Writer stopped") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private func writeVideo(_ url: URL, range: Range<Int64>, count: Int, width: Int, height: Int, compositor: FrameCompositor, queue: MTLCommandQueue, cache: CVMetalTextureCache, progress: @escaping @Sendable (Double) -> Void) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: settings.format == .mp4 ? .mp4 : .mov)
        defer { if writer.status != .completed { writer.cancelWriting() } }
        let compression: [String: Any] = [AVVideoAverageBitRateKey: settings.videoBitrate(width: width, height: height), AVVideoExpectedSourceFrameRateKey: settings.fps, AVVideoMaxKeyFrameIntervalKey: settings.fps * 2, AVVideoAllowFrameReorderingKey: false]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: settings.codec == .h264 ? AVVideoCodecType.h264 : .hevc, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true], AVVideoCompressionPropertiesKey: compression, AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        video.expectsMediaDataInRealTime = false
        guard writer.canAdd(video) else { throw RenderError.write("Requested video codec is unavailable") }
        writer.add(video)
        let pool = try makePool(width: width, height: height)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        // Microphone channel conversion can prepare media even with DSP disabled.
        let preparationWeight=settings.includeAudio ? 0.15 : 0
        let timeline: AudioTimeline?
        if settings.includeAudio {
            timeline=try await AudioTimeline.prepare(project: project,range: range,speechEnhancement: settings.speechEnhancement) { value in progress(value*preparationWeight) }
        } else { timeline=nil }
        // Native audio readers can reopen URLs after creation; retain all temporary media until joined.
        defer { withExtendedLifetime(timeline) {} }
        lock.withLock { speechReports=timeline?.speechReports ?? [] }
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
        let context = audioReader.flatMap { pair in audio.map { AudioPumpContext(reader: pair.0,output: pair.1,input: $0,writer: writer) } }
        // Each input advances whenever it is ready. Feeding only up to the current
        // video PTS can deadlock the writer's muxer at an interleave/segment boundary.
        let audioTask = context.map { context in
            Task.detached(priority: .userInitiated) { [self] in
                do { try await pumpAudio(context) }
                catch { context.writer.cancelWriting(); throw error }
            }
        }
        let cancellation=ExportCancellation(writer: writer,reader: audioReader?.0,pump: audioTask)
        var deduplicator=ExactFrameDeduplicator(), encodedFrames=0
        try await withTaskCancellationHandler {
            do {
                for index in 0..<count {
                    try Task.checkCancellation()
                    let time = CMTime(value: Int64(index), timescale: Int32(settings.fps))
                    try await ready(video, writer: writer)
                    let buffer = try autoreleasepool { try render(index: index, range: range, pool: pool, compositor: compositor, queue: queue, cache: cache) }
                    try Task.checkCancellation()
                    let append: Bool
                    if settings.variableFrameRate { append=try deduplicator.shouldAppend(buffer,isLast: index==count-1) }
                    else { append=true }
                    if append {
                        guard adaptor.append(buffer, withPresentationTime: time) else { throw RenderError.write(writer.error?.localizedDescription ?? "Cannot append video") }
                        encodedFrames += 1
                    }
                    progress(preparationWeight+Double(index+1)/Double(count)*(0.95-preparationWeight))
                }
                video.markAsFinished()
                try await audioTask?.value
                writer.endSession(atSourceTime: CMTime(value: Int64(count), timescale: Int32(settings.fps)))
                await writer.finishWriting()
                try Task.checkCancellation()
                guard writer.status == .completed else { throw RenderError.write(writer.error?.localizedDescription ?? "Export did not finish") }
            } catch {
                let original=error
                audioTask?.cancel(); writer.cancelWriting(); audioReader?.0.cancelReading()
                // Join the pump before deleting any files or releasing its media sources.
                var audioFailure: Error?
                do { try await audioTask?.value } catch { if !(error is CancellationError) { audioFailure=error } }
                try Task.checkCancellation()
                throw audioFailure ?? original
            }
        } onCancel: { cancellation.cancel() }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videos = try await asset.loadTracks(withMediaType: .video), audios = try await asset.loadTracks(withMediaType: .audio)
        guard videos.count == 1, audios.count == (audio == nil ? 0 : 1), abs(duration.seconds - Double(range.count)/1e9) <= 1 / Double(settings.fps) + 0.000_001 else { throw RenderError.verification("Export duration or track count differs from the requested timeline") }
        let size = try await videos[0].load(.naturalSize)
        guard Int(size.width) == width, Int(size.height) == height else { throw RenderError.verification("Export dimensions differ from settings") }
        lock.withLock { completedEncodedVideoFrames=encodedFrames }
    }
    private func pumpAudio(_ context: AudioPumpContext) async throws {
        let pump=MediaInputPump<CMSampleBuffer>(
            request: { queue,callback in context.input.requestMediaDataWhenReady(on: queue,using: callback) },
            ready: { context.input.isReadyForMoreMediaData },
            read: {
                guard context.writer.status == .writing else { throw RenderError.write(context.writer.error?.localizedDescription ?? "Writer stopped") }
                return context.output.copyNextSampleBuffer()
            },
            append: { sample in guard context.input.append(sample) else { throw RenderError.write(context.writer.error?.localizedDescription ?? "Cannot append audio") } },
            end: {
                guard context.reader.status == .completed else { throw RenderError.decode(context.reader.error.map { "Audio reader: \($0 as NSError)" } ?? "Audio reader stopped before completion") }
                context.input.markAsFinished()
            },
            // markAsFinished ends requests; failures cancel the owning writer.
            stop: {},
            cancelSource: { context.reader.cancelReading() })
        try await pump.run()
    }
    private func writeGIF(_ url: URL, range: Range<Int64>, count: Int, width: Int, height: Int, compositor: FrameCompositor, queue: MTLCommandQueue, cache: CVMetalTextureCache, progress: @Sendable (Double) -> Void) async throws {
        let destination = try GIFFrameDestination(url: url, count: count, disableLoop: settings.gifDisableLoop)
        let context = CIContext(mtlDevice: compositor.device)
        let colors = CGColorSpace(name: CGColorSpace.sRGB)!
        let pool = try makePool(width: width, height: height)
        func frame(_ index: Int) throws -> CGImage {
            let buffer = try render(index: index, range: range, pool: pool, compositor: compositor, queue: queue, cache: cache)
            let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colors])
            guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colors) else { throw RenderError.write("Cannot convert GIF frame") }
            return cg
        }
        let palette: GIFPalette
        if settings.gifHighQuality {
            var histogram = GIFPaletteHistogram()
            for index in 0..<count {
                try Task.checkCancellation()
                try autoreleasepool { try histogram.add(frame(index)) }
                progress(Double(index+1)/Double(count)*0.35)
            }
            palette = try histogram.palette()
        } else { palette = GIFPalette.fast() }
        // GIF delays are integral centiseconds. Distribute rounding error across frames
        // so total timing remains correct instead of losing time on every frame.
        for index in 0..<count {
            try Task.checkCancellation()
            let delay = ExportTiming.gifDelay(index: index,count: count,durationNs: Int64(range.count))
            try autoreleasepool {
                let cg = try palette.indexed(frame(index))
                destination.add(cg, delay: delay)
            }
            let initial = settings.gifHighQuality ? 0.35 : 0.0
            progress(initial+Double(index+1)/Double(count)*(0.95-initial))
        }
        let source = try destination.finish()
        var duration = 0.0
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any], let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any], let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] ?? gif[kCGImagePropertyGIFDelayTime]) as? Double else { throw RenderError.verification("GIF frame delay missing") }
            duration += delay
        }
        guard abs(duration - Double(range.count)/1e9) <= 1/Double(settings.fps)+0.000_001 else { throw RenderError.verification("GIF timing differs from requested duration") }
    }
}

private final class AudioPumpContext: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderAudioMixOutput
    let input: AVAssetWriterInput
    let writer: AVAssetWriter
    init(reader: AVAssetReader,output: AVAssetReaderAudioMixOutput,input: AVAssetWriterInput,writer: AVAssetWriter) { self.reader=reader; self.output=output; self.input=input; self.writer=writer }
}

private final class ExportCancellation: @unchecked Sendable {
    let writer: AVAssetWriter
    let reader: AVAssetReader?
    let pump: Task<Void, Error>?
    init(writer: AVAssetWriter,reader: AVAssetReader?,pump: Task<Void, Error>?) { self.writer=writer; self.reader=reader; self.pump=pump }
    func cancel() { pump?.cancel(); writer.cancelWriting(); reader?.cancelReading() }
}
