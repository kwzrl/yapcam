# Swift module contracts

Owned by Lead. Owners implement these surfaces; consumers code against them.
Additions are fine; breaking changes go through Lead. Signatures are the contract,
bodies are the owner's call.

## YapcamCapture (owner: capture)

```swift
public struct DisplaySource: Identifiable, Sendable { id: CGDirectDisplayID; name: String; frame: CGRect /*global points*/; scale: CGFloat; pixelSize: CGSize }
public struct WindowSource: Identifiable, Sendable { id: CGWindowID; title: String; appName: String; bundleID: String?; frame: CGRect; thumbnail: CGImage? }
public struct CaptureDevice: Identifiable, Sendable { id: String /*uniqueID*/; name: String; isDefault: Bool }

public struct CaptureSources: Sendable {
    public var displays: [DisplaySource]; public var windows: [WindowSource]
    public var cameras: [CaptureDevice]; public var microphones: [CaptureDevice]
    public static func load() async throws -> CaptureSources
}

public enum CaptureTarget: Sendable, Codable, Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case area(display: CGDirectDisplayID, rect: CGRect /*display-local points*/)
}

public struct RecordingOptions: Sendable, Codable {
    public var target: CaptureTarget
    public var systemAudio: Bool
    public var microphoneID: String?      // nil = off
    public var cameraID: String?          // nil = off
    public var recordKeystrokes: Bool
    public var maxFPS: Int                // 30 or 60
    public var excludeYapcamWindows: Bool // default true
    public var outputDirectory: URL       // package is created inside
}

public enum Permission: Sendable { case screen, microphone, camera, inputMonitoring, accessibility }
public enum PermissionState: Sendable { case granted, denied, notDetermined }
public enum CapturePermissions {
    public static func state(_ p: Permission) -> PermissionState
    public static func request(_ p: Permission) async -> PermissionState
    public static func openSettings(_ p: Permission)
}

public enum RecordingState: Sendable, Equatable { case idle, preparing, recording, paused, finishing, finished(URL), failed(CaptureError), cancelled }

public enum CaptureError: LocalizedError, Sendable, Equatable {
    case permissionDenied(Permission), sourceUnavailable, deviceLost(String), diskFull(availableBytes: Int64), writerFailed(String)
}

@MainActor public final class RecordingSession: ObservableObject {
    public init(options: RecordingOptions)
    @Published public private(set) var state: RecordingState
    @Published public private(set) var elapsed: TimeInterval   // excludes pauses
    @Published public private(set) var micLevel: Float          // 0…1, for meters
    @Published public private(set) var warnings: [String]       // e.g. camera disconnected, recording continues
    public func start() async throws
    public func pause() async throws
    public func resume() async throws
    public func stop() async throws -> URL                      // the finished .yapcam package
    public func cancel() async                                  // stops and deletes the package
    public var packageURL: URL? { get }
    public static func interruptedPackages(in directory: URL) -> [URL]
    public static func recover(_ package: URL) throws -> URL   // finalizes what was written
}

/// Windows that belong to Yapcam (toolbar, overlays) are excluded via their window numbers.
public enum CaptureExclusions { @MainActor public static func register(_ window: NSWindow); @MainActor public static func unregister(_ window: NSWindow) }
```

## YapcamCore (owner: core)

```swift
public enum EditCommand: Encodable, Sendable {
    case split(atNs: Int64)
    case deleteRange(startNs: Int64, endNs: Int64)
    case setSpeed(clipID: String, speed: Double)
    case addZoom(ZoomSpec)          // returns new id in ChangeSet
    case updateZoom(id: String, patch: [String: JSONValue])
    case removeZoom(id: String)
    case set(path: String, value: JSONValue)
    case batch([EditCommand])
    case autoZooms
    case autoSpeedTyping(speed: Double)
    case processSilence(ranges: [SilenceRange], speed: Double?) // nil cuts; value speeds
    case applyPreset([String: JSONValue])
    case addMedia(path: String, asBackground: Bool)
    case relinkProject(project: JSONValue, paths: [String])    // recovery-only
}
public struct ChangeSet: Decodable, Sendable { public var changed: [String]; public var createdIDs: [String] }

public final class Project: @unchecked Sendable {   // calls serialized internally
    public static func create(package: URL) throws -> Project
    public static func open(package: URL) throws -> Project   // throws CoreError.missingMedia([…]) etc.
    public func save() throws
    @discardableResult public func apply(_ c: EditCommand) throws -> ChangeSet
    public func undo() throws; public func redo() throws
    public var canUndo: Bool { get }; public var canRedo: Bool { get }
    public var durationNs: Int64 { get }
    public func frame(atNs: Int64) throws -> YcFrame            // re-exported C struct
    public func frameExtras(atNs: Int64) throws -> YcFrameExtras // ABI v2, same stateless clock
    public func clicks() throws -> [CursorClick]                // sorted edited timeline ns
    public func query<T: Decodable>(_ q: String, as: T.Type) throws -> T
    public func snapshot() throws -> Project                    // for export
    public let packageURL: URL
    public let session: SessionInfo                             // decoded session.json
    public static let didChange: Notification.Name
}
public enum CoreError: LocalizedError { case status(Int32, String), missingMedia([String]), unsupportedVersion(Int) }
```

`YapcamCore.abiVersion` and `YC_ABI_VERSION` are 2. The original YcFrame stays
328 bytes; the new C-exported YcFrameExtras is 2600 bytes (layout in FORMATS.md).
`frameExtras(atNs:)` serializes calls like `frame(atNs:)`, returning evaluated
render options, up to 32 visible highlight instructions and final fade opacity.
Render draws the valid prefix of extras.highlights then black at fade_opacity.
Call frame/extras on the same immutable snapshot during export. Preview adapters
must serialize edits if they require a matched pair; two calls take separate locks.

Core also exposes cold, typed bridges for existing RenderConfiguration/RenderLayer
hooks; they do not import YapcamRender:

```swift
public struct CursorClick: Decodable, Sendable, Equatable {
    public var tlNs: Int64; public var srcNs: Int64; public var segment: UInt32
    public var t: Int64; public var x: Double?; public var y: Double?; public var button: String?
}
public struct CoreRenderOptions: Decodable, Sendable, Equatable {
    public enum CursorStyle: String, Decodable, Sendable { case recorded, pointer, touch }
    public var cursorStyle: CursorStyle
    public var cursorMotionBlur: Double; public var cursorSpotlightRadius: Double
    public var backgroundNoise: Double; public var windowChrome: Bool
    public var cameraBackgroundRemoval: Bool; public var cameraFaceFraming: Bool
    public var cameraShadowRadius: Double
}
public struct CoreRenderLayer: Decodable, Sendable, Equatable, Identifiable {
    public var id: String; public var kind: String               // highlight
    public var rect: [Double]                                  // canvas x,y,width,height
    public var cornerRadius: Double; public var opacity: Double; public var dimOpacity: Double
    public var fill: [Float]; public var stroke: [Float]        // RGBA, sRGB
    public var strokeWidth: Double
}
extension Project {
    public func renderOptions() throws -> CoreRenderOptions
    public func renderLayers(atNs: Int64) throws -> [CoreRenderLayer]
}
```

`{"q":"clicks"}` is available through query or clicks(); use `.tlNs` for snapping.
Refresh after split/delete/speed/typing/silence edits; removed events disappear.
The full setting path/type/default inventory is in docs/FORMATS.md. Encode generic
nanosecond settings with `JSONValue.integer(Int64)` to preserve precision beyond 2⁵³.

## YapcamRender (owner: render)

```swift
public final class FrameCompositor {                            // Metal; used by preview and export
    public init(device: MTLDevice, project: Project) throws
    public func encode(_ frame: YcFrame, to target: MTLTexture, in cb: MTLCommandBuffer) throws
}

@MainActor public final class PreviewPlayer: ObservableObject {
    public init(project: Project) throws
    @Published public private(set) var currentNs: Int64
    @Published public private(set) var isPlaying: Bool
    public func play(); public func pause(); public func togglePlay()
    public func seek(toNs: Int64, precise: Bool)                // precise=false while scrubbing
    public func invalidate()                                    // project changed → redraw current frame
}
public struct PreviewView: NSViewRepresentable { public init(player: PreviewPlayer) }

public struct ExportSettings: Sendable, Codable, Equatable {
    public enum Format: String, Sendable, Codable { case mp4, mov, gif }
    public enum Codec: String, Sendable, Codable { case h264, hevc }
    public var format: Format; public var codec: Codec
    public var outputHeight: Int        // 720, 1080, 1440, 2160 (width from canvas aspect)
    public var fps: Int                 // 24, 30, 60
    public var quality: Double          // 0…1
    public var includeAudio: Bool
}
public final class Exporter: @unchecked Sendable {
    public init(project: Project, settings: ExportSettings, destination: URL) throws
    public func run(progress: @Sendable @escaping (Double) -> Void) async throws -> URL
    // cancel = cancel the Task; partial file is removed. Success only after the
    // written file is reopened and its duration/tracks verified.
}
```

## YapcamEditor (owner: editor)

```swift
@MainActor public final class EditorDocument: ObservableObject {
    public init(package: URL) throws                            // open or create project, recovery
    public let project: Project; public let player: PreviewPlayer
}
public struct EditorView: View { public init(document: EditorDocument) }
@MainActor public enum EditorWindows { public static func open(package: URL) }   // used by the app after recording
```

## Yapcam app (owner: ui)

Uses everything above. Owns the vertical toolbar, source pickers, area overlay,
countdown, recording HUD, settings, onboarding, menu bar item, recent projects, and
the open/save/export menu commands (delegating to EditorWindows).
