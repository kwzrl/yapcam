import Foundation
import Combine
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
    /// Per-clip settings (amplitudes 0…1, cursor flags); defaults mean "unchanged".
    public var micGain = 1.0, systemGain = 1.0
    public var hideCursor = false, disableSmoothing = false
    public init(id: String, srcStartNs: Int64, srcEndNs: Int64, speed: Double = 1) {
        self.id = id; self.srcStartNs = srcStartNs; self.srcEndNs = srcEndNs; self.speed = speed
    }
    /// Duration on the timeline after speed is applied.
    public var timelineDurationNs: Int64 { Int64(Double(srcEndNs - srcStartNs) / speed) }
}

public struct ZoomLensParams: Equatable, Sendable {
    public static let radiusRange = 0.25...0.75
    public var radius = 0.35, bevel = 0.2, chromaticAberration = 0.5
    public init(radius: Double = 0.35, bevel: Double = 0.2, chromaticAberration: Double = 0.5) {
        self.radius = radius; self.bevel = bevel; self.chromaticAberration = chromaticAberration
    }
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
    /// nil = classic (the whole screen scales); set = glass loupe (a magnifying lens over the screen).
    public var lens: ZoomLensParams?
    public init(id: String, startNs: Int64, endNs: Int64, mode: Mode = .manual,
                scale: Double = 2, focusX: Double = 0.5, focusY: Double = 0.5,
                easeInNs: Int64 = 300_000_000, easeOutNs: Int64 = 300_000_000, enabled: Bool = true, lens: ZoomLensParams? = nil) {
        self.lens = lens
        self.id = id; self.startNs = startNs; self.endNs = endNs; self.mode = mode
        self.scale = scale; self.focusX = focusX; self.focusY = focusY
        self.easeInNs = easeInNs; self.easeOutNs = easeOutNs; self.enabled = enabled
    }
}

public struct WallpaperInfo: Equatable, Identifiable, Sendable {
    public var id: String, title: String, category: String
    public init(id: String, title: String, category: String) { self.id = id; self.title = title; self.category = category }
}

public struct CameraRecipe: Equatable, Identifiable, Sendable {
    public var id: String, name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
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
    case setClipSettings(clipID: String, patch: [String: JSONValue])
    case addZoom(startNs: Int64, endNs: Int64, scale: Double, focusX: Double, focusY: Double)
    case updateZoom(id: String, startNs: Int64?, endNs: Int64?, scale: Double?, focusX: Double?, focusY: Double?,
                    easeInNs: Int64? = nil, easeOutNs: Int64? = nil, enabled: Bool? = nil, mode: TimelineZoom.Mode? = nil)
    /// New zoom with the project's remembered (last edited) style; focus is centered.
    case insertZoom(startNs: Int64, endNs: Int64)
    /// Puts a span of the original recording back on the timeline as a clip at an existing clip boundary (restores cuts/trims).
    case insertSource(startNs: Int64, endNs: Int64, atNs: Int64, speed: Double, micGain: Double, systemGain: Double, hideCursor: Bool, disableSmoothing: Bool)
    /// Grows a clip back over cut-away source at one edge (`sourceNs` = the new source boundary). One undo step; core clamps it.
    case restoreClipEdge(clipID: String, start: Bool, sourceNs: Int64)
    /// Joins the clip with its successor into one (S-EDT-26). `keepRight`: the merged clip keeps the right clip's settings.
    case mergeClips(leftID: String, keepRight: Bool)
    /// New zoom with explicit fields (scale, target, mode, style, lens, enabled, easing): used by split and duplicate so nothing is lost.
    case insertZoomWith(startNs: Int64, endNs: Int64, patch: [String: JSONValue])
    /// A continuous interactive change: edits with the same key less than 100 ms apart share one undo step (core coalesced_edit).
    indirect case coalesced(key: String, command: EditorCommand)
    /// nil = classic style; otherwise the glass loupe with these parameters.
    case setZoomLens(id: String, lens: ZoomLensParams?)
    case removeZoom(id: String)
    case set(path: String, value: JSONValue)
    case autoZooms
    case autoSpeedTyping(speed: Double)
    case processSilence(spans: [TimeSpan], speed: Double?)   // speed nil = cut
    case applyTypingSuggestion(id: String, speed: Double)
    case dismissTypingSuggestion(id: String)
    case restoreTypingSuggestions
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
    /// Timeline times of recorded key presses (edited timeline; empty when no keystrokes were recorded).
    var keyTimesNs: [Int64] { get }
    /// Timeline times of the markers dropped while recording (mapped through cuts, speed and repeated clips).
    var markerTimesNs: [Int64] { get }
    /// Typing bursts on the edited timeline (one record per retained occurrence; occurrences of one burst share an id).
    var typingRecords: [TypingRecord] { get }
    func frameGeometry(atNs: Int64) -> FrameGeometry?
    var hasCamera: Bool { get }
    /// Length of the whole original recording (what trims and cuts can be reset to).
    var sourceDurationNs: Int64 { get }
    /// Pixel size the camera was recorded at (from the recording manifest); nil without a camera.
    var cameraPixelSize: (width: Int, height: Int)? { get }
    /// The recording has cursor movement data (not an external device) / typed keys were recorded.
    var hasMouseData: Bool { get }
    var hasKeystrokes: Bool { get }
    var hasMic: Bool { get }
    func apply(_ command: EditorCommand) throws
    func undo() throws
    func redo() throws
    func save() throws
    /// Final step of closing a document: after this, apply/undo/redo/save throw (core `Project.close()`).
    func close()
    /// Import RecordingTranscript JSON as captions (one undo step).
    func importTranscript(_ data: Data) throws
    /// Copy an audio file into the package and add it as a music track at `startNs` (one undo step).
    func importMusic(_ file: URL, startNs: Int64) async throws
    /// The app's own authored background tracks (render's `MusicLibrary`): 4 categories. Nothing is sampled or downloaded.
    var musicLibrary: [LibraryTrack] { get }
    /// Generates the track and adds it as a looping music item at `startNs` (one undo step).
    func addLibraryMusic(trackID: String, startNs: Int64) async throws
    /// Writes the track as a local WAV (for the preview button).
    func writeLibraryTrack(trackID: String, to url: URL) async throws
    /// Original wallpaper/gradient library (render). Applying is one undo step.
    var wallpapers: [WallpaperInfo] { get }
    func applyWallpaper(id: String) async throws
    func wallpaperThumbnail(id: String) async -> CGImage?
    /// The twelve original camera color recipes of core and a `.cube` import (one undo step; core registers the file).
    var cameraRecipes: [CameraRecipe] { get }
    func importCameraLUT(_ file: URL) throws
    /// Copy an image into the package and use it as the background (one undo step).
    func importBackgroundImage(_ file: URL) throws
    /// Look presets: core's portable setting export/import (one undo step for import).
    func exportPreset(to url: URL) throws
    func importPreset(from url: URL) throws
    /// Silent stretches of the main audio track in timeline time (decodes audio; may take a moment).
    func silentSpans() async throws -> [TimeSpan]
    /// Microphone (else system audio) loudness mapped onto the edited timeline; empty when there is no audio.
    func waveformPoints() async throws -> [WavePoint]
    /// Keys and chords captured on the edited timeline with their hidden state (core `key_overlay_shortcuts`).
    func keyChords() -> [KeyChord]
}

public struct LibraryTrack: Equatable, Identifiable, Sendable {
    public var id: String, name: String, category: String, categoryTitle: String
    public var beatsPerMinute: Int, durationNs: Int64
    public init(id: String, name: String, category: String, categoryTitle: String, beatsPerMinute: Int, durationNs: Int64) {
        self.id = id; self.name = name; self.category = category; self.categoryTitle = categoryTitle; self.beatsPerMinute = beatsPerMinute; self.durationNs = durationNs
    }
}

public struct KeyChord: Equatable, Sendable, Identifiable {
    public var text: String, isShortcut: Bool, hidden: Bool
    public var id: String { text }
    public init(text: String, isShortcut: Bool, hidden: Bool) { self.text = text; self.isShortcut = isShortcut; self.hidden = hidden }
}

@MainActor
public protocol PlaybackEngine: AnyObject {
    var currentNs: Int64 { get }
    var isPlaying: Bool { get }
    func play()
    func pause()
    func seek(toNs: Int64, precise: Bool)
    func invalidate()
    /// Refresh after an appearance-only edit (keeps audio and decoder caches). Engines without it rebuild fully.
    func invalidateVisuals()
    /// nil = off. Preview re-prepares its audio when the settings change.
    func setSpeechEnhancement(_ settings: SpeechEnhancement?) throws
    /// Local preview controls (size cap, resolution, speed, motion blur); engines without them ignore the call.
    func setPreviewOptions(_ options: PreviewOptions) throws
    /// Called by the model whenever `currentNs`/`isPlaying` change.
    var onChange: (@MainActor () -> Void)? { get set }
}

/// Offline microphone clean-up (mirrors render's SpeechEnhancementSettings; project paths audio.speech_enhancement*).
public struct SpeechEnhancement: Equatable, Sendable {
    public var highPassHz = 90.0, noiseThresholdDB = -45.0, noiseReductionDB = 30.0
    public var compressorThresholdDB = -24.0, compressorRatio = 3.0, targetLUFS = -16.0, peakCeilingDBFS = -1.0
    public var normalizeLoudness = true
    public init() {}
}

/// Output container/codec choices the export sheet offers (all supported by render's exporter).
/// MP4 (H.264) and GIF are the primary choices; the rest sit under "Advanced" in the sheet.
public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case mp4h264, gif, mp4hevc, mp4both, movh264, movhevc
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .mp4h264: "MP4 (H.264)"; case .gif: "GIF (no audio)"; case .mp4hevc: "MP4 (HEVC, smaller)"
        case .mp4both: "MP4 (H.264 + HEVC copy)"; case .movh264: "MOV (H.264)"; case .movhevc: "MOV (HEVC)"
        }
    }
    public var fileExtension: String { switch self { case .mp4h264, .mp4hevc, .mp4both: "mp4"; case .movh264, .movhevc: "mov"; case .gif: "gif" } }
    public var supportsAudio: Bool { self != .gif }
    /// The paired H.264 + HEVC export writes two files, so it needs a folder: not available for the clipboard.
    public var fileTargetOnly: Bool { self == .mp4both }
    public var isPrimary: Bool { self == .mp4h264 || self == .gif }
    public static var primary: [ExportFormat] { allCases.filter(\.isPrimary) }
    public static var advanced: [ExportFormat] { allCases.filter { !$0.isPrimary } }
}

/// Where the export goes: a file you choose, or the clipboard (a local file kept in a history, pasted as a file).
public enum ExportTarget: String, CaseIterable, Sendable, Identifiable {
    case file, clipboard
    public var id: String { rawValue }
    public var label: String { self == .file ? "File" : "Clipboard" }
}

public struct ExportRequest: Equatable, Sendable {
    public var height: Int
    public var fps: Int
    public var destination: URL
    public var includeAudio: Bool
    public var speech: SpeechEnhancement?
    public var format: ExportFormat
    public var quality: Double
    /// Reference-style compression preset; when set it wins over `quality` (MP4/MOV only).
    public var compression: CompressionPreset?
    public var gifHighQuality: Bool
    public var gifDisableLoop: Bool
    /// Experimental (Settings): MP4/MOV omit exact duplicate rendered frames. Ignored for GIF.
    public var variableFrameRate: Bool
    public var target: ExportTarget
    /// false = VideoToolbox software encoder (render `hardwareEncodingEnabled`); decoding stays system-managed.
    public var hardwareEncoding: Bool
    public init(height: Int, fps: Int, destination: URL, includeAudio: Bool = true, speech: SpeechEnhancement? = nil,
                format: ExportFormat = .mp4h264, quality: Double = 0.8, compression: CompressionPreset? = nil,
                gifHighQuality: Bool = true, gifDisableLoop: Bool = false, variableFrameRate: Bool = false, target: ExportTarget = .file, hardwareEncoding: Bool = true) {
        self.target = target; self.hardwareEncoding = hardwareEncoding
        self.height = height; self.fps = fps; self.destination = destination; self.includeAudio = includeAudio; self.speech = speech
        self.format = format; self.quality = quality; self.compression = compression
        self.gifHighQuality = gifHighQuality; self.gifDisableLoop = gifDisableLoop
        self.variableFrameRate = variableFrameRate && format != .gif
    }
}

/// Planned output of an export: even pixel size, estimated file size(s) and render time.
public struct ExportEstimateInfo: Equatable, Sendable {
    public var width: Int, height: Int
    public var bytes: Int64
    public var renderSeconds: Double
    public init(width: Int, height: Int, bytes: Int64, renderSeconds: Double) {
        self.width = width; self.height = height; self.bytes = bytes; self.renderSeconds = renderSeconds
    }
}

/// Where an export is in the shared render queue (one export renders at a time; the others wait in order).
public enum ExportQueueStatus: Sendable, Equatable { case waiting, preparing, rendering }

public protocol ExportEngine: Sendable {
    /// Same as `run(_:progress:)`, additionally reporting queue phases (may be called off the main actor).
    func run(_ request: ExportRequest, progress: @Sendable @escaping (Double) -> Void,
             status: @Sendable @escaping (ExportQueueStatus) -> Void) async throws -> URL
    /// Cancel by cancelling the surrounding Task. Throws on failure; returns the verified file.
    func run(_ request: ExportRequest, progress: @Sendable @escaping (Double) -> Void) async throws -> URL
    /// Planning numbers for the sheet's readout; nil when the engine cannot estimate.
    func estimate(for request: ExportRequest) -> ExportEstimateInfo?
    /// Files the clipboard export kept (newest first), and putting one of them on the clipboard again.
    func clipboardHistory() -> [URL]
    func copyToClipboard(_ url: URL) throws
}
public extension ExportEngine {
    func estimate(for request: ExportRequest) -> ExportEstimateInfo? { nil }
    func clipboardHistory() -> [URL] { [] }
    func copyToClipboard(_ url: URL) throws {}
    /// Engines without a queue report nothing.
    func run(_ request: ExportRequest, progress: @Sendable @escaping (Double) -> Void,
             status: @Sendable @escaping (ExportQueueStatus) -> Void) async throws -> URL { try await run(request, progress: progress) }
}

public extension EditingProject {
    var markerTimesNs: [Int64] { [] }
    func waveformPoints() async throws -> [WavePoint] { [] }
    var cameraPixelSize: (width: Int, height: Int)? { nil }
    var sourceDurationNs: Int64 { clips.map(\.srcEndNs).max() ?? 0 }
    func keyChords() -> [KeyChord] { [] }
    var musicLibrary: [LibraryTrack] { [] }
    func addLibraryMusic(trackID: String, startNs: Int64) async throws {}
    func writeLibraryTrack(trackID: String, to url: URL) async throws {}
}

/// One keystroke burst occurrence on the timeline, identified by core's source-stable suggestion id.
public struct TypingRecord: Equatable, Sendable { public var id: String; public var span: TimeSpan }

extension EditorCommand {
    /// Settings paths whose edits only change how frames look (never clip mapping, audio or timing).
    static let visualPrefixes = ["canvas.background", "canvas.padding", "canvas.radius", "canvas.shadow", "canvas.inset",
                                 "canvas.window_chrome", "canvas.screen_quality", "cursor.size", "cursor.set", "camera.style"]
    var isVisualOnly: Bool {
        guard case .set(let path, _) = self else { return false }
        return Self.visualPrefixes.contains { path == $0 || path.hasPrefix($0 + ".") || path.hasPrefix($0 + "_") }
    }
}


@MainActor public final class AgentConnection: ObservableObject {
    public static let shared = AgentConnection()
    public let port: UInt16
    public let token: String
    @Published public var running = false
    @Published public var error: String?
    private init() {
        let defaults = UserDefaults.standard
        port = UInt16(exactly: defaults.integer(forKey: "agent.mcp.port")) .flatMap { $0 == 0 ? nil : $0 } ?? 7777
        if let saved = defaults.string(forKey: "agent.mcp.token"), !saved.isEmpty { token = saved }
        else { token = UUID().uuidString + UUID().uuidString; defaults.set(token, forKey: "agent.mcp.token") }
    }
    public var claudeCommand: String {
        "claude mcp add --transport http yapcam http://127.0.0.1:\(port)/mcp --header \"Authorization: Bearer \(token)\""
    }
    public func stdioCommand(binary: URL, closedProject: URL) -> String {
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "claude mcp add --transport stdio yapcam-closed -- \(quote(binary.path)) --project \(quote(closedProject.path))"
    }
}
