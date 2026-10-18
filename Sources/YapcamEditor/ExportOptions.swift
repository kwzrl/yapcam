import Foundation
import YapcamRender

/// Compression presets of the reference: Studio, Social, Web, Web (low). `quality` is what render's exporter takes (0…1).
/// The web presets are not offered at 4K.
public enum CompressionPreset: String, CaseIterable, Identifiable, Sendable {
    case studio, social, web, webLow = "web-low"
    public var id: String { rawValue }
    /// Render's own title ("Studio", "Social Media", "Web", "Web (Low)"), so picker, quick export and summaries read the same.
    public var label: String { renderValue.title }
    var renderValue: ExportSettings.Compression {
        switch self { case .studio: .studio; case .social: .social; case .web: .web; case .webLow: .webLow }
    }
    public var hint: String {
        switch self { case .studio: "Highest quality, large file"; case .social: "Good quality for sharing"; case .web: "Small file"; case .webLow: "Smallest file" }
    }
    /// Two-line description shown under the compression segments.
    public var longHint: String {
        switch self {
        case .studio: "Near-lossless. Best for editing further in another app."
        case .social: "Good for posting. Slight artifacts up close; platforms recompress anyway."
        case .web: "Small file for embedding in a page."
        case .webLow: "Smallest file. Visible artifacts."
        }
    }
    /// Legacy quality value; exports send the preset itself (render maps it to quantiser 14/24/30/42).
    public var quality: Double { switch self { case .studio: 0.95; case .social: 0.8; case .web: 0.55; case .webLow: 0.3 } }
    public func isAvailable(atHeight h: Int) -> Bool { !((self == .web || self == .webLow) && h >= 2160) }
}

/// Valid choices for one output format. This table is the single place that has to match render's validation.
public struct ExportOptionSet: Sendable, Equatable {
    public var fps: [Int]
    public var heights: [Int]
    public var defaultFPS: Int
    public var defaultHeight: Int
    public var presets: [CompressionPreset]          // empty: the format has no compression presets (GIF)
    public var defaultPreset: CompressionPreset?

    public func presets(atHeight h: Int) -> [CompressionPreset] { presets.filter { $0.isAvailable(atHeight: h) } }
}

extension ExportFormat {
    var renderFormat: ExportSettings.Format { switch self { case .gif: .gif; case .movh264, .movhevc: .mov; default: .mp4 } }
    var renderCodec: ExportSettings.Codec { switch self { case .mp4hevc, .movhevc: .hevc; case .mp4both: .both; default: .h264 } }

    /// What render accepts (`ExportSettings.frameRates/heights` of the container). Defaults follow the reference: MP4 60 fps,
    /// Social Media, 720p; GIF 15 fps, 480p. 4K is offered only where render's compression allows it (Studio / Social Media).
    public var options: ExportOptionSet {
        let rates = ExportSettings.frameRates(for: renderFormat), heights = ExportSettings.heights(for: renderFormat)
        if self == .gif {
            return ExportOptionSet(fps: rates, heights: heights, defaultFPS: 15, defaultHeight: 480, presets: [], defaultPreset: nil)
        }
        return ExportOptionSet(fps: rates, heights: heights, defaultFPS: 60, defaultHeight: 720, presets: CompressionPreset.allCases, defaultPreset: .social)
    }
}
