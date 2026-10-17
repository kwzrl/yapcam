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

`YapcamCore.abiVersion` and `YC_ABI_VERSION` are now 3 (motion API below). The original YcFrame stays
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
    public enum CursorStyle: String, Decodable, Sendable { case recorded, pointer, touch, arrow }
    public var cursorStyle: CursorStyle
    public var cursorMotionBlur: Double; public var cursorSpotlightRadius: Double
    public var backgroundNoise: Double
    public var backgroundWallpaperId: String?; public var backgroundWallpaperIndex: UInt32?
    public var windowChrome: Bool
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

## Core additive backlog APIs (ABI-v2 structs unchanged)

Models and JSON contracts are in FORMATS.md's additive schema-1 effects section.
New public Core types: TextEffectKind (annotation/reaction/caption), TextStyle,
TextEffectRecord, MusicTrack, MusicDucking, TimelineActivityRange, CoreAudioOverlay,
CoreEffectsAt. Codable model fields use Swift camelCase; EditCommand emits nested
snake_case JSON with exact Int64 ns. Query decoding uses convertFromSnakeCase.
TextEffectRecord(id:"",startNs:endNs:text:rect:space:style:) generates an id on add.
MusicTrack(id:"",startNs:endNs:source:path:fileStartNs:fileDurationNs:gainDb:loop:
fadeInNs:fadeOutNs:ducking:) defaults match FORMATS.md. Built-in source calm/bright
uses an effective 8s duration; file source requires registered package media.

```swift
// New EditCommand cases:
case addText(TextEffectKind, TextEffectRecord)
case updateText(TextEffectKind, id: String, patch: [String: JSONValue])
case removeText(TextEffectKind, id: String)
case addMusic(MusicTrack)
case updateMusic(id: String, patch: [String: JSONValue])
case removeMusic(id: String)
case importTranscript(JSONValue, style: TextStyle, replace: Bool)

// New Project methods:
func textEffects(_ kind: TextEffectKind) throws -> [TextEffectRecord]
func musicTracks() throws -> [MusicTrack]
func audioOverlays() throws -> [CoreAudioOverlay]
func effects(atNs: Int64) throws -> CoreEffectsAt
func renderOptions(atNs: Int64) throws -> CoreRenderOptions
@discardableResult func importTranscript(_ data: Data,
    style: TextStyle = TextStyle(), replace: Bool = true) throws -> ChangeSet
@discardableResult func importMusic(_ file: URL, startNs: Int64 = 0,
    endNs: Int64? = nil, gainDb: Double = -18, loop: Bool = true) async throws -> ChangeSet
```

CoreRenderLayer appends optional text, fontSize, color; all existing properties
stay required. Text creates a `.text(String,fontSize:color:)` Render layer; a
separate preceding highlight supplies its rounded background. CoreEffectsAt has
layers, renderOptions and audio, evaluated from one state at one time. Each audio
row has source/path, timeline/file clocks, loop, gain/start/end, envelope anchors,
fades and optional gainAt. File/calm/bright map to Render's corresponding sources;
soft/crisp map to original click sounds. Interpolate split segment gains in dB;
keep fades anchored to envelopeStartNs/envelopeEndNs across all splits. Renderer
adapters must preserve these endpoints/anchors rather than flatten duck ramps.

Camera options are evaluated per active layout in frameExtras/renderOptions(atNs:)
and effects(atNs:). The parameterless renderOptions() retains root defaults for
existing callers. Scene zoom/slide transforms are already applied to YcFrame
geometry; adapters must not apply a second tween. Capture supplies
RecordingTranscript encoded JSON; Core consumes its word source ranges without a
Speech-module dependency, IO or permissions. importMusic validates a local audio
track, copies it into package assets, registers its fingerprint and adds its model
as one transaction; failed edits remove the staged file. Undo keeps immutable
asset bytes available for redo. These text/audio APIs use the existing JSON boundary; the separate guide-audit
motion extension below adds ABI v3 without changing existing structs.

## Guide-audit Core additions (ABI v3)

The additional set paths and query contracts are in FORMATS.md's guide-audit
section. All existing YcFrame and YcFrameExtras fields/offsets remain unchanged.
New YcFrameMotion is 24 bytes/alignment 8; Project.abiVersion and YC_ABI_VERSION=3.
CoreRenderOptions appends cursorRotationRad, zoomMotionBlur and panMotionBlur.
The timed form supplies evaluated strengths; the parameterless form supplies
configured strengths and zero rotation. The existing extras still expose legacy
cursor options; use motion for tilt and per-kind evaluation.

```swift
func frameMotion(atNs: Int64) throws -> YcFrameMotion  // no core allocation/IO
func motion(atNs: Int64) throws -> CoreFrameMotion    // typed motion_at JSON
func musicLibrary() throws -> [CoreMusicSource]       // original calm/bright sources
// CoreFrameMotion: tlNs:Int64, cursorRotationRad:Double,
// cursorMotionBlur:Double, zoomMotionBlur:Double, panMotionBlur:Double
// CoreMusicSource: id:String, name:String, durationNs:Int64
```

Renderer should apply motion.cursor_rotation_rad once about the cursor hotspot
(positive clockwise), and opt into independent zoom/pan blur. The legacy frame
still supplies max active screen blur for old consumers. CUR-12 forcing pointer,
CUR-14 end hold, CUR-15 shake filtering, CUR-16 type debounce, ANI-02 zoom/pan
presets, and CAM-07 overlay camera resizing are already evaluated by Core.
Snapshots use the same indexes/settings and give deterministic backward seeks.
Each frame/extras/motion call reads independently; export uses an immutable snapshot.

## AUD-06 Core preparation bridge (no Core-to-Render dependency)

```swift
func speechEnhancementPlan() throws -> SpeechEnhancementPlan
func prepareSpeechEnhancement(using processor:
    @Sendable (URL, URL, CoreSpeechEnhancementSettings) async throws -> Void
) async throws -> [PreparedMicrophoneMedia]
```

CoreSpeechEnhancementSettings is Codable/Sendable with highPassHz,
noiseThresholdDb, noiseReductionDb, compressorThresholdDb, compressorRatio,
targetLufs, peakCeilingDbfs, normalizeLoudness; defaults match FORMATS.md/Render.
SpeechEnhancementPlan has enabled, settings, media[{path,mediaIndex}]. Each returned
PreparedMicrophoneMedia has originalPath, processedURL, durationNs, channels,
sampleRate. Core snapshots the plan, validates fingerprints and 48k Float32 output
format/clock, cleans failed/cancelled runs, and leaves project/recordings unchanged.
Successful results live in a unique package cache/speech run directory. Disabled or
no-retained-mic states return []; native codec/processor failures throw explicitly.

For custom media sources, Editor can use this concrete Render invocation and URL substitution:

```swift
let frozen = try project.snapshot() // one export configuration
let prepared = try await frozen.prepareSpeechEnhancement { source, destination, s in
    let settings = YapcamRender.SpeechEnhancementSettings(
        highPassHz: s.highPassHz, noiseThresholdDB: s.noiseThresholdDb,
        noiseReductionDB: s.noiseReductionDb,
        compressorThresholdDB: s.compressorThresholdDb,
        compressorRatio: s.compressorRatio, targetLUFS: s.targetLufs,
        peakCeilingDBFS: s.peakCeilingDbfs,
        normalizeLoudness: s.normalizeLoudness)
    _ = try await SpeechEnhancer.processFile(source, to: destination, settings: settings)
}
let replacements = Dictionary(uniqueKeysWithValues:
    prepared.map { ($0.originalPath, $0.processedURL) })
// Render source resolves mic media by this map, keeping original file_ns,
// track offsets, clips/speeds and gain ramps. Never overwrite recording paths.
```

Render/Editor must wire their media-resolution hook; a persisted toggle alone does
not claim enhanced output. Preview should discard results after configuration
changes; export uses frozen above. No DSP dependency or file decoding enters Rust
frame evaluation. Core tests inject identity/failing PCM processors to validate
coordination; Render tests own DSP/normalization quality and native compressed IO.


CUR-06 adds `CoreRenderOptions.CursorStyle.arrow` and the existing
`.set(path: "cursor.style", value: .string("arrow"))`. `frameExtras(atNs:)`
returns cursor_style 3; `renderOptions()`/`renderOptions(atNs:)` and
`effects(atNs:)` decode `.arrow`. `cursor.always_default` still takes precedence
and returns `.pointer`/code 1. All previous raw values and ABI layouts are stable.
Render owns accepting extras code 3 and selecting its vector arrow texture.


Render's newer native timeline integration also accepts the persisted settings
directly: `ExportSettings(speechEnhancement: settingsOrNil)`,
`PreviewPlayer(project: project, speechEnhancement: settingsOrNil)` and
`player.setSpeechEnhancement(settingsOrNil)`. In Editor, derive the same optional
Render settings from `project.speechEnhancementPlan()` and the field conversion
above; `enabled == false` maps to nil. For an export, derive them from the same
frozen project used by the exporter. This native path prepares microphone files
once and owns their cache lifetime. Use Core's preparation bridge for custom URL
resolution, or the native Render path; never enable native enhancement on URLs
that were already processed by the bridge. Editor must wire the same persisted
configuration into preview and export and cancel/discard stale preview work.


CUR-06 palette/shape/size selection appends optional `cursorSetId: String?`,
`cursorShape: CoreRenderOptions.CursorShape?`, and
`cursorLogicalSize: CoreRenderOptions.CursorLogicalSize` to root/timed options.
CursorShape raw strings are FORMATS.md's ten names; CursorLogicalSize is
small/regular/large/extraLarge (raw extra_large). `Project.cursorLibrary()` returns
CoreCursorLibrary {sets:[{id,name}], shapes:[CursorShape], logicalSizes:[{id,scale}]}.
Set cursor.set_id/shape with .string(id) or .null; set cursor.logical_size with
.string(sizeID). Defaults null/null/regular keep prior behavior.

Render adapter mapping: effective shape overrides the legacy style mapping;
pointing_hand -> RenderConfiguration.CursorStyle.pointer, text -> .text, resize
names -> their camel-case enum values, open_hand/closed_hand -> .openHand/.closedHand.
Map logical size extra_large -> VectorCursorSize.extraLarge, and palette ->
configuration.cursorSetID. Always-default already produces effective shape arrow.
If shape is nil, retain the existing extras style mapping. Do not change frame scale
for logical size; Render's generated artwork owns that multiplier. Native/Core
imports remain acyclic; these are additive JSON options, not ABI struct changes.


Wave 3 adds optional `backgroundWallpaperId` and `backgroundWallpaperIndex` to
root and timed `CoreRenderOptions`. New revision-3 projects publish Render's own
Deep Slate entry as `deep-slate` / index 1; older Core query payloads decode both
as nil. These identify a Render-library selection and are distinct from the
project-media `canvas.background.asset` index. The current Deep Slate entry is an
analytic gradient, so its colors and angle continue to render through `YcFrame`
without a C ABI change.
