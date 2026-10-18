import Foundation

public struct ExportSettings: Sendable, Codable, Equatable {
    public enum Format: String, Sendable, Codable { case mp4, mov, gif }
    public enum Codec: String, CaseIterable, Sendable, Codable {
        case h264, hevc, both
        public var title: String {
            switch self { case .h264: "H.264"; case .hevc: "HEVC"; case .both: "Both" }
        }
    }
    public enum Target: String, CaseIterable, Sendable, Codable { case file, clipboard }
    public static func codecs(for target: Target) -> [Codec] { target == .file ? [.h264,.hevc,.both] : [.h264,.hevc] }
    public enum Compression: String, CaseIterable, Sendable, Codable {
        case studio, social, web, webLow
        public var title: String {
            switch self { case .studio: "Studio"; case .social: "Social Media"; case .web: "Web"; case .webLow: "Web (Low)" }
        }
        public var preferredQuantizer: Int {
            switch self { case .studio: 14; case .social: 24; case .web: 30; case .webLow: 42 }
        }
        /// Native AVAssetWriter rate-control fallback; no unsupported private QP keys.
        public var bitrateFactor: Double {
            switch self { case .studio: 0.3; case .social: 0.05; case .web: 0.0175; case .webLow: 0.0075 }
        }
        public var supports4K: Bool { self == .studio || self == .social }
    }
    public var format: Format
    public var codec: Codec
    public var outputHeight: Int
    public var fps: Int
    /// Legacy custom quality remains readable for saved callers. New UI uses compression.
    public var quality: Double { didSet { compression = nil } }
    public var compression: Compression?
    public var includeAudio: Bool
    public var bitrate: Int?
    public var rangeStartNs: Int64?
    public var rangeEndNs: Int64?
    public var speechEnhancement: SpeechEnhancementSettings?
    /// Optional local screen-processing preference. Nil inherits the project's
    /// evaluated setting; zero improvement with upscaling off explicitly bypasses it.
    public var screenQuality: ScreenQualitySettings?
    public var gifHighQuality: Bool
    public var gifDisableLoop: Bool
    /// Nil preserves the legacy Forever/Once switch. Values 2...10 request an
    /// explicit finite repeat count in the GIF application extension.
    public var gifLoopCount: Int?
    /// Experimental MP4/MOV mode: omit exact duplicate rendered frames, retaining
    /// their timeline spacing and final endpoint. Evaluation remains on the fps grid.
    public var variableFrameRate: Bool
    /// False explicitly requests a software encoder through Apple's public
    /// encoder specification. Decoder acceleration is controlled separately.
    public var hardwareEncodingEnabled: Bool
    /// False explicitly requests software video decoding for every preview/export
    /// AVAssetReader created by Render. GPU compositing remains unchanged.
    public var hardwareDecodingEnabled: Bool
    /// Bounds retained decode/compositing resources more aggressively. The output
    /// frame grid and encoding settings are intentionally identical.
    public var lowMemory: Bool
    /// Experimental file-export mode: render two frame-aligned ranges concurrently
    /// and join their encoded tracks without another generation of compression.
    public var parallelSegments: Bool

    public init(format: Format = .mp4, codec: Codec = .h264, outputHeight: Int? = nil, fps: Int? = nil,
                quality: Double? = nil, includeAudio: Bool = true, bitrate: Int? = nil,
                rangeStartNs: Int64? = nil, rangeEndNs: Int64? = nil,
                speechEnhancement: SpeechEnhancementSettings? = nil, compression: Compression? = nil,
                gifHighQuality: Bool = true, gifDisableLoop: Bool = false,gifLoopCount: Int? = nil,variableFrameRate: Bool = false,
                screenQuality: ScreenQualitySettings? = nil,hardwareEncodingEnabled: Bool = true,
                hardwareDecodingEnabled: Bool = true,lowMemory: Bool = false,parallelSegments: Bool = false) {
        self.format = format; self.codec = codec
        self.outputHeight = outputHeight ?? (format == .gif ? 480 : 720)
        self.fps = fps ?? (format == .gif ? 15 : 60)
        self.quality = quality ?? 0.8
        self.compression = compression ?? (quality == nil ? .social : nil)
        self.includeAudio = format == .gif ? false : includeAudio
        self.bitrate = bitrate; self.rangeStartNs = rangeStartNs; self.rangeEndNs = rangeEndNs
        self.speechEnhancement = speechEnhancement
        self.screenQuality = screenQuality
        self.gifHighQuality = gifHighQuality; self.gifDisableLoop = gifDisableLoop; self.gifLoopCount=gifLoopCount
        self.variableFrameRate = format == .gif ? false : variableFrameRate
        self.hardwareEncodingEnabled=hardwareEncodingEnabled
        self.hardwareDecodingEnabled=hardwareDecodingEnabled
        self.lowMemory=lowMemory
        self.parallelSegments=parallelSegments
    }
    public static let primaryFormats: [Format] = [.mp4, .gif]
    public static func heightTitle(_ height: Int) -> String { height == 2160 ? "4K" : "\(height)p" }
    /// The effective format/target choices, shared by picker and quick export.
    /// Legacy custom quality is labeled explicitly instead of pretending to be
    /// one of the four compression presets.
    public func summary(for target: Target = .file) -> String {
        let s=closestValidPreset(for: target)
        var parts=[s.format.rawValue.uppercased()]
        if s.format != .gif { parts.append(s.codec.title) }
        parts += [Self.heightTitle(s.outputHeight),"\(s.fps)fps"]
        if s.format == .gif {
            let loop = s.gifDisableLoop ? "Play once" : s.gifLoopCount.map { "Loop \($0)×" } ?? "Loop"
            parts += [s.gifHighQuality ? "High quality" : "Standard quality",loop]
        } else { parts.append(s.compression?.title ?? "Custom") }
        return parts.joined(separator: " • ")
    }
    public static func frameRates(for format: Format) -> [Int] {
        format == .gif ? [50,30,25,20,15,10] : [60,50,30,25,24,20,10]
    }
    public static func heights(for format: Format) -> [Int] {
        switch format { case .mp4: [720,1080,2160]; case .gif: [480,720,1080]; case .mov: [720,1080,1440,2160] }
    }
    public static func normalizedFrameRate(_ value: Int, for format: Format) -> Int {
        let allowed = frameRates(for: format)
        return allowed.first { $0 <= value } ?? allowed.last!
    }
    public func supports(height: Int) -> Bool {
        Self.heights(for: format).contains(height) && (format == .gif || height != 2160 || compression?.supports4K != false)
    }
    /// Map a sheet or older saved preset into this format/target's catalog.
    /// Rates/heights snap down (or up to the catalog minimum); never raises
    /// compression to preserve 4K. Ranges, quality and explicit bitrate survive
    /// unchanged and still undergo validation when an exporter is constructed.
    public func closestValidPreset(for target: Target = .file) -> Self {
        var result = self
        result.fps = Self.normalizedFrameRate(fps,for: format)
        let heights = Self.heights(for: format).filter { result.supports(height: $0) }
        result.outputHeight = heights.last { $0 <= outputHeight } ?? heights[0]
        if format == .gif {
            result.codec = .h264 // GIF has no video codec, audio or microphone processing.
            result.includeAudio = false
            result.speechEnhancement = nil
            result.variableFrameRate = false
        } else if target == .clipboard && codec == .both { result.codec = .h264 }
        return result
    }
    public func destinations(for primary: URL) -> [URL] {
        guard codec == .both else { return [primary] }
        let stem = primary.deletingPathExtension()
        return [primary, stem.deletingLastPathComponent().appendingPathComponent(stem.lastPathComponent+"-h265").appendingPathExtension(format.rawValue)]
    }
    public enum Preset: String, CaseIterable, Sendable { case compact720, standard1080, high1440, ultra4K, gif }
    public static func preset(_ preset: Preset) -> Self {
        switch preset {
        case .compact720: Self()
        case .standard1080: Self(outputHeight: 1080)
        case .high1440: Self(format: .mov, outputHeight: 1440, compression: .studio)
        case .ultra4K: Self(codec: .hevc, outputHeight: 2160, compression: .studio)
        case .gif: Self(format: .gif)
        }
    }
    func validatedRange(duration: Int64) throws -> Range<Int64> {
        try speechEnhancement?.validate()
        try screenQuality?.validate()
        guard supports(height: outputHeight), Self.frameRates(for: format).contains(fps),
              quality.isFinite, (0...1).contains(quality),
              bitrate.map({ (100_000...200_000_000).contains($0) }) ?? true,
              gifLoopCount.map({ (2...10).contains($0) }) ?? true,
              !(gifDisableLoop && gifLoopCount != nil),
              format != .gif || codec != .both else {
            throw RenderError.invalidSettings("Export size, frame rate, compression or codec is unsupported for this format")
        }
        let start = rangeStartNs ?? 0, end = rangeEndNs ?? duration
        guard start >= 0, end > start, end <= duration else { throw RenderError.invalidSettings("Export range must lie inside the nonempty timeline") }
        return start..<end
    }
    /// Even pixel dimensions fit within 3840x2160 without changing the canvas aspect.
    public func outputSize(canvasWidth: UInt32, canvasHeight: UInt32) throws -> (width: Int, height: Int) {
        guard canvasWidth > 0, canvasHeight > 0, outputHeight > 0 else { throw RenderError.invalidSettings("Empty canvas") }
        let height = Double(outputHeight), width = Double(canvasWidth)/Double(canvasHeight)*height
        let scale = min(1, 3840/width, 2160/height)
        return (max(2, Int(floor(width*scale/2))*2), max(2, Int(floor(height*scale/2))*2))
    }
    public func outputWidth(canvasWidth: UInt32, canvasHeight: UInt32) throws -> Int {
        try outputSize(canvasWidth: canvasWidth, canvasHeight: canvasHeight).width
    }
    func videoBitrate(width: Int, height: Int? = nil) -> Int {
        if let bitrate { return bitrate }
        let factor = compression?.bitrateFactor ?? ((0.04 + quality*0.2) * (codec == .hevc ? 0.65 : 1))
        return max(1, Int(Double(width)*Double(height ?? outputHeight)*Double(fps)*factor))
    }
    private enum CodingKeys: String, CodingKey {
        case format, codec, outputHeight, fps, quality, compression, includeAudio, bitrate
        case rangeStartNs, rangeEndNs, speechEnhancement, gifHighQuality, gifDisableLoop, gifLoopCount, variableFrameRate, screenQuality
        case hardwareEncodingEnabled, hardwareDecodingEnabled, lowMemory, parallelSegments
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(format: try c.decodeIfPresent(Format.self, forKey: .format) ?? .mp4,
                  codec: try c.decodeIfPresent(Codec.self, forKey: .codec) ?? .h264,
                  outputHeight: try c.decodeIfPresent(Int.self, forKey: .outputHeight),
                  fps: try c.decodeIfPresent(Int.self, forKey: .fps),
                  quality: try c.decodeIfPresent(Double.self, forKey: .quality),
                  includeAudio: try c.decodeIfPresent(Bool.self, forKey: .includeAudio) ?? true,
                  bitrate: try c.decodeIfPresent(Int.self, forKey: .bitrate),
                  rangeStartNs: try c.decodeIfPresent(Int64.self, forKey: .rangeStartNs),
                  rangeEndNs: try c.decodeIfPresent(Int64.self, forKey: .rangeEndNs),
                  speechEnhancement: try c.decodeIfPresent(SpeechEnhancementSettings.self, forKey: .speechEnhancement),
                  compression: try c.decodeIfPresent(Compression.self, forKey: .compression),
                  gifHighQuality: try c.decodeIfPresent(Bool.self, forKey: .gifHighQuality) ?? true,
                  gifDisableLoop: try c.decodeIfPresent(Bool.self, forKey: .gifDisableLoop) ?? false,
                  gifLoopCount: try c.decodeIfPresent(Int.self,forKey: .gifLoopCount),
                  variableFrameRate: try c.decodeIfPresent(Bool.self,forKey: .variableFrameRate) ?? false,
                  screenQuality: try c.decodeIfPresent(ScreenQualitySettings.self,forKey: .screenQuality),
                  hardwareEncodingEnabled: try c.decodeIfPresent(Bool.self,forKey: .hardwareEncodingEnabled) ?? true,
                  hardwareDecodingEnabled: try c.decodeIfPresent(Bool.self,forKey: .hardwareDecodingEnabled) ?? true,
                  lowMemory: try c.decodeIfPresent(Bool.self,forKey: .lowMemory) ?? false,
                  parallelSegments: try c.decodeIfPresent(Bool.self,forKey: .parallelSegments) ?? false)
    }
}
public struct ExportMetrics: Sendable {
    public let frames: Int
    public let elapsedSeconds: Double
    public let mediaSeconds: Double
    public var realtimeMultiplier: Double { mediaSeconds / max(elapsedSeconds, 0.000_001) }
}
