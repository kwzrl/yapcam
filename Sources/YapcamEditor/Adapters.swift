import Foundation
import CoreGraphics
import Combine
import YapcamCore
import YapcamRender

/// Lets render read the core project (preview and export share one evaluator).
final class ProjectRenderSource: RenderProjectSource, @unchecked Sendable {
    let project: Project
    private let lock = NSLock()
    private var cachedCursor: CoreRenderOptions?
    private var observer: NSObjectProtocol?
    init(_ project: Project) {
        self.project = project
        // Cursor selections only change with edits, so one cold query serves every frame until the next change.
        observer = NotificationCenter.default.addObserver(forName: Project.didChange, object: project, queue: nil) { [weak self] _ in
            self?.lock.withLock { self?.cachedCursor = nil }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func cursorOptions(atNs ns: Int64) throws -> CoreRenderOptions {
        if let c = lock.withLock({ cachedCursor }) { return c }
        let o = try project.renderOptions(atNs: min(max(ns, 0), max(project.durationNs - 1, 0)))
        lock.withLock { cachedCursor = o }
        return o
    }
    var packageURL: URL { project.packageURL }
    var durationNs: Int64 { project.durationNs }
    func frame(atNs: Int64) throws -> YcFrame { try project.frame(atNs: atNs) }
    func renderSnapshot() throws -> any RenderProjectSource { ProjectRenderSource(try project.snapshot()) }
    func renderBackgroundAsset(index: UInt32) throws -> URL { try project.mediaURL(atIndex: index) }
    // Core-driven effects (highlights, fades, cursor/camera options) and gain automation.
    func renderEffects(atNs: Int64, canvasSize: CGSize) throws -> RenderFrameEffects {
        var fx = try project.renderEffects(atNs: atNs, canvasSize: canvasSize)
        // Render's Project adapter does not apply the cursor palette/shape/size yet (docs/FORMATS.md CUR-06); the editor's
        // source does, so the picker changes preview and export.
        let o = try cursorOptions(atNs: atNs)
        fx.configuration.cursorSetID = o.cursorSetId
        fx.configuration.cursorSize = o.cursorLogicalSize.render
        if let shape = o.cursorShape { fx.configuration.cursorStyle = shape.render }
        return fx
    }
    func renderAudioRanges() throws -> [RenderAudioRange]? { try project.renderAudioRanges() }
    /// Core's `audio.stereo_mic`: without this forward the default (true) hides the toggle's effect in preview and export.
    func renderStereoMicrophone() throws -> Bool { try project.renderStereoMicrophone() }
    /// Music tracks (built-in and files) and click sounds, evaluated by core (`audio_overlays`). Without this
    /// forward the protocol default returns [] and all added audio is silently missing from preview and export.
    func renderAudioOverlays() throws -> [AudioOverlay] { try project.renderAudioOverlays() }
    var renderConfiguration: RenderConfiguration { project.renderConfiguration }
    func renderLayers(atNs: Int64) throws -> [RenderLayer] { try project.renderLayers(atNs: atNs) }
    func renderClips() throws -> [RenderClip] {
        try project.query("{\"q\":\"clips\"}", as: [ClipInfo].self)
            .map { RenderClip(srcStartNs: $0.srcStartNs, srcEndNs: $0.srcEndNs, speed: $0.speed) }
    }
}

private struct CoreZoom: Decodable {
    var id: String, tlStartNs: Int64, tlEndNs: Int64, mode: String
    var target: [Double], scale: Double, easeInNs: Int64, easeOutNs: Int64, enabled: Bool?
}
private struct ClickRow: Decodable { var tlNs: Int64 }

/// `EditingProject` over the Rust-backed `Project`. Reads are cached and refreshed after every mutation.
@MainActor
public final class CoreEditingProject: EditingProject {
    public let project: Project
    public private(set) var clips: [TimelineClip] = []
    public private(set) var zooms: [TimelineZoom] = []
    public private(set) var settings: JSONValue = .null
    private var clickCache: [Int64] = []
    private var clicksStale = true
    /// Click times are timeline-mapped, so they are re-queried lazily after every project change.
    public var clickTimesNs: [Int64] {
        if clicksStale {
            clickCache = ((try? project.query("{\"q\":\"clicks\"}", as: [ClickRow].self)) ?? []).map(\.tlNs)
            keyCache = ((try? project.query("{\"q\":\"key_events\"}", as: [ClickRow].self)) ?? []).map(\.tlNs)
            markerCache = ((try? project.markers()) ?? []).map(\.tlNs).sorted()
            typingCache = ((try? project.typingSuggestions()) ?? []).flatMap { s in
                s.ranges.map { TypingRecord(id: s.id, span: TimeSpan(startNs: $0.tlStartNs, endNs: $0.tlEndNs)) }
            }.sorted { $0.span.startNs < $1.span.startNs }
            clicksStale = false
        }
        return clickCache
    }
    private var keyCache: [Int64] = []
    public var keyTimesNs: [Int64] { _ = clickTimesNs; return keyCache }
    private var markerCache: [Int64] = []
    public var markerTimesNs: [Int64] { _ = clickTimesNs; return markerCache }
    private var typingCache: [TypingRecord] = []
    public var typingRecords: [TypingRecord] {
        _ = clickTimesNs
        return typingCache
    }

    public init(project: Project) {
        self.project = project
        refresh()
    }

    public func frameGeometry(atNs ns: Int64) -> FrameGeometry? {
        guard let f = try? project.frame(atNs: ns) else { return nil }
        return FrameGeometry(canvasWidth: Double(f.canvas_w), canvasHeight: Double(f.canvas_h),
                             dest: CGRect(x: f.screen_dest.x, y: f.screen_dest.y, width: f.screen_dest.w, height: f.screen_dest.h),
                             crop: CGRect(x: f.screen_crop.x, y: f.screen_crop.y, width: f.screen_crop.w, height: f.screen_crop.h))
    }
    public var hasCamera: Bool { project.session.tracks.camera != nil }
    private lazy var mouseData: Bool = project.session.segments.contains { seg in
        guard let rel = seg.files["events"] else { return false }
        let url = project.packageURL.appendingPathComponent("recording").appendingPathComponent(rel)
        return ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }
    public var hasMouseData: Bool { mouseData }
    private lazy var keystrokes: Bool = ((try? project.query("{\"q\":\"key_events\"}", as: [JSONValue].self)) ?? []).isEmpty == false
    public var hasKeystrokes: Bool { keystrokes }
    public var hasMic: Bool { project.session.tracks.mic != nil }
    public var durationNs: Int64 { project.durationNs }
    public var canUndo: Bool { project.canUndo }
    public var canRedo: Bool { project.canRedo }

    private var editCount = 0
    /// One cold-path read per change: the project JSON already contains clips and zooms, so the former
    /// separate `clips`/`zooms` queries (about 14 ms extra at 500 clips/200 zooms) are not needed.
    private func refresh() {
        clicksStale = true
        guard let data = try? project.toJSON(), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            clips = []; zooms = []; settings = .null; return
        }
        settings = JSONValue(foundation: object)
        let rows = ((object["timeline"] as? [String: Any])?["clips"] as? [[String: Any]]) ?? []
        clips = rows.compactMap { r in
            guard let id = r["id"] as? String, let a = (r["src_start_ns"] as? NSNumber)?.int64Value, let b = (r["src_end_ns"] as? NSNumber)?.int64Value else { return nil }
            var c = TimelineClip(id: id, srcStartNs: a, srcEndNs: b, speed: (r["speed"] as? NSNumber)?.doubleValue ?? 1)
            if let st = r["settings"] as? [String: Any] {          // omitted settings mean the defaults
                c.micGain = (st["mic_gain"] as? NSNumber)?.doubleValue ?? 1; c.systemGain = (st["system_gain"] as? NSNumber)?.doubleValue ?? 1
                c.hideCursor = (st["hide_cursor"] as? Bool) ?? false; c.disableSmoothing = (st["disable_smoothing"] as? Bool) ?? false
            }
            return c
        }
        zooms = ((object["zooms"] as? [[String: Any]]) ?? []).compactMap { z in
            guard let id = z["id"] as? String, let a = (z["tl_start_ns"] as? NSNumber)?.int64Value, let b = (z["tl_end_ns"] as? NSNumber)?.int64Value else { return nil }
            let target = (z["target"] as? [NSNumber])?.map(\.doubleValue) ?? [0.5, 0.5]
            return TimelineZoom(id: id, startNs: a, endNs: b, mode: (z["mode"] as? String) == "auto" ? .auto : .manual,
                                scale: (z["scale"] as? NSNumber)?.doubleValue ?? 2, focusX: target.first ?? 0.5, focusY: target.last ?? 0.5,
                                easeInNs: (z["ease_in_ns"] as? NSNumber)?.int64Value ?? 0, easeOutNs: (z["ease_out_ns"] as? NSNumber)?.int64Value ?? 0,
                                enabled: (z["enabled"] as? Bool) ?? true,
                                lens: Self.lens(z))
        }
    }

    private static func lens(_ z: [String: Any]) -> ZoomLensParams? {
        guard (z["style"] as? String) == "lens" else { return nil }
        let l = z["lens"] as? [String: Any] ?? [:]
        func n(_ k: String, _ d: Double) -> Double { (l[k] as? NSNumber)?.doubleValue ?? d }
        return ZoomLensParams(radius: n("radius", 0.35), bevel: n("bevel", 0.2), chromaticAberration: n("chromatic_aberration", 0.5))
    }

    private func map(_ c: EditorCommand) -> EditCommand {
        switch c {
        case .split(let at): return .split(atNs: at)
        case .deleteRange(let a, let b): return .deleteRange(startNs: a, endNs: b)
        case .setSpeed(let id, let s): return .setSpeed(clipID: id, speed: s)
        case .setClipSettings(let id, let patch): return .setClipSettings(clipID: id, patch: patch)
        case .addZoom(let s, let e, let scale, let fx, let fy):
            return .addZoom(ZoomSpec(startNs: s, endNs: e, target: [fx, fy], scale: scale))
        case .updateZoom(let id, let s, let e, let scale, let fx, let fy, let ei, let eo, let en, let mode):
            var patch: [String: JSONValue] = [:]
            if let s { patch["tl_start_ns"] = .number(Double(s)) }
            if let e { patch["tl_end_ns"] = .number(Double(e)) }
            if let scale { patch["scale"] = .number(scale) }
            if fx != nil || fy != nil {
                let cur = zooms.first { $0.id == id }
                patch["target"] = .array([.number(fx ?? cur?.focusX ?? 0.5), .number(fy ?? cur?.focusY ?? 0.5)])
            }
            if let ei { patch["ease_in_ns"] = .number(Double(ei)) }
            if let eo { patch["ease_out_ns"] = .number(Double(eo)) }
            if let en { patch["enabled"] = .bool(en) }
            if let mode { patch["mode"] = .string(mode.rawValue) }
            return .updateZoom(id: id, patch: patch)
        case .insertZoom(let s, let e): return .insertTimelineItem(.zoom, startNs: s, durationNs: e - s)
        case .setZoomLens(let id, let lens):
            var patch: [String: JSONValue] = ["style": .string(lens == nil ? "classic" : "lens")]
            if let l = lens { patch["lens"] = .object(["radius": .number(l.radius), "bevel": .number(l.bevel), "chromatic_aberration": .number(l.chromaticAberration)]) }
            return .updateZoom(id: id, patch: patch)
        case .removeZoom(let id): return .removeZoom(id: id)
        case .set(let path, let v): return .set(path: path, value: v)
        case .autoZooms: return .autoZooms
        case .autoSpeedTyping(let speed): return .autoSpeedTyping(speed: speed)
        case .processSilence(let spans, let speed):
            return .processSilence(ranges: spans.map { SilenceRange(startNs: $0.startNs, endNs: $0.endNs) }, speed: speed)
        case .applyTypingSuggestion(let id, let speed): return .applyTypingSuggestion(id: id, speed: speed)
        case .dismissTypingSuggestion(let id): return .dismissTypingSuggestion(id: id)
        case .restoreTypingSuggestions: return .restoreTypingSuggestions
        case .batch(let cs): return .batch(cs.map(map))
        }
    }

    /// Structural timeline edits go through core's checked envelope (minimum clip/zoom lengths, atomic, history-safe).
    private func isStructural(_ c: EditorCommand) -> Bool {
        switch c {
        case .split, .deleteRange, .addZoom, .insertZoom, .updateZoom, .setZoomLens, .processSilence: true
        case .batch(let cs): cs.contains(where: isStructural)
        default: false
        }
    }
    public func apply(_ command: EditorCommand) throws {
        let mapped = map(command)
        try project.apply(isStructural(command) ? .timelineEdit(mapped) : mapped); refresh()
    }
    public func undo() throws { try project.undo(); refresh() }
    public func redo() throws { try project.redo(); refresh() }
    public func save() throws { try project.save() }
    public func close() { project.close() }
    public var wallpapers: [WallpaperInfo] {
        BackgroundLibrary.presets.map { WallpaperInfo(id: $0.id, title: $0.title, category: $0.category.rawValue) }
    }
    public func applyWallpaper(id: String) async throws {
        guard let preset = BackgroundLibrary.preset(id: id) else { throw RenderError.invalidSettings("Unknown wallpaper") }
        try await BackgroundLibrary.apply(preset, to: project); refresh()
    }
    public func wallpaperThumbnail(id: String) async -> CGImage? {
        guard let preset = BackgroundLibrary.preset(id: id) else { return nil }
        return await Task.detached(priority: .utility) { try? BackgroundLibrary.image(for: preset, width: 192, height: 108) }.value
    }
    public var cameraRecipes: [CameraRecipe] { ((try? project.cameraStyleLibrary()) ?? []).map { CameraRecipe(id: $0.id, name: $0.name) } }
    public func importCameraLUT(_ file: URL) throws { _ = try project.importCameraLUT(from: file); refresh() }
    public func importBackgroundImage(_ file: URL) throws { try project.importBackgroundImage(file); refresh() }
    public func exportPreset(to url: URL) throws { try project.exportPreset(to: url) }
    public func importPreset(from url: URL) throws { try project.importPreset(from: url); refresh() }
    public func importTranscript(_ data: Data) throws { try project.importTranscript(data); refresh() }
    public func importMusic(_ file: URL, startNs: Int64) async throws {
        try await project.importMusic(file, startNs: startNs, endNs: nil, gainDb: -18, loop: true); refresh()
    }

    private struct AudioRangeRow: Decodable {
        var track: String, path: String
        var fileStartNs: Int64, fileEndNs: Int64, tlStartNs: Int64, tlEndNs: Int64
    }

    public func silentSpans() async throws -> [TimeSpan] {
        let rows = try project.query("{\"q\":\"audio_ranges\"}", as: [AudioRangeRow].self)
        let track = rows.contains { $0.track == "mic" } ? "mic" : "system_audio"
        var cache: [String: [SilenceRange]] = [:]
        var out: [TimeSpan] = []
        for row in rows where row.track == track {
            let silent: [SilenceRange]
            if let c = cache[row.path] { silent = c } else {
                silent = try await AudioAnalysis.silence(in: project.packageURL.appendingPathComponent(row.path))
                cache[row.path] = silent
            }
            let fileLen = Double(row.fileEndNs - row.fileStartNs), tlLen = Double(row.tlEndNs - row.tlStartNs)
            guard fileLen > 0 else { continue }
            for r in silent {
                let a = max(r.startNs, row.fileStartNs), b = min(r.endNs, row.fileEndNs)
                guard b > a else { continue }
                let ta = row.tlStartNs + Int64(Double(a - row.fileStartNs) / fileLen * tlLen)
                let tb = row.tlStartNs + Int64(Double(b - row.fileStartNs) / fileLen * tlLen)
                if tb > ta { out.append(TimeSpan(startNs: ta, endNs: tb)) }
            }
        }
        return out.sorted { $0.startNs < $1.startNs }
    }
}

/// `PlaybackEngine` over render's `PreviewPlayer`. Caches the values it publishes because
/// `@Published` notifies before the stored value changes.
@MainActor
final class PreviewPlayerAdapter: PlaybackEngine {
    let player: PreviewPlayer
    private(set) var currentNs: Int64 = 0
    private(set) var isPlaying = false
    var onChange: (@MainActor () -> Void)?
    private var bag = Set<AnyCancellable>()

    init(player: PreviewPlayer) {
        self.player = player
        player.$currentNs.sink { [weak self] v in MainActor.assumeIsolated { self?.currentNs = v; self?.onChange?() } }.store(in: &bag)
        player.$isPlaying.sink { [weak self] v in MainActor.assumeIsolated { self?.isPlaying = v; self?.onChange?() } }.store(in: &bag)
    }
    func play() { player.play() }
    func pause() { player.pause() }
    func seek(toNs: Int64, precise: Bool) { player.seek(toNs: toNs, precise: precise) }
    func invalidate() { player.invalidate() }
    func invalidateVisuals() { do { try player.invalidateVisuals() } catch { player.invalidate() } }
    func setSpeechEnhancement(_ settings: SpeechEnhancement?) throws { try player.setSpeechEnhancement(settings.map(\.render)) }
    func setPreviewOptions(_ o: PreviewOptions) throws {
        var s = player.previewSettings
        s.maximumHeight = o.maxHeight
        s.resolution = PreviewSettings.Resolution(rawValue: o.resolution) ?? .full
        s.playbackRate = o.rate
        try player.setPreviewSettings(s)
        player.setMotionBlurEnabled(o.motionBlur)
    }
}

struct RenderExportEngine: ExportEngine {
    let source: ProjectRenderSource

    static func settings(for request: ExportRequest) -> ExportSettings {
        let (container, codec): (ExportSettings.Format, ExportSettings.Codec) = switch request.format {
        case .mp4h264: (.mp4, .h264); case .mp4hevc: (.mp4, .hevc); case .movh264: (.mov, .h264); case .gif: (.gif, .h264) }
        let compression: ExportSettings.Compression? = request.compression.map {
            switch $0 { case .studio: .studio; case .social: .social; case .web: .web; case .webLow: .webLow } }
        return ExportSettings(format: container, codec: codec, outputHeight: request.height, fps: request.fps,
                              quality: compression == nil ? request.quality : nil,
                              includeAudio: request.includeAudio && request.format.supportsAudio,
                              speechEnhancement: request.speech.map(\.render), compression: compression,
                              gifHighQuality: request.gifHighQuality, gifDisableLoop: request.gifDisableLoop)
    }

    func estimate(for request: ExportRequest) -> ExportEstimateInfo? {
        guard let frame = try? source.frame(atNs: 0),
              let e = try? Self.settings(for: request).estimate(canvasWidth: frame.canvas_w, canvasHeight: frame.canvas_h,
                                                                 durationNs: source.durationNs, hasAudio: request.includeAudio) else { return nil }
        return ExportEstimateInfo(width: e.width, height: e.height, bytes: e.totalBytes, renderSeconds: e.renderSeconds)
    }
    func run(_ request: ExportRequest, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        let settings = Self.settings(for: request)
        return try await AtomicExport.run(to: request.destination) { temp in
            let exporter = try Exporter(project: source, settings: settings, destination: temp)
            return try await exporter.run(progress: progress)
        }
    }
}

extension SpeechEnhancement {
    var render: SpeechEnhancementSettings {
        SpeechEnhancementSettings(highPassHz: highPassHz, noiseThresholdDB: noiseThresholdDB, noiseReductionDB: noiseReductionDB,
                                  compressorThresholdDB: compressorThresholdDB, compressorRatio: compressorRatio, targetLUFS: targetLUFS,
                                  peakCeilingDBFS: peakCeilingDBFS, normalizeLoudness: normalizeLoudness)
    }
}

extension JSONValue {
    /// Fast conversion from `JSONSerialization` output (avoids Codable's cascading type probes on large documents).
    init(foundation any: Any) {
        switch any {
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(foundation: $0) })
        case let d as [String: Any]: self = .object(d.mapValues { JSONValue(foundation: $0) })
        default: self = .null
        }
    }
}

extension CoreRenderOptions.CursorLogicalSize {
    var render: VectorCursorSize {
        switch self { case .small: .small; case .regular: .regular; case .large: .large; case .extraLarge: .extraLarge }
    }
}
extension CoreRenderOptions.CursorShape {
    var render: RenderConfiguration.CursorStyle {
        switch self {
        case .arrow: .arrow; case .pointingHand: .pointer; case .touch: .touch; case .text: .text
        case .resizeHorizontal: .resizeHorizontal; case .resizeVertical: .resizeVertical
        case .resizeDiagonalNWSE: .resizeDiagonalNWSE; case .resizeDiagonalNESW: .resizeDiagonalNESW
        case .openHand: .openHand; case .closedHand: .closedHand
        }
    }
}
