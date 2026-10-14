import Foundation
import CoreGraphics
import CYapcamCore

public typealias YcFrame = CYapcamCore.YcFrame

public enum RenderError: LocalizedError {
    case unavailable(String), invalidSettings(String), missingMedia(String), decode(String), metal(String), write(String), verification(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let s), .invalidSettings(let s), .missingMedia(let s), .decode(let s), .metal(let s), .write(let s), .verification(let s): return s
        }
    }
}

/// Shared evaluator input. Implementations must serialize project access and freeze edits for snapshots.
public protocol RenderProjectSource: AnyObject, Sendable {
    var packageURL: URL { get }
    var durationNs: Int64 { get }
    func frame(atNs: Int64) throws -> YcFrame
    func renderSnapshot() throws -> any RenderProjectSource
    func renderClips() throws -> [RenderClip]
    func renderBackgroundAsset(index: UInt32) throws -> URL
    var renderConfiguration: RenderConfiguration { get }
    func renderLayers(atNs: Int64) throws -> [RenderLayer]
    func renderAudioOverlays() throws -> [AudioOverlay]
}

public struct RenderClip: Sendable, Decodable {
    public var srcStartNs: Int64
    public var srcEndNs: Int64
    public var speed: Double
    public init(srcStartNs: Int64, srcEndNs: Int64, speed: Double = 1) {
        self.srcStartNs = srcStartNs; self.srcEndNs = srcEndNs; self.speed = speed
    }
    enum CodingKeys: String, CodingKey { case srcStartNs = "src_start_ns", srcEndNs = "src_end_ns", speed }
}

struct RecordingManifest: Decodable {
    struct Segment: Decodable {
        var index: UInt32
        var dir: String
        var srcStartNs: Int64
        var durationNs: Int64
        var files: [String: String]
        var trackStartNs: [String: Int64]
        enum CodingKeys: String, CodingKey { case index, dir, files, srcStartNs = "src_start_ns", durationNs = "duration_ns", trackStartNs = "track_start_ns" }
    }
    var segments: [Segment]
    static func load(package: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: package.appendingPathComponent("recording/session.json")))
    }
}

/// Reject escaping relative references, including symlinks, before reading project assets.
func mediaURL(_ relative: String, root: URL) throws -> URL {
    let base = root.resolvingSymlinksInPath().standardizedFileURL
    let result = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
    guard !relative.hasPrefix("/"), result.path.hasPrefix(base.path + "/") else { throw RenderError.missingMedia("Media reference escapes its package: \(relative)") }
    guard FileManager.default.fileExists(atPath: result.path) else { throw RenderError.missingMedia(relative) }
    return result
}

public extension RenderProjectSource {
    var renderConfiguration: RenderConfiguration { RenderConfiguration() }
    func renderLayers(atNs: Int64) throws -> [RenderLayer] { [] }
    func renderAudioOverlays() throws -> [AudioOverlay] { [] }
}
