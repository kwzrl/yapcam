import Foundation
import CoreGraphics
import YapcamCore

// Editor-side abstraction over `Project` (core), `PreviewPlayer` and `Exporter` (render).
// The real types are adapted behind these protocols once they land on main; until then
// the editor is developed and tested against `FakeProject` / `FakePlayer` / `FakeExporter`.

public struct TimelineClip: Equatable, Identifiable, Sendable {
    public var id: String
    public var srcStartNs: Int64
    public var srcEndNs: Int64
    public var speed: Double
    public init(id: String, srcStartNs: Int64, srcEndNs: Int64, speed: Double = 1) {
        self.id = id; self.srcStartNs = srcStartNs; self.srcEndNs = srcEndNs; self.speed = speed
    }
    /// Duration on the timeline after speed is applied.
    public var timelineDurationNs: Int64 { Int64(Double(srcEndNs - srcStartNs) / speed) }
}

public struct TimelineZoom: Equatable, Identifiable, Sendable {
    public enum Mode: String, Sendable { case auto, manual }
    public var id: String
    public var startNs: Int64
    public var endNs: Int64
    public var mode: Mode
    public var scale: Double
    /// Focus point, normalized 0…1 in source space.
    public var focusX: Double
    public var focusY: Double
    public var easeInNs: Int64
    public var easeOutNs: Int64
    public var enabled: Bool
    public init(id: String, startNs: Int64, endNs: Int64, mode: Mode = .manual,
                scale: Double = 2, focusX: Double = 0.5, focusY: Double = 0.5,
                easeInNs: Int64 = 300_000_000, easeOutNs: Int64 = 300_000_000, enabled: Bool = true) {
        self.id = id; self.startNs = startNs; self.endNs = endNs; self.mode = mode
        self.scale = scale; self.focusX = focusX; self.focusY = focusY
        self.easeInNs = easeInNs; self.easeOutNs = easeOutNs; self.enabled = enabled
    }
}

public struct TimeSpan: Equatable, Sendable { public var startNs: Int64; public var endNs: Int64
    public init(startNs: Int64, endNs: Int64) { self.startNs = startNs; self.endNs = endNs }
    public var durationNs: Int64 { endNs - startNs }
}

/// Edit commands; the encoding follows docs/FORMATS.md.
public enum EditorCommand: Equatable, Sendable {
    case split(atNs: Int64)
    case deleteRange(startNs: Int64, endNs: Int64)
    case setSpeed(clipID: String, speed: Double)
    case addZoom(startNs: Int64, endNs: Int64, scale: Double, focusX: Double, focusY: Double)
    case updateZoom(id: String, startNs: Int64?, endNs: Int64?, scale: Double?, focusX: Double?, focusY: Double?,
                    easeInNs: Int64? = nil, easeOutNs: Int64? = nil, enabled: Bool? = nil, mode: TimelineZoom.Mode? = nil)
    case removeZoom(id: String)
    case set(path: String, value: JSONValue)
    case autoZooms
    case autoSpeedTyping(speed: Double)
    case processSilence(spans: [TimeSpan], speed: Double?)   // speed nil = cut
    case batch([EditorCommand])
}

/// Where the screen is drawn in the canvas for one frame (canvas pixels) and which part of it is shown (normalized).
public struct FrameGeometry: Equatable, Sendable {
    public var canvasWidth: Double, canvasHeight: Double
    public var dest: CGRect          // canvas px
    public var crop: CGRect          // normalized source rect currently visible
    public init(canvasWidth: Double, canvasHeight: Double, dest: CGRect, crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) {
        self.canvasWidth = canvasWidth; self.canvasHeight = canvasHeight; self.dest = dest; self.crop = crop
    }
    public var aspect: Double { canvasHeight > 0 ? canvasWidth / canvasHeight : 16.0 / 9 }

    /// Unclamped linear map from preview fractions to normalized source coordinates (may fall outside 0…1).
    public func sourceCoords(fromPreview p: CGPoint) -> CGPoint {
        CGPoint(x: crop.minX + (p.x * canvasWidth - dest.minX) / max(dest.width, 1) * crop.width,
                y: crop.minY + (p.y * canvasHeight - dest.minY) / max(dest.height, 1) * crop.height)
    }
    /// Preview-fraction drag deltas → normalized deltas in the given highlight space.
    public func normalizedDelta(dx: Double, dy: Double, space: String) -> CGSize {
        if space == "canvas" { return CGSize(width: dx, height: dy) }
        return CGSize(width: dx * canvasWidth / max(dest.width, 1) * crop.width, height: dy * canvasHeight / max(dest.height, 1) * crop.height)
    }
    /// Normalized rect in `space` → rect in preview fractions.
    public func previewRect(fromNormalized r: [Double], space: String) -> CGRect {
        if space == "canvas" { return CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }
        let a = previewPoint(fromSource: CGPoint(x: r[0], y: r[1])), b = previewPoint(fromSource: CGPoint(x: r[0] + r[2], y: r[1] + r[3]))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// Inverse: normalized source coordinates → preview fractions.
    public func previewPoint(fromSource s: CGPoint) -> CGPoint {
        CGPoint(x: (dest.minX + (s.x - crop.minX) / max(crop.width, 1e-6) * dest.width) / canvasWidth,
                y: (dest.minY + (s.y - crop.minY) / max(crop.height, 1e-6) * dest.height) / canvasHeight)
    }

    /// Maps a point given in 0…1 of the whole preview to a normalized source position (nil outside the screen).
    public func sourcePoint(fromPreview p: CGPoint) -> CGPoint? {
        let cx = p.x * canvasWidth, cy = p.y * canvasHeight
        guard dest.width > 0, dest.height > 0, dest.contains(CGPoint(x: cx, y: cy)) else { return nil }
        return CGPoint(x: crop.minX + (cx - dest.minX) / dest.width * crop.width,
                       y: crop.minY + (cy - dest.minY) / dest.height * crop.height)
    }
}

@MainActor
public protocol EditingProject: AnyObject {
    var durationNs: Int64 { get }
    var canUndo: Bool { get }
    var canRedo: Bool { get }
    var clips: [TimelineClip] { get }
    var zooms: [TimelineZoom] { get }
    /// Full project document (settings live under canvas/cursor/camera/audio/zoom_settings/…).
    var settings: JSONValue { get }
    /// Source-time positions of mouse clicks mapped to timeline time (snap targets).
    var clickTimesNs: [Int64] { get }
    func frameGeometry(atNs: Int64) -> FrameGeometry?
    var hasCamera: Bool { get }
    var hasMic: Bool { get }
    func apply(_ command: EditorCommand) throws
    func undo() throws
    func redo() throws
    func save() throws
    /// Silent stretches of the main audio track in timeline time (decodes audio; may take a moment).
    func silentSpans() async throws -> [TimeSpan]
}

@MainActor
public protocol PlaybackEngine: AnyObject {
    var currentNs: Int64 { get }
    var isPlaying: Bool { get }
    func play()
    func pause()
    func seek(toNs: Int64, precise: Bool)
    func invalidate()
    /// Called by the model whenever `currentNs`/`isPlaying` change.
    var onChange: (@MainActor () -> Void)? { get set }
}

public struct ExportRequest: Equatable, Sendable {
    public var height: Int
    public var fps: Int
    public var destination: URL
    public var includeAudio: Bool
    public init(height: Int, fps: Int, destination: URL, includeAudio: Bool = true) {
        self.height = height; self.fps = fps; self.destination = destination; self.includeAudio = includeAudio
    }
}

public protocol ExportEngine: Sendable {
    /// Cancel by cancelling the surrounding Task. Throws on failure; returns the verified file.
    func run(_ request: ExportRequest, progress: @Sendable @escaping (Double) -> Void) async throws -> URL
}
