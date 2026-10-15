import Foundation

public struct TimelineConstraints: Decodable, Sendable, Equatable {
    public var clipMinNs: Int64
    public var zoomMinNs: Int64
    public var layoutMinNs: Int64
    public var maskMinNs: Int64
    public var insertDurationNs: Int64
}
public struct CoreHistoryState: Decodable, Sendable, Equatable {
    public var undoSteps: Int
    public var redoSteps: Int
    public var limit: Int
    public var coalesceMs: Int
}
extension Project {
    public func timelineConstraints() throws -> TimelineConstraints {
        try query("{\"q\":\"timeline_constraints\"}", as: TimelineConstraints.self)
    }
    public func historyState() throws -> CoreHistoryState {
        try query("{\"q\":\"history\"}", as: CoreHistoryState.self)
    }
}

public struct CoreInsertionStyles: Decodable, Sendable, Equatable {
    public struct Zoom: Decodable, Sendable, Equatable {
        public var mode: String
        public var scale: Double
        public var easeInNs: Int64
        public var easeOutNs: Int64
    }
    public struct Mask: Decodable, Sendable, Equatable {
        public var radius: Double
        public var opacity: Double
        public var dimOpacity: Double
        public var fill: [Float]
        public var stroke: [Float]
        public var strokeWidth: Double
    }
    public var zoom: Zoom?
    public var mask: Mask?
}
extension Project {
    public func insertionStyles() throws -> CoreInsertionStyles {
        try query("{\"q\":\"insertion_styles\"}", as: CoreInsertionStyles.self)
    }
}

public struct CoreCapabilities: Decodable, Sendable, Equatable {
    public var canCrop: Bool
    public var canRoundCorners: Bool
    public var canInset: Bool
    public var canCursor: Bool
    public var canAutoZoom: Bool
    public var canCamera: Bool
    public var canCameraLayouts: Bool
    public var canExternalAudio: Bool
    public var deviceFrameActive: Bool
    public var externalRecording: Bool
}
extension Project {
    public func capabilities() throws -> CoreCapabilities {
        try query("{\"q\":\"capabilities\"}", as: CoreCapabilities.self)
    }
}
