import Foundation

/// Advisory cost model, not a reservation or an encoded-size guarantee.
public struct ExportEstimate: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let fps: Int
    public let frames: Int
    public let mediaSeconds: Double
    /// In destination order; Both returns H.264 then HEVC, never one combined file.
    public let fileBytes: [Int64]
    public let renderSeconds: Double
    public var totalBytes: Int64 { fileBytes.reduce(0,+) }
}

public extension ExportSettings {
    /// Uses the same effective settings, range, frame count, even dimensions and
    /// bitrate fallback as Exporter. Supply measured output pixel-frames/second
    /// to calibrate time; the default is an explicitly approximate planning rate.
    /// GIF uses a 0.53-bit/pixel/frame size model and 2.5x video rendering cost.
    func estimate(canvasWidth: UInt32, canvasHeight: UInt32, durationNs: Int64,
                  hasAudio: Bool, target: Target = .file,
                  pixelsPerSecond: Double = 250_000_000) throws -> ExportEstimate {
        guard outputHeight > 0, fps > 0, pixelsPerSecond.isFinite, pixelsPerSecond > 0 else {
            throw RenderError.invalidSettings("Export estimate requires positive dimensions, rate and throughput")
        }
        let settings = closestValidPreset(for: target)
        let range = try settings.validatedRange(duration: durationNs)
        let size = try settings.outputSize(canvasWidth: canvasWidth,canvasHeight: canvasHeight)
        let seconds = Double(range.count)/1e9
        let frames = ExportTiming.frameCount(durationNs: Int64(range.count),fps: settings.fps)
        let pixels = Double(size.width)*Double(size.height)
        func bytes(_ count: Double) throws -> Int64 {
            guard count.isFinite, count >= 0, count < Double(Int64.max/2) else {
                throw RenderError.invalidSettings("Estimated export size is too large")
            }
            return Int64(ceil(count))
        }
        let files: [Int64]
        if settings.format == .gif { files = [try bytes(pixels*Double(frames)*0.53/8)] }
        else {
            let codecs: [Codec] = settings.codec == .both ? [.h264,.hevc] : [settings.codec]
            files = try codecs.map { codec in
                var child = settings; child.codec = codec
                let audio = child.includeAudio && hasAudio ? 192_000 : 0
                return try bytes(seconds*(Double(child.videoBitrate(width: size.width,height: size.height))+Double(audio))/8)
            }
        }
        let time = pixels*Double(frames)/pixelsPerSecond*(settings.format == .gif ? 2.5 : Double(files.count))
        guard time.isFinite else { throw RenderError.invalidSettings("Estimated export time is too large") }
        return ExportEstimate(width: size.width,height: size.height,fps: settings.fps,frames: frames,
                              mediaSeconds: seconds,fileBytes: files,renderSeconds: time)
    }
}
