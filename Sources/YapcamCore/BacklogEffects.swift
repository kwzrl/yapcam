import Foundation

public enum TextEffectKind: String, Sendable { case annotation, reaction, caption }
public struct TextStyle: Codable, Sendable, Equatable {
    public enum FontFamily: String, Codable, Sendable, CaseIterable { case sans, serif, mono }
    public enum Reveal: String, Codable, Sendable, CaseIterable { case line, word }
    public enum Growth: String, Codable, Sendable, CaseIterable { case full, expanding, centered }
    public enum Entrance: String, Codable, Sendable, CaseIterable { case appear, fade, slide }
    public var fontFamily: FontFamily
    public var reveal: Reveal
    public var growth: Growth
    public var entrance: Entrance
    public var language: String
    public var fontSize: Double
    public var fontSizeRatio: Double?
    public var color: [Float]
    public var background: [Float]
    public var radius: Double
    public var opacity: Double
    public init(fontSize: Double = 36, color: [Float] = [1,1,1,1], background: [Float] = [0,0,0,0.65], radius: Double = 12, opacity: Double = 1, fontFamily: FontFamily = .sans, reveal: Reveal = .line, growth: Growth = .full, entrance: Entrance = .appear, language: String = "auto", fontSizeRatio: Double? = nil) {
        self.fontSizeRatio = fontSizeRatio
        self.fontSize = fontSize; self.color = color; self.background = background; self.radius = radius; self.opacity = opacity
        self.fontFamily = fontFamily; self.reveal = reveal; self.growth = growth; self.entrance = entrance; self.language = language
    }
    private enum CodingKeys: String, CodingKey { case fontSize, fontSizeRatio, color, background, radius, opacity, fontFamily, reveal, growth, entrance, language }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(fontSize: try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 36,
                  color: try c.decodeIfPresent([Float].self, forKey: .color) ?? [1,1,1,1],
                  background: try c.decodeIfPresent([Float].self, forKey: .background) ?? [0,0,0,0.65],
                  radius: try c.decodeIfPresent(Double.self, forKey: .radius) ?? 12,
                  opacity: try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
                  fontFamily: try c.decodeIfPresent(FontFamily.self, forKey: .fontFamily) ?? .sans,
                  reveal: try c.decodeIfPresent(Reveal.self, forKey: .reveal) ?? .line,
                  growth: try c.decodeIfPresent(Growth.self, forKey: .growth) ?? .full,
                  entrance: try c.decodeIfPresent(Entrance.self, forKey: .entrance) ?? .appear,
                  language: try c.decodeIfPresent(String.self, forKey: .language) ?? "auto",
                  fontSizeRatio: try c.decodeIfPresent(Double.self, forKey: .fontSizeRatio))
    }
}
public struct CaptionWord: Codable, Sendable, Equatable {
    public var text: String
    public var tlStartNs: Int64
    public var tlEndNs: Int64
    public init(text: String, startNs: Int64, endNs: Int64) {
        self.text = text; tlStartNs = startNs; tlEndNs = endNs
    }
}
public struct TextEffectRecord: Codable, Sendable, Equatable, Identifiable {
    public var words: [CaptionWord]
    public var id: String
    public var tlStartNs: Int64
    public var tlEndNs: Int64
    public var text: String
    public var rect: [Double]
    public var space: String
    public var style: TextStyle
    public init(id: String = "", startNs: Int64, endNs: Int64, text: String, rect: [Double] = [0.1,0.75,0.8,0.15], space: String = "canvas", style: TextStyle = TextStyle(), words: [CaptionWord] = []) {
        self.id = id; tlStartNs = startNs; tlEndNs = endNs; self.text = text; self.rect = rect; self.space = space; self.style = style
        self.words = words
    }
    private enum CodingKeys: String, CodingKey { case id, tlStartNs, tlEndNs, text, rect, space, style, words }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), startNs: try c.decode(Int64.self, forKey: .tlStartNs),
                  endNs: try c.decode(Int64.self, forKey: .tlEndNs), text: try c.decode(String.self, forKey: .text),
                  rect: try c.decode([Double].self, forKey: .rect), space: try c.decode(String.self, forKey: .space),
                  style: try c.decode(TextStyle.self, forKey: .style), words: try c.decodeIfPresent([CaptionWord].self, forKey: .words) ?? [])
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
    public var libraryId: String?
    public var ducking: MusicDucking
    public init(id: String = "", startNs: Int64, endNs: Int64, source: String = "file", path: String = "", fileStartNs: Int64 = 0, fileDurationNs: Int64 = 0, gainDb: Double = -26.020599913279625, loop: Bool = true, fadeInNs: Int64 = 500_000_000, fadeOutNs: Int64 = 500_000_000, libraryId: String? = nil, ducking: MusicDucking = MusicDucking()) {
        self.id = id; tlStartNs = startNs; tlEndNs = endNs; self.source = source; self.path = path; self.fileStartNs = fileStartNs; self.fileDurationNs = fileDurationNs; self.gainDb = gainDb; self.loop = loop; self.fadeInNs = fadeInNs; self.fadeOutNs = fadeOutNs; self.libraryId = libraryId; self.ducking = ducking
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
    public var privacyMasks: CorePrivacyMaskFrame?
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
    @discardableResult public func importTranscript(_ data: Data, style: TextStyle? = nil, replace: Bool = true) throws -> ChangeSet {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let selected = try style ?? captionDefaults()
        return try apply(.importTranscript(json, style: selected, replace: replace))
    }
}

extension Project {
    public func captionDefaults() throws -> TextStyle {
        try query("{\"q\":\"caption_defaults\"}", as: TextStyle.self)
    }
}


public struct KeyOverlayShortcut: Decodable, Sendable, Equatable {
    public var text: String
    public var isShortcut: Bool
    public var hidden: Bool
}
extension Project {
    public func keyOverlayShortcuts() throws -> [KeyOverlayShortcut] {
        try query("{\"q\":\"key_overlay_shortcuts\"}", as: [KeyOverlayShortcut].self)
    }
    @discardableResult public func setHiddenShortcuts(_ chords: [String]) throws -> ChangeSet {
        try apply(.set(path: "cursor.key_overlay.hidden_shortcuts", value: .array(chords.map(JSONValue.string))))
    }
}
