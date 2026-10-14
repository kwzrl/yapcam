import Foundation

public struct ExportSettings: Sendable, Codable, Equatable {
    public enum Format: String, Sendable, Codable { case mp4, mov, gif }
    public enum Codec: String, Sendable, Codable { case h264, hevc }
    public var format: Format
    public var codec: Codec
    public var outputHeight: Int
    public var fps: Int
    public var quality: Double
    public var includeAudio: Bool
    /// Optional explicit bitrate in bits/second; quality supplies the default.
    public var bitrate: Int?
    public var rangeStartNs: Int64?
    public var rangeEndNs: Int64?
    public init(format: Format = .mp4, codec: Codec = .h264, outputHeight: Int = 1080, fps: Int = 30, quality: Double = 0.8, includeAudio: Bool = true, bitrate: Int? = nil, rangeStartNs: Int64? = nil, rangeEndNs: Int64? = nil) {
        self.format = format; self.codec = codec; self.outputHeight = outputHeight; self.fps = fps; self.quality = quality; self.includeAudio = includeAudio
        self.bitrate = bitrate; self.rangeStartNs = rangeStartNs; self.rangeEndNs = rangeEndNs
    }
    public enum Preset: String, CaseIterable, Sendable { case compact720, standard1080, high1440, ultra4K, gif }
    public static func preset(_ preset: Preset) -> Self {
        switch preset {
        case .compact720: return Self(outputHeight: 720, quality: 0.6)
        case .standard1080: return Self()
        case .high1440: return Self(outputHeight: 1440, fps: 60, quality: 0.9)
        case .ultra4K: return Self(codec: .hevc, outputHeight: 2160, fps: 60, quality: 0.9)
        case .gif: return Self(format: .gif, outputHeight: 720, fps: 24, includeAudio: false)
        }
    }
    func validatedRange(duration: Int64) throws -> Range<Int64> {
        guard [720,1080,1440,2160].contains(outputHeight), [24,30,60].contains(fps), quality.isFinite, (0...1).contains(quality), bitrate.map({ (100_000...200_000_000).contains($0) }) ?? true else { throw RenderError.invalidSettings("Export requires 720p–4K, 24/30/60 fps, quality 0…1 and a valid bitrate") }
        let start = rangeStartNs ?? 0, end = rangeEndNs ?? duration
        guard start >= 0, end > start, end <= duration else { throw RenderError.invalidSettings("Export range must lie inside the nonempty timeline") }
        return start..<end
    }
    func outputWidth(canvasWidth: UInt32, canvasHeight: UInt32) throws -> Int {
        guard canvasWidth > 0, canvasHeight > 0 else { throw RenderError.invalidSettings("Empty canvas") }
        let width = Double(canvasWidth) / Double(canvasHeight) * Double(outputHeight)
        guard width.isFinite, width >= 2, width <= 8192 else { throw RenderError.invalidSettings("Output width must be 2…8192 pixels") }
        return max(2, Int((width / 2).rounded()) * 2)
    }
    func videoBitrate(width: Int) -> Int {
        bitrate ?? Int(Double(width * outputHeight * fps) * (0.04 + quality * 0.2) * (codec == .hevc ? 0.65 : 1))
    }
}

public struct ExportMetrics: Sendable {
    public let frames: Int
    public let elapsedSeconds: Double
    public let mediaSeconds: Double
    public var realtimeMultiplier: Double { mediaSeconds / max(elapsedSeconds, 0.000_001) }
}
