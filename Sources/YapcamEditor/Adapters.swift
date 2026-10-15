import Foundation
import CoreGraphics
import Combine
import YapcamCore
import YapcamRender

/// Lets render read the core project (preview and export share one evaluator).
final class ProjectRenderSource: RenderProjectSource, @unchecked Sendable {
    let project: Project
    init(_ project: Project) { self.project = project }
    var packageURL: URL { project.packageURL }
    var durationNs: Int64 { project.durationNs }
    func frame(atNs: Int64) throws -> YcFrame { try project.frame(atNs: atNs) }
    func renderSnapshot() throws -> any RenderProjectSource { ProjectRenderSource(try project.snapshot()) }
    func renderBackgroundAsset(index: UInt32) throws -> URL { try project.mediaURL(atIndex: index) }
    // Core-driven effects (highlights, fades, cursor/camera options) and gain automation.
    func renderEffects(atNs: Int64, canvasSize: CGSize) throws -> RenderFrameEffects { try project.renderEffects(atNs: atNs, canvasSize: canvasSize) }
    func renderAudioRanges() throws -> [RenderAudioRange]? { try project.renderAudioRanges() }
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
            clicksStale = false
        }
        return clickCache
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
            return TimelineClip(id: id, srcStartNs: a, srcEndNs: b, speed: (r["speed"] as? NSNumber)?.doubleValue ?? 1)
        }
        zooms = ((object["zooms"] as? [[String: Any]]) ?? []).compactMap { z in
            guard let id = z["id"] as? String, let a = (z["tl_start_ns"] as? NSNumber)?.int64Value, let b = (z["tl_end_ns"] as? NSNumber)?.int64Value else { return nil }
            let target = (z["target"] as? [NSNumber])?.map(\.doubleValue) ?? [0.5, 0.5]
            return TimelineZoom(id: id, startNs: a, endNs: b, mode: (z["mode"] as? String) == "auto" ? .auto : .manual,
                                scale: (z["scale"] as? NSNumber)?.doubleValue ?? 2, focusX: target.first ?? 0.5, focusY: target.last ?? 0.5,
                                easeInNs: (z["ease_in_ns"] as? NSNumber)?.int64Value ?? 0, easeOutNs: (z["ease_out_ns"] as? NSNumber)?.int64Value ?? 0,
                                enabled: (z["enabled"] as? Bool) ?? true)
        }
    }

    private func map(_ c: EditorCommand) -> EditCommand {
        switch c {
        case .split(let at): return .split(atNs: at)
        case .deleteRange(let a, let b): return .deleteRange(startNs: a, endNs: b)
        case .setSpeed(let id, let s): return .setSpeed(clipID: id, speed: s)
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
        case .removeZoom(let id): return .removeZoom(id: id)
        case .set(let path, let v): return .set(path: path, value: v)
        case .autoZooms: return .autoZooms
        case .autoSpeedTyping(let speed): return .autoSpeedTyping(speed: speed)
        case .processSilence(let spans, let speed):
            return .processSilence(ranges: spans.map { SilenceRange(startNs: $0.startNs, endNs: $0.endNs) }, speed: speed)
        case .batch(let cs): return .batch(cs.map(map))
        }
    }

    public func apply(_ command: EditorCommand) throws { try project.apply(map(command)); refresh() }
    public func undo() throws { try project.undo(); refresh() }
    public func redo() throws { try project.redo(); refresh() }
    public func save() throws { try project.save() }
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
    func setSpeechEnhancement(_ settings: SpeechEnhancement?) throws { try player.setSpeechEnhancement(settings.map(\.render)) }
}

struct RenderExportEngine: ExportEngine {
    let source: ProjectRenderSource
    func run(_ request: ExportRequest, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        let settings = ExportSettings(format: .mp4, codec: .h264, outputHeight: request.height, fps: request.fps, includeAudio: request.includeAudio,
                                      speechEnhancement: request.speech.map(\.render))
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
