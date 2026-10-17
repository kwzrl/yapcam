@preconcurrency import AVFoundation
import Metal
import CoreVideo

final class TextureFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let cvTexture: CVMetalTexture
    let texture: MTLTexture
    let time: CMTime
    let geometry: SourceGeometry
    init(buffer: CVPixelBuffer, cache: CVMetalTextureCache, time: CMTime, pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb, transform: CGAffineTransform = .identity, usage: MTLTextureUsage = .shaderRead) throws {
        var wrapped: CVMetalTexture?
        let attributes=[kCVMetalTextureUsage as String: usage.rawValue] as CFDictionary
        let result = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, attributes, pixelFormat, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &wrapped)
        guard result == kCVReturnSuccess, let wrapped, let texture = CVMetalTextureGetTexture(wrapped) else { throw RenderError.metal("Cannot map decoded IOSurface to Metal (\(result))") }
        geometry=SourceGeometry(size: CGSize(width: CVPixelBufferGetWidth(buffer),height: CVPixelBufferGetHeight(buffer)),transform: transform)
        pixelBuffer = buffer; cvTexture = wrapped; self.texture = texture; self.time = time
    }
}

/// Serial reader with a bounded window and exact nearest-timestamp selection for VFR media.
final class FrameSource {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let cache: CVMetalTextureCache
    let preferredTransform: CGAffineTransform
    private let mediaEnd: CMTime
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var frames: [TextureFrame] = []
    private var exhausted = false
    private let capacity = 4
    private let reuseSeekReader: Bool
    private let onDecode: ((TextureFrame) throws -> Void)?
    private var seekReader: AVAssetReader?
    private var seekOutput: AVAssetReaderTrackOutput?
    private var randomWindow=false
    // Internal diagnostic for sparse-tail/scrubbing regression tests.
    private(set) var readerStartCount = 0
    private(set) var decodedFrameCount = 0
    private(set) var readerResetCount = 0
    init(url: URL, cache: CVMetalTextureCache,reuseSeekReader: Bool = true,
         onDecode: ((TextureFrame) throws -> Void)? = nil) throws {
        self.reuseSeekReader=reuseSeekReader
        self.onDecode=onDecode
        asset = AVURLAsset(url: url,options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = asset.tracks(withMediaType: .video).first else { throw RenderError.decode("No video track in \(url.lastPathComponent)") }
        self.track = track; self.cache = cache; preferredTransform=track.preferredTransform
        let end=track.timeRange.end
        guard end.isNumeric, end > .zero else { throw RenderError.decode("Video track has invalid duration") }
        mediaEnd=end
    }
    deinit { reader?.cancelReading(); seekReader?.cancelReading() }
    /// Optional device media may end before the recording segment; do not invent later frames.
    func hasEnded(atNs ns: Int64) -> Bool { CMTime(value: ns,timescale: 1_000_000_000)>=mediaEnd }
    private func restart(at time: CMTime) throws {
        randomWindow=false
        reader?.cancelReading()
        let r = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        o.alwaysCopiesSampleData = false
        guard r.canAdd(o) else { throw RenderError.decode("Cannot add video reader output") }
        r.add(o)
        let start=VideoSeekStart.time(asset: asset,track: track,requested: time)
        r.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        guard r.startReading() else { throw RenderError.decode(r.error?.localizedDescription ?? "Video reader failed") }
        reader = r; output = o; frames.removeAll(); exhausted = false
        readerStartCount += 1
    }
    private func randomSeek(at time: CMTime) throws -> Bool {
        guard reuseSeekReader,let range=VideoSeekStart.neighbours(asset: asset,track: track,requested: time) else { return false }
        var complete=false
        defer {
            if !complete { seekReader?.cancelReading(); seekReader=nil; seekOutput=nil; frames.removeAll(); randomWindow=false }
        }
        reader?.cancelReading(); reader=nil; output=nil
        if let seekReader,let seekOutput,seekReader.status == .reading {
            // Previous finite window was completely drained, as required by AVF.
            seekOutput.reset(forReadingTimeRanges: [NSValue(timeRange: range)])
            readerResetCount+=1
        } else {
            let r=try AVAssetReader(asset: asset)
            let o=AVAssetReaderTrackOutput(track: track,outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
            o.alwaysCopiesSampleData=false; o.supportsRandomAccess=true
            guard r.canAdd(o) else { throw RenderError.decode("Cannot add random-access video output") }
            r.add(o); r.timeRange=range
            guard r.startReading() else { throw RenderError.decode(r.error?.localizedDescription ?? "Random-access video reader failed") }
            seekReader=r; seekOutput=o; readerStartCount+=1
        }
        frames.removeAll()
        while let sample=seekOutput?.copyNextSampleBuffer() {
            guard let buffer=CMSampleBufferGetImageBuffer(sample) else { continue }
            decodedFrameCount+=1
            let frame = try TextureFrame(buffer: buffer,cache: cache,time: CMSampleBufferGetPresentationTimeStamp(sample),transform: preferredTransform)
            try onDecode?(frame)
            frames.append(frame)
            if frames.count>capacity { frames.removeFirst() }
        }
        guard seekReader?.status != .failed else { throw RenderError.decode(seekReader?.error?.localizedDescription ?? "Random-access video decode failed") }
        guard !frames.isEmpty else { throw RenderError.decode("No random-access video samples at requested time") }
        randomWindow=true; exhausted=range.end>=mediaEnd
        complete=true
        return true
    }
    func frame(atNs ns: Int64) throws -> TextureFrame {
        guard ns >= 0 else { throw RenderError.decode("Negative source frame timestamp") }
        let time = CMTime(value: ns, timescale: 1_000_000_000)
        let backward=frames.first.map { time < $0.time } ?? false
        let distant = !exhausted && (frames.last.map { time.seconds-$0.time.seconds>1 } ?? false)
        if !frames.isEmpty,(backward || distant),try randomSeek(at: time) {
            return frames.min { abs($0.time.seconds-time.seconds)<abs($1.time.seconds-time.seconds) }!
        }
        if randomWindow {
            if !backward,(exhausted || frames.last.map { time <= $0.time } == true) {
                return frames.min { abs($0.time.seconds-time.seconds)<abs($1.time.seconds-time.seconds) }!
            }
            // Resume a sequential stream after scrubbing; exports/playback do not
            // pay for a reset every frame. Keep the drained seek reader for later.
            try restart(at: time)
        }
        // Once EOF is known, the final decoded frame is valid throughout a static
        // tail. Its PTS can be seconds behind the request; reopening the same
        // reader on each preview/export frame only decodes that same tail again.
        // Backward seeks before the retained window still need a fresh reader.
        if reader == nil || (frames.first.map { time < $0.time } ?? false) || (!exhausted && (frames.last.map { time.seconds - $0.time.seconds > 1 } ?? false)) {
            try restart(at: time)
        }
        while !exhausted && (frames.last.map { $0.time < time } ?? true) {
            guard let sample = output?.copyNextSampleBuffer() else {
                if reader?.status == .failed { throw RenderError.decode(reader?.error?.localizedDescription ?? "Video decode failed") }
                exhausted = true; break
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw RenderError.decode("Video sample has no pixel buffer") }
            decodedFrameCount += 1
            let frame = try TextureFrame(buffer: buffer, cache: cache, time: CMSampleBufferGetPresentationTimeStamp(sample),transform: preferredTransform)
            try onDecode?(frame)
            frames.append(frame)
            if frames.count > capacity { frames.removeFirst() }
        }
        guard let best = frames.min(by: { abs($0.time.seconds - time.seconds) < abs($1.time.seconds - time.seconds) }) else { throw RenderError.decode("No video samples at requested time") }
        return best
    }
}
