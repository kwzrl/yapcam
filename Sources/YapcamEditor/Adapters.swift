import Foundation
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
    public private(set) var clickTimesNs: [Int64] = []

    public init(project: Project) {
        self.project = project
        refresh()
        clickTimesNs = ((try? project.query("{\"q\":\"clicks\"}", as: [ClickRow].self)) ?? []).map(\.tlNs)
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
    private func refresh() {
        clips = ((try? project.query("{\"q\":\"clips\"}", as: [ClipInfo].self)) ?? [])
            .map { TimelineClip(id: $0.id, srcStartNs: $0.srcStartNs, srcEndNs: $0.srcEndNs, speed: $0.speed) }
        zooms = ((try? project.query("{\"q\":\"zooms\"}", as: [CoreZoom].self)) ?? []).map {
            TimelineZoom(id: $0.id, startNs: $0.tlStartNs, endNs: $0.tlEndNs, mode: $0.mode == "auto" ? .auto : .manual,
                         scale: $0.scale, focusX: $0.target.first ?? 0.5, focusY: $0.target.last ?? 0.5,
                         easeInNs: $0.easeInNs, easeOutNs: $0.easeOutNs, enabled: $0.enabled ?? true)
        }
        settings = (try? project.query("{\"q\":\"project\"}", as: JSONValue.self)) ?? .null
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
}

struct RenderExportEngine: ExportEngine {
    let source: ProjectRenderSource
    func run(_ request: ExportRequest, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        // The save panel already asked the user about replacing an existing file.
        if FileManager.default.fileExists(atPath: request.destination.path) { try FileManager.default.removeItem(at: request.destination) }
        let settings = ExportSettings(format: .mp4, codec: .h264, outputHeight: request.height, fps: request.fps, includeAudio: request.includeAudio)
        let exporter = try Exporter(project: source, settings: settings, destination: request.destination)
        return try await exporter.run(progress: progress)
    }
}
