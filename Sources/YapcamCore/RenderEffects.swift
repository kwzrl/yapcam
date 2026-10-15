import Foundation

/// Supplemental options for the renderer's configuration hooks. These do not
/// change YcFrame or introduce a dependency from Core to Render.
public struct CoreRenderOptions: Decodable, Sendable, Equatable {
    public enum CursorStyle: String, Decodable, Sendable { case recorded, pointer, touch, arrow }
    public var cursorStyle: CursorStyle
    public var cursorRotationRad: Double
    public var zoomMotionBlur: Double
    public var panMotionBlur: Double
    public var cursorMotionBlur: Double
    public var cursorSpotlightRadius: Double
    public var backgroundNoise: Double
    public var windowChrome: Bool
    public var cameraBackgroundRemoval: Bool
    public var cameraFaceFraming: Bool
    public var cameraShadowRadius: Double
}

/// A rounded highlight, mask, or full-canvas fade, evaluated in canvas pixels by
/// Rust. Arrays have fixed lengths: rect [x,y,width,height], fill/stroke RGBA.
/// Rendering applies these in order after the primary frame; fades are last.
public struct CoreRenderLayer: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: String
    public var rect: [Double]
    public var cornerRadius: Double
    public var opacity: Double
    public var dimOpacity: Double
    public var fill: [Float]
    public var stroke: [Float]
    public var strokeWidth: Double
    public var text: String?
    public var fontSize: Double?
    public var color: [Float]?
}

/// Mouse-down events, sorted on the edited timeline. Removed events are omitted.
public struct CursorClick: Decodable, Sendable, Equatable {
    public var tlNs: Int64
    public var srcNs: Int64
    public var segment: UInt32
    public var t: Int64
    public var x: Double?
    public var y: Double?
    public var button: String?
}

extension Project {
    public func clicks() throws -> [CursorClick] {
        try query("{\"q\":\"clicks\"}", as: [CursorClick].self)
    }
    public func renderOptions() throws -> CoreRenderOptions {
        try query("{\"q\":\"render_options\"}", as: CoreRenderOptions.self)
    }
    public func renderLayers(atNs: Int64) throws -> [CoreRenderLayer] {
        try query("{\"q\":\"layers_at\",\"tl_ns\":\(atNs)}", as: [CoreRenderLayer].self)
    }
}

/// Evaluated ABI-v3 motion outputs. Binary structs retain Float; cold queries
/// decode to Double for editor controls. Positive rotation is clockwise.
public struct CoreFrameMotion: Decodable, Sendable, Equatable {
    public var tlNs: Int64
    public var cursorRotationRad: Double
    public var cursorMotionBlur: Double
    public var zoomMotionBlur: Double
    public var panMotionBlur: Double
}
public struct CoreMusicSource: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var durationNs: Int64
}
extension Project {
    public func motion(atNs: Int64) throws -> CoreFrameMotion {
        try query("{\"q\":\"motion_at\",\"tl_ns\":\(atNs)}", as: CoreFrameMotion.self)
    }
    public func musicLibrary() throws -> [CoreMusicSource] {
        try query("{\"q\":\"music_library\"}", as: [CoreMusicSource].self)
    }
}
