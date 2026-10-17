import Foundation

/// Supplemental options for the renderer's configuration hooks. These do not
/// change YcFrame or introduce a dependency from Core to Render.
public struct CoreRenderOptions: Decodable, Sendable, Equatable {
    public enum CursorStyle: String, Decodable, Sendable { case recorded, pointer, touch, arrow }
    public enum CursorShape: String, Codable, Sendable, CaseIterable, Hashable {
        case arrow, pointingHand = "pointing_hand", touch, text
        case resizeHorizontal = "resize_horizontal", resizeVertical = "resize_vertical"
        case resizeDiagonalNWSE = "resize_diagonal_nwse", resizeDiagonalNESW = "resize_diagonal_nesw"
        case openHand = "open_hand", closedHand = "closed_hand"
        case crosshair, notAllowed = "not_allowed"
    }
    public enum CursorVariant: String, Codable, Sendable, CaseIterable { case standard, alternate }
    public enum CursorLogicalSize: String, Codable, Sendable, CaseIterable, Hashable {
        case small, regular, large, extraLarge = "extra_large"
    }
    public struct ScreenShadow: Decodable, Sendable, Equatable {
        public var style: String
        public var offsetX: Double
        public var offsetY: Double
        public var radius: Double
        public var opacity: Double
    }
    public var screenShadow: ScreenShadow?
    public var paddingRatio: Double?
    public var cursorSizePoints: Double?
    public var cursorUseDefaultIfAppHasLowResolution: Bool?
    public var cursorAlwaysUseDefault: Bool?
    public var cursorSetId: String?
    public var cursorShape: CursorShape?
    public var cursorVariants: [String: CursorVariant]?
    public var cursorLogicalSize: CursorLogicalSize
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
    public var cameraStyle: CameraStyle?
    public var cameraLayout: CoreCameraLayout?
    public var zoomLens: CoreZoomLens?
    public var globalMotionBlur: Double?
    public var screenQuality: CoreScreenQuality?
    public var insetOrigin: [Double]?
}

/// A rounded highlight, mask, or full-canvas fade, evaluated in canvas pixels by
/// Rust. Arrays have fixed lengths: rect [x,y,width,height], fill/stroke RGBA.
/// Rendering applies these in order after the primary frame; fades are last.
public struct CoreRenderLayer: Decodable, Sendable, Equatable, Identifiable {
    public enum Purpose: String, Decodable, Sendable { case unspecified, textBackground = "text_background", privacyMask = "privacy_mask" }
    public var purpose: Purpose?
    public var id: String
    public var kind: String
    public var rect: [Double]
    public var cornerRadius: Double
    public var blurRadius: Double?
    public var opacity: Double
    public var dimOpacity: Double
    public var fill: [Float]
    public var stroke: [Float]
    public var strokeWidth: Double
    public var text: String?
    public var fontSize: Double?
    public var color: [Float]?
    public var fontFamily: TextStyle.FontFamily?
    public var caption: CoreCaptionEvaluation?
}

/// Supplemental mask instructions; indices match frameExtras.highlights on the
/// same immutable project snapshot. Existing C frame layouts remain unchanged.
public struct CoreMaskEffects: Decodable, Sendable, Equatable {
    public struct Effect: Decodable, Sendable, Equatable {
        public var kind: UInt32 // 0 highlight, 1 Gaussian blur
        public var blurRadius: Double
    }
    public var tlNs: Int64
    public var highlightCount: UInt32
    public var effects: [Effect]
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
    public func maskEffects(atNs: Int64) throws -> CoreMaskEffects {
        try query("{\"q\":\"mask_effects_at\",\"tl_ns\":\(atNs)}", as: CoreMaskEffects.self)
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


public struct CoreCursorLibrary: Decodable, Sendable, Equatable {
    public struct Palette: Decodable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
    }
    public struct LogicalSize: Decodable, Sendable, Equatable, Identifiable {
        public var id: CoreRenderOptions.CursorLogicalSize
        public var scale: Double
    }
    public var sets: [Palette]
    public var shapes: [CoreRenderOptions.CursorShape]
    public var logicalSizes: [LogicalSize]
    public var variants: [CoreRenderOptions.CursorVariant]
}
extension Project {
    public func cursorLibrary() throws -> CoreCursorLibrary {
        try query("{\"q\":\"cursor_library\"}", as: CoreCursorLibrary.self)
    }
}


/// Original-space privacy instructions. Consume on the same immutable project
/// snapshot as layers/options; renderer support is required before pre-masking.
public struct CorePrivacyMaskFrame: Decodable, Sendable, Equatable {
    public struct Screen: Decodable, Sendable, Equatable {
        public var present: Bool
        public var segment: UInt32
        public var srcNs: Int64
        public var fileNs: Int64
        public var pixelSize: [UInt32]
        public var canvasSize: [UInt32]
        public var crop: [Double]
        public var dest: [Double]
        public var sourcePixelsPerCanvasPixel: [Double]?
    }
    public struct Mask: Decodable, Sendable, Equatable, Identifiable {
        public enum Space: String, Decodable, Sendable { case source, canvas }
        public enum Kind: String, Decodable, Sendable { case highlight, blur }
        public var id: String
        public var order: Int
        public var purpose: CoreRenderLayer.Purpose
        public var space: Space
        public var kind: Kind
        public var rect: [Double]
        public var tlStartNs: Int64
        public var tlEndNs: Int64
        public var cornerRadius: Double
        public var blurRadius: Double?
        public var opacity: Double
        public var dimOpacity: Double
        public var fill: [Float]
        public var stroke: [Float]
        public var strokeWidth: Double
    }
    public var schemaVersion: UInt32
    public var tlNs: Int64
    public var screen: Screen
    public var masks: [Mask]
    private enum CodingKeys: String, CodingKey { case schemaVersion, tlNs, screen, masks }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(UInt32.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Unsupported privacy-mask schema")
        }
        tlNs = try c.decode(Int64.self, forKey: .tlNs)
        screen = try c.decode(Screen.self, forKey: .screen)
        masks = try c.decode([Mask].self, forKey: .masks)
    }
}
extension Project {
    public func privacyMasks(atNs: Int64) throws -> CorePrivacyMaskFrame {
        try query("{\"q\":\"privacy_masks_at\",\"tl_ns\":\(atNs)}", as: CorePrivacyMaskFrame.self)
    }
}
