import Foundation

public enum TextEffectKind: String, Sendable { case annotation, reaction, caption }
public struct TextStyle: Codable, Sendable, Equatable {
    public var fontSize: Double
    public var color: [Float]
    public var background: [Float]
    public var radius: Double
    public var opacity: Double
    public init(fontSize: Double = 36, color: [Float] = [1,1,1,1], background: [Float] = [0,0,0,0.65], radius: Double = 12, opacity: Double = 1) {
        self.fontSize = fontSize; self.color = color; self.background = background; self.radius = radius; self.opacity = opacity
    }
}
public struct TextEffectRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var tlStartNs: Int64
    public var tlEndNs: Int64
    public var text: String
    public var rect: [Double]
    public var space: String
    public var style: TextStyle
    public init(id: String = "", startNs: Int64, endNs: Int64, text: String, rect: [Double] = [0.1,0.75,0.8,0.15], space: String = "canvas", style: TextStyle = TextStyle()) {
        self.id = id; tlStartNs = startNs; tlEndNs = endNs; self.text = text; self.rect = rect; self.space = space; self.style = style
    }
}
public struct MusicDucking: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var gainDb: Double
    public var attackNs: Int64
    public var releaseNs: Int64
    public var ranges: [TimelineActivityRange]
    public init(enabled: Bool = false, gainDb: Double = -12, attackNs: Int64 = 50_000_000, releaseNs: Int64 = 200_000_000, ranges: [TimelineActivityRange] = []) {
        self.enabled = enabled; self.gainDb = gainDb; self.attackNs = attackNs; self.releaseNs = releaseNs; self.ranges = ranges
    }
}
public struct TimelineActivityRange: Codable, Sendable, Equatable {
    public var tlStartNs: Int64
    public var tlEndNs: Int64
    public init(startNs: Int64, endNs: Int64) { tlStartNs = startNs; tlEndNs = endNs }
}
public struct MusicTrack: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var tlStartNs: Int64
    public var tlEndNs: Int64
    public var source: String
    public var path: String
    public var fileStartNs: Int64
    public var fileDurationNs: Int64
    public var gainDb: Double
    public var loop: Bool
    public var fadeInNs: Int64
    public var fadeOutNs: Int64
    public var ducking: MusicDucking
    public init(id: String = "", startNs: Int64, endNs: Int64, source: String = "file", path: String = "", fileStartNs: Int64 = 0, fileDurationNs: Int64 = 0, gainDb: Double = -26.020599913279625, loop: Bool = true, fadeInNs: Int64 = 500_000_000, fadeOutNs: Int64 = 500_000_000, ducking: MusicDucking = MusicDucking()) {
        self.id = id; tlStartNs = startNs; tlEndNs = endNs; self.source = source; self.path = path; self.fileStartNs = fileStartNs; self.fileDurationNs = fileDurationNs; self.gainDb = gainDb; self.loop = loop; self.fadeInNs = fadeInNs; self.fadeOutNs = fadeOutNs; self.ducking = ducking
    }
}
public struct CoreAudioOverlay: Decodable, Sendable, Equatable {
    public var id: String
    public var source: String
    public var path: String
    public var tlStartNs: Int64
    public var tlEndNs: Int64
    public var fileStartNs: Int64
    public var fileDurationNs: Int64
    public var loop: Bool
    public var gain: Double
    public var gainStart: Double
    public var gainEnd: Double
    public var fadeInNs: Int64
    public var fadeOutNs: Int64
    public var envelopeStartNs: Int64
    public var envelopeEndNs: Int64
    public var gainAt: Double?
}
public struct CoreEffectsAt: Decodable, Sendable, Equatable {
    public var layers: [CoreRenderLayer]
    public var renderOptions: CoreRenderOptions
    public var audio: [CoreAudioOverlay]
}

/// Keep typed model fields idiomatic Swift while nested command JSON uses the
/// documented snake_case keys. JSONValue preserves all large Int64 timestamps.
struct EffectCommandValue<T: Encodable>: Encodable {
    let value: T
    func encode(to encoder: any Encoder) throws {
        let json = JSONEncoder(); json.keyEncodingStrategy = .convertToSnakeCase
        let data = try json.encode(value)
        try JSONDecoder().decode(JSONValue.self, from: data).encode(to: encoder)
    }
}
extension Project {
    public func textEffects(_ kind: TextEffectKind) throws -> [TextEffectRecord] {
        let query = kind == .annotation ? "annotations" : kind == .reaction ? "reactions" : "captions"
        return try self.query("{\"q\":\"\(query)\"}", as: [TextEffectRecord].self)
    }
    public func musicTracks() throws -> [MusicTrack] { try query("{\"q\":\"music\"}", as: [MusicTrack].self) }
    public func audioOverlays() throws -> [CoreAudioOverlay] { try query("{\"q\":\"audio_overlays\"}", as: [CoreAudioOverlay].self) }
    public func effects(atNs: Int64) throws -> CoreEffectsAt { try query("{\"q\":\"effects_at\",\"tl_ns\":\(atNs)}", as: CoreEffectsAt.self) }
    public func renderOptions(atNs: Int64) throws -> CoreRenderOptions { try query("{\"q\":\"render_options_at\",\"tl_ns\":\(atNs)}", as: CoreRenderOptions.self) }
    /// Pass Capture RecordingTranscript JSON directly; Core does not read files
    /// or request speech permission. Captions are replaced in a single undo step.
    @discardableResult public func importTranscript(_ data: Data, style: TextStyle = TextStyle(), replace: Bool = true) throws -> ChangeSet {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        return try apply(.importTranscript(json, style: style, replace: replace))
    }
}
