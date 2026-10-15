import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), integer(Int64), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = (-9_007_199_254_740_992...9_007_199_254_740_992).contains(v) ? .number(Double(v)) : .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public var numberValue: Double? {
        switch self { case .number(let value): return value; case .integer(let value): return Double(value); default: return nil }
    }
    public var integerValue: Int64? {
        switch self {
        case .integer(let value): return value
        case .number(let value) where value.isFinite && value >= Double(Int64.min) && value < Double(Int64.max) && value.rounded() == value: return Int64(value)
        default: return nil
        }
    }

}

public struct ZoomSpec: Codable, Sendable, Equatable {
    public var tlStartNs: Int64
    public var tlEndNs: Int64
    public var mode: String
    public var target: [Double]
    public var scale: Double
    public var easeInNs: Int64
    public var easeOutNs: Int64
    public init(startNs: Int64, endNs: Int64, target: [Double] = [0.5, 0.5], scale: Double = 2,
                mode: String = "manual", easeInNs: Int64 = 300_000_000, easeOutNs: Int64 = 300_000_000) {
        tlStartNs = startNs; tlEndNs = endNs; self.target = target; self.scale = scale; self.mode = mode
        self.easeInNs = easeInNs; self.easeOutNs = easeOutNs
    }
    enum CodingKeys: String, CodingKey {
        case tlStartNs = "tl_start_ns", tlEndNs = "tl_end_ns", mode, target, scale
        case easeInNs = "ease_in_ns", easeOutNs = "ease_out_ns"
    }
}
public enum TimelineItemKind: String, Sendable { case zoom, layout, mask }
public enum EditCommand: Encodable, Sendable {
    case addText(TextEffectKind, TextEffectRecord)
    case updateText(TextEffectKind, id: String, patch: [String: JSONValue])
    case removeText(TextEffectKind, id: String)
    case addMusic(MusicTrack)
    case updateMusic(id: String, patch: [String: JSONValue])
    case removeMusic(id: String)
    case importTranscript(JSONValue, style: TextStyle, replace: Bool)
    case insertTimelineItem(TimelineItemKind, startNs: Int64 = 0, durationNs: Int64? = nil, patch: [String: JSONValue] = [:])
    indirect case coalescedEdit(key: String, command: EditCommand)
    indirect case timelineEdit(EditCommand)
    case setClipSettings(clipID: String, patch: [String: JSONValue])
    case split(atNs: Int64)
    case deleteRange(startNs: Int64, endNs: Int64)
    case setSpeed(clipID: String, speed: Double)
    case addZoom(ZoomSpec)
    case updateZoom(id: String, patch: [String: JSONValue])
    case removeZoom(id: String)
    case set(path: String, value: JSONValue)
    case batch([EditCommand])
    case autoZooms
    case autoSpeedTyping(speed: Double? = nil)
    case applyTypingSuggestion(id: String, speed: Double? = nil)
    case dismissTypingSuggestion(id: String)
    case restoreTypingSuggestions
    case applyPreset([String: JSONValue])
    case processSilence(ranges: [SilenceRange], speed: Double?)
    case relinkProject(project: JSONValue, paths: [String])
    case addMedia(path: String, asBackground: Bool)
    // Encode integer times as Int64, never via JSONValue.Double.
    enum Key: String, CodingKey {
        case op, at = "at_tl_ns", start = "tl_start_ns", end = "tl_end_ns", clipID = "clip_id"
        case key
        case command, duration = "duration_ns"
        case speed, zoom, id, patch, path, value, commands, preset, ranges, mode, project, paths, role, record, transcript, style, replace
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .addText(let kind, let record):
            try c.encode("add_" + kind.rawValue, forKey: .op); try c.encode(EffectCommandValue(value: record), forKey: .record)
        case .updateText(let kind, let id, let patch):
            try c.encode("update_" + kind.rawValue, forKey: .op); try c.encode(id, forKey: .id); try c.encode(patch, forKey: .patch)
        case .removeText(let kind, let id):
            try c.encode("remove_" + kind.rawValue, forKey: .op); try c.encode(id, forKey: .id)
        case .addMusic(let record):
            try c.encode("add_music", forKey: .op); try c.encode(EffectCommandValue(value: record), forKey: .record)
        case .updateMusic(let id, let patch):
            try c.encode("update_music", forKey: .op); try c.encode(id, forKey: .id); try c.encode(patch, forKey: .patch)
        case .removeMusic(let id):
            try c.encode("remove_music", forKey: .op); try c.encode(id, forKey: .id)
        case .importTranscript(let transcript, let style, let replace):
            try c.encode("import_transcript", forKey: .op); try c.encode(transcript, forKey: .transcript); try c.encode(EffectCommandValue(value: style), forKey: .style); try c.encode(replace, forKey: .replace)
        case .insertTimelineItem(let kind, let start, let duration, let patch):
            try c.encode("insert_" + kind.rawValue, forKey: .op); try c.encode(start, forKey: .start); try c.encodeIfPresent(duration, forKey: .duration); try c.encode(patch, forKey: .patch)
        case .coalescedEdit(let key, let command): try c.encode("coalesced_edit", forKey: .op); try c.encode(key, forKey: .key); try c.encode(command, forKey: .command)
        case .timelineEdit(let command): try c.encode("timeline_edit", forKey: .op); try c.encode(command, forKey: .command)
        case .setClipSettings(let id, let patch): try c.encode("set_clip_settings", forKey: .op); try c.encode(id, forKey: .clipID); try c.encode(patch, forKey: .patch)
        case .split(let at): try c.encode("split", forKey: .op); try c.encode(at, forKey: .at)
        case .deleteRange(let a, let b):
            try c.encode("delete_range", forKey: .op); try c.encode(a, forKey: .start); try c.encode(b, forKey: .end)
        case .setSpeed(let id, let speed):
            try c.encode("set_speed", forKey: .op); try c.encode(id, forKey: .clipID); try c.encode(speed, forKey: .speed)
        case .addZoom(let z): try c.encode("add_zoom", forKey: .op); try c.encode(z, forKey: .zoom)
        case .updateZoom(let id, let patch):
            try c.encode("update_zoom", forKey: .op); try c.encode(id, forKey: .id); try c.encode(patch, forKey: .patch)
        case .removeZoom(let id): try c.encode("remove_zoom", forKey: .op); try c.encode(id, forKey: .id)
        case .set(let path, let value):
            try c.encode("set", forKey: .op); try c.encode(path, forKey: .path); try c.encode(value, forKey: .value)
        case .batch(let commands): try c.encode("batch", forKey: .op); try c.encode(commands, forKey: .commands)
        case .autoZooms: try c.encode("auto_zooms", forKey: .op)
        case .autoSpeedTyping(let speed): try c.encode("auto_speed_typing", forKey: .op); try c.encodeIfPresent(speed, forKey: .speed)
        case .applyTypingSuggestion(let id, let speed):
            try c.encode("apply_typing_suggestion", forKey: .op); try c.encode(id, forKey: .id); try c.encodeIfPresent(speed, forKey: .speed)
        case .dismissTypingSuggestion(let id):
            try c.encode("dismiss_typing_suggestion", forKey: .op); try c.encode(id, forKey: .id)
        case .restoreTypingSuggestions: try c.encode("restore_typing_suggestions", forKey: .op)
        case .addMedia(let path, let asBackground):
            try c.encode("add_media", forKey: .op); try c.encode(path, forKey: .path); try c.encode(asBackground ? "background" : "asset", forKey: .role)
        case .relinkProject(let project, let paths):
            try c.encode("relink_project", forKey: .op); try c.encode(project, forKey: .project); try c.encode(paths, forKey: .paths)
        case .processSilence(let ranges, let speed):
            try c.encode("process_silence", forKey: .op); try c.encode(ranges, forKey: .ranges)
            try c.encode(speed == nil ? "cut" : "speed", forKey: .mode); if let speed { try c.encode(speed, forKey: .speed) }
        case .applyPreset(let preset): try c.encode("apply_preset", forKey: .op); try c.encode(preset, forKey: .preset)
        }
    }
}
public struct ChangeSet: Decodable, Sendable {
    public var changed: [String]
    public var createdIDs: [String]
}
public enum CoreError: LocalizedError, Sendable {
    case status(Int32, String), missingMedia([String]), unsupportedVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .status(_, let message): message
        case .missingMedia(let paths): "Missing or changed media: " + paths.joined(separator: ", ")
        case .unsupportedVersion(let version): "This project uses unsupported schema version \(version)."
        }
    }
}
public struct SessionInfo: Codable, Sendable {
    public var schemaVersion: Int
    public var appVersion: String
    public var createdAt: String
    public var status: String
    public var source: Source
    public var tracks: Tracks
    public var segments: [Segment]
    public struct Source: Codable, Sendable {
        public var kind: String
        public var displayId: UInt32
        public var displayID: UInt32 { displayId }
        public var displayName: String
        public var contentRectPoints: [Double]
        public var scale: Double
        public var windowTitle: String?
        public var appBundleId: String?
        public var appBundleID: String? { appBundleId }
        private enum CodingKeys: String, CodingKey {
            case kind, displayId, displayName, contentRectPoints, scale, windowTitle, appBundleId
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            displayId = try c.decode(UInt32.self, forKey: .displayId)
            contentRectPoints = try c.decode([Double].self, forKey: .contentRectPoints)
            scale = try c.decode(Double.self, forKey: .scale)
            windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle)
            appBundleId = try c.decodeIfPresent(String.self, forKey: .appBundleId)
            let name = try c.decodeIfPresent(String.self, forKey: .displayName)
            if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = name
            } else if kind == "window", let title = windowTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = title
            } else {
                displayName = "Display \(displayId)"
            }
        }
    }
    public struct Tracks: Codable, Sendable {
        public var screen: Screen
        public var camera: Camera?
        public var mic: Audio?
        public var systemAudio: Audio?
    }
    public struct Screen: Codable, Sendable {
        public var pixelSize: [Int]
        public var maxFps: Int
        public var codec: String
        public var cursorInVideo: Bool
    }
    public struct Camera: Codable, Sendable {
        public var deviceName: String
        public var pixelSize: [Int]
        public var fps: Double
        public var mirrored: Bool
    }
    public struct Audio: Codable, Sendable {
        public var deviceName: String?
        public var sampleRate: Int
        public var channels: Int
    }
    public struct Segment: Codable, Sendable {
        public var index: Int
        public var dir: String
        public var srcStartNs: Int64
        public var durationNs: Int64
        public var hostStartNs: Int64
        public var files: [String: String]
        public var trackStartNs: [String: Int64]
    }
}
public struct ClipSettings: Codable, Sendable, Equatable {
    public var micGain: Double
    public var systemGain: Double
    public var externalGain: Double
    public var hideCursor: Bool
    public var disableSmoothing: Bool
    public init(micGain: Double = 1, systemGain: Double = 1, externalGain: Double = 1, hideCursor: Bool = false, disableSmoothing: Bool = false) {
        self.micGain = micGain; self.systemGain = systemGain; self.externalGain = externalGain
        self.hideCursor = hideCursor; self.disableSmoothing = disableSmoothing
    }
}
public struct ClipInfo: Decodable, Sendable, Identifiable {
    public var settings: ClipSettings?
    public var effectiveSettings: ClipSettings { settings ?? ClipSettings() }
    public var id: String
    public var srcStartNs: Int64
    public var srcEndNs: Int64
    public var speed: Double
    public var tlStartNs: Int64
    public var tlEndNs: Int64
}
