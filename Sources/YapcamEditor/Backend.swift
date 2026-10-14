import Foundation

// Editor-side abstraction over `Project` (core), `PreviewPlayer` and `Exporter` (render).
// The real types are adapted behind these protocols once they land on main; until then
// the editor is developed and tested against `FakeProject` / `FakePlayer` / `FakeExporter`.

public struct ClipInfo: Equatable, Identifiable, Sendable {
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

public struct ZoomInfo: Equatable, Identifiable, Sendable {
    public enum Mode: String, Sendable { case auto, manual }
    public var id: String
    public var startNs: Int64
    public var endNs: Int64
    public var mode: Mode
    public var scale: Double
    /// Focus point, normalized 0…1 in source space.
    public var focusX: Double
    public var focusY: Double
    public init(id: String, startNs: Int64, endNs: Int64, mode: Mode = .manual,
                scale: Double = 2, focusX: Double = 0.5, focusY: Double = 0.5) {
        self.id = id; self.startNs = startNs; self.endNs = endNs; self.mode = mode
        self.scale = scale; self.focusX = focusX; self.focusY = focusY
    }
}

public struct CanvasSettings: Equatable, Sendable {
    public var padding: Double = 48
    public var cornerRadius: Double = 12
    public var shadow: Double = 0.4
    public var backgroundColorHex: String = "#1F2937"
    public init() {}
}

/// Edit commands; the encoding follows docs/FORMATS.md.
public enum EditorCommand: Equatable, Sendable {
    case split(atNs: Int64)
    case deleteRange(startNs: Int64, endNs: Int64)
    case setSpeed(clipID: String, speed: Double)
    case addZoom(startNs: Int64, endNs: Int64, scale: Double, focusX: Double, focusY: Double)
    case updateZoom(id: String, startNs: Int64?, endNs: Int64?, scale: Double?, focusX: Double?, focusY: Double?)
    case removeZoom(id: String)
    case setNumber(path: String, value: Double)
    case setString(path: String, value: String)
    case batch([EditorCommand])
}

@MainActor
public protocol EditingProject: AnyObject {
    var durationNs: Int64 { get }
    var canUndo: Bool { get }
    var canRedo: Bool { get }
    var clips: [ClipInfo] { get }
    var zooms: [ZoomInfo] { get }
    var canvas: CanvasSettings { get }
    /// Source-time positions of mouse clicks mapped to timeline time (snap targets).
    var clickTimesNs: [Int64] { get }
    func apply(_ command: EditorCommand) throws
    func undo() throws
    func redo() throws
    func save() throws
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
    public init(height: Int, fps: Int, destination: URL) { self.height = height; self.fps = fps; self.destination = destination }
}

public protocol ExportEngine: Sendable {
    /// Cancel by cancelling the surrounding Task. Throws on failure; returns the verified file.
    func run(_ request: ExportRequest, progress: @Sendable @escaping (Double) -> Void) async throws -> URL
}
