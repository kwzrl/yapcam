import Foundation

/// Compression presets of the reference: Studio, Social, Web, Web (low). `quality` is what render's exporter takes (0…1).
/// The web presets are not offered at 4K.
public enum CompressionPreset: String, CaseIterable, Identifiable, Sendable {
    case studio, social, web, webLow = "web-low"
    public var id: String { rawValue }
    public var label: String {
        switch self { case .studio: "Studio"; case .social: "Social"; case .web: "Web"; case .webLow: "Web (low)" }
    }
    public var hint: String {
        switch self { case .studio: "Highest quality, large file"; case .social: "Good quality for sharing"; case .web: "Small file"; case .webLow: "Smallest file" }
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
    /// What render accepts (`ExportSettings.frameRates/heights`). Defaults follow the reference: MP4 60 fps, Social, 720p;
    /// GIF 15 fps, 480p.
    public var options: ExportOptionSet {
        switch self {
        case .mp4h264, .mp4hevc, .movh264:
            ExportOptionSet(fps: [60, 50, 30, 25, 24, 20, 10], heights: [720, 1080] + (self == .movh264 ? [1440] : []) + [2160],
                            defaultFPS: 60, defaultHeight: 720, presets: CompressionPreset.allCases, defaultPreset: .social)
        case .gif:
            ExportOptionSet(fps: [50, 30, 25, 20, 15, 10], heights: [480, 720, 1080], defaultFPS: 15, defaultHeight: 480, presets: [], defaultPreset: nil)
        }
    }
}
