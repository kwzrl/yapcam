import Foundation
import YapcamCore
import CoreGraphics

/// In-memory project used for development and tests until the Rust-backed `Project` lands.
/// Mirrors core semantics: split creates clips, deleteRange ripples, each command = one undo step.
@MainActor
public final class FakeProject: EditingProject {
    public private(set) var clips: [TimelineClip]
    public private(set) var zooms: [TimelineZoom] = []
    public private(set) var settings: JSONValue = .object([
        "canvas": .object(["padding": .number(48), "radius": .number(18), "background": .object(["kind": .string("solid"), "color": .array([.number(0.12), .number(0.14), .number(0.18), .number(1)])]), "shadow": .object(["opacity": .number(0.3), "radius": .number(24)])]),
        "cursor": .object(["visible": .bool(true), "size": .number(1), "smoothing": .number(0.15), "hide_when_idle": .bool(false), "click_effect": .string("ring")]),
        "audio": .object(["mic_gain_db": .number(0), "system_gain_db": .number(0), "mic_muted": .bool(false), "system_muted": .bool(false)]),
        "zoom_settings": .object(["automatic": .bool(true), "follow_cursor": .bool(true)]),
    ])
    public private(set) var autoZoomRuns = 0
    public private(set) var typingRuns = 0
    public private(set) var processSilenceCalls: [(spans: [TimeSpan], speed: Double?)] = []
    public var silences: [TimeSpan] = []
    public var silenceDelay: Duration = .zero
    public var clickTimesNs: [Int64] = []
    public var keyTimesNs: [Int64] = []
    public var markerTimesNs: [Int64] = []
    public private(set) var dismissedTypingIDs = Set<String>()
    public private(set) var typingCommands: [String] = []
    public var typingRecords: [TypingRecord] {
        TypingBursts.detect(keyTimesNs).map { TypingRecord(id: "k\($0.startNs)", span: $0) }.filter { !dismissedTypingIDs.contains($0.id) }
    }
    public var hasCamera = true
    public func frameGeometry(atNs: Int64) -> FrameGeometry? {
        FrameGeometry(canvasWidth: 1920, canvasHeight: 1080, dest: CGRect(x: 96, y: 54, width: 1728, height: 972))
    }
    public var hasMic = true
    public var hasMouseData = true
    public var hasKeystrokes = true
    public private(set) var saveCount = 0
    public var failSave = false
    private var nextID = 1
    private struct Snapshot { var clips: [TimelineClip]; var zooms: [TimelineZoom]; var settings: JSONValue }
    private var undoStack: [Snapshot] = [], redoStack: [Snapshot] = []

    public init(durationNs: Int64 = 10_000_000_000) {
        clips = [TimelineClip(id: "c0", srcStartNs: 0, srcEndNs: durationNs)]
    }

    public var durationNs: Int64 { clips.reduce(0) { $0 + $1.timelineDurationNs } }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func apply(_ command: EditorCommand) throws {
        if closed { throw NSError(domain: "Fake", code: 9, userInfo: [NSLocalizedDescriptionKey: "Project is closed"]) }
        let snap = Snapshot(clips: clips, zooms: zooms, settings: settings)
        try run(command)
        undoStack.append(snap); redoStack.removeAll()
    }

    private func newID(_ p: String) -> String { defer { nextID += 1 }; return "\(p)\(nextID)" }

    private func run(_ c: EditorCommand) throws {
        switch c {
        case .batch(let cs): for x in cs { try run(x) }
        case .split(let at):
            var t: Int64 = 0
            for (i, clip) in clips.enumerated() {
                let d = clip.timelineDurationNs
                if at > t && at < t + d {
                    let srcAt = clip.srcStartNs + Int64(Double(at - t) * clip.speed)
                    var a = clip; a.srcEndNs = srcAt
                    var b = clip; b.id = newID("c"); b.srcStartNs = srcAt
                    clips.replaceSubrange(i...i, with: [a, b]); return
                }
                t += d
            }
            throw NSError(domain: "Fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "split out of range"])
        case .deleteRange(let s, let e):
            // Like core: clips are trimmed by source time (speed-aware), later content ripples left.
            var t: Int64 = 0
            var out: [TimelineClip] = []
            for clip in clips {
                let d = clip.timelineDurationNs
                defer { t += d }
                guard e > t && s < t + d else { out.append(clip); continue }
                if s > t { var left = clip; left.srcEndNs = clip.srcStartNs + Int64(Double(s - t) * clip.speed); out.append(left) }
                if e < t + d { var right = clip; right.srcStartNs = clip.srcStartNs + Int64(Double(e - t) * clip.speed); if s > t { right.id = newID("c") }; out.append(right) }
            }
            clips = out
            let removed = e - s
            zooms = zooms.compactMap { z in
                var z = z
                func map(_ x: Int64) -> Int64 { x < s ? x : x >= e ? x - removed : s }
                z.startNs = map(z.startNs); z.endNs = map(z.endNs)
                return z.endNs > z.startNs ? z : nil
            }
        case .setClipSettings(let id, let patch):
            guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
            for (k, v) in patch {
                switch (k, v) {
                case ("mic_gain", .number(let x)): clips[i].micGain = x
                case ("system_gain", .number(let x)): clips[i].systemGain = x
                case ("hide_cursor", .bool(let x)): clips[i].hideCursor = x
                case ("disable_smoothing", .bool(let x)): clips[i].disableSmoothing = x
                default: throw NSError(domain: "Fake", code: 5, userInfo: [NSLocalizedDescriptionKey: "unknown clip setting \(k)"])
                }
            }
        case .setSpeed(let id, let speed):
            guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
            clips[i].speed = speed
        case .addZoom(let s, let e, let scale, let fx, let fy):
            zooms.append(TimelineZoom(id: newID("z"), startNs: s, endNs: e, mode: .manual, scale: scale, focusX: fx, focusY: fy))
        case .insertZoom(let s, let e):
            zooms.append(TimelineZoom(id: newID("z"), startNs: s, endNs: e, mode: .manual, scale: 2, focusX: 0.5, focusY: 0.5))
        case .setZoomLens(let id, let lens):
            if let i = zooms.firstIndex(where: { $0.id == id }) { zooms[i].lens = lens }
        case .updateZoom(let id, let s, let e, let scale, let fx, let fy, let ei, let eo, let en, let mode):
            guard let i = zooms.firstIndex(where: { $0.id == id }) else { return }
            if let s { zooms[i].startNs = s }; if let e { zooms[i].endNs = e }
            if let ei { zooms[i].easeInNs = ei }; if let eo { zooms[i].easeOutNs = eo }; if let en { zooms[i].enabled = en }; if let mode { zooms[i].mode = mode }
            if let scale { zooms[i].scale = scale }; if let fx { zooms[i].focusX = fx }; if let fy { zooms[i].focusY = fy }
        case .removeZoom(let id): zooms.removeAll { $0.id == id }
        case .set(let path, let v): settings = Self.setting(settings, path.split(separator: ".").map(String.init)[...], v)
        case .autoZooms: autoZoomRuns += 1
        case .autoSpeedTyping: typingRuns += 1
        case .applyTypingSuggestion(let id, let speed): typingCommands.append("apply \(id) \(speed)")
        case .dismissTypingSuggestion(let id): typingCommands.append("dismiss \(id)"); dismissedTypingIDs.insert(id)
        case .restoreTypingSuggestions: typingCommands.append("restore"); dismissedTypingIDs = []
        case .processSilence(let spans, let speed):
            processSilenceCalls.append((spans, speed))
            for sp in spans.sorted(by: { $0.startNs > $1.startNs }) {
                if speed == nil { try run(.deleteRange(startNs: sp.startNs, endNs: sp.endNs)) }
            }
        }
    }

    private static func setting(_ node: JSONValue, _ path: ArraySlice<String>, _ v: JSONValue) -> JSONValue {
        guard let head = path.first else { return v }
        var obj: [String: JSONValue] = [:]
        if case .object(let o) = node { obj = o }
        obj[head] = setting(obj[head] ?? .object([:]), path.dropFirst(), v)
        return .object(obj)
    }

    public func undo() throws {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(Snapshot(clips: clips, zooms: zooms, settings: settings))
        clips = s.clips; zooms = s.zooms; settings = s.settings
    }
    public func redo() throws {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(Snapshot(clips: clips, zooms: zooms, settings: settings))
        clips = s.clips; zooms = s.zooms; settings = s.settings
    }
    public var wallpapers = [WallpaperInfo(id: "quiet-dawn", title: "Quiet Dawn", category: "gradients"), WallpaperInfo(id: "boreal-glow", title: "Boreal Glow", category: "landscapes")]
    public private(set) var appliedWallpapers: [String] = []
    public var wallpaperDelay: Duration = .zero
    public func applyWallpaper(id: String) async throws {
        try await Task.sleep(for: wallpaperDelay)
        guard wallpapers.contains(where: { $0.id == id }) else { throw NSError(domain: "Fake", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unknown wallpaper"]) }
        appliedWallpapers.append(id)
        let snap = Snapshot(clips: clips, zooms: zooms, settings: settings)
        settings = Self.setting(settings, ["canvas", "background", "kind"][...], .string(id == "quiet-dawn" ? "gradient" : "image"))
        undoStack.append(snap); redoStack.removeAll()
    }
    public func wallpaperThumbnail(id: String) async -> CGImage? { nil }
    public var cameraRecipes = [CameraRecipe(id: "warm-studio", name: "Warm studio"), CameraRecipe(id: "cool-daylight", name: "Cool daylight")]
    public private(set) var importedLUTs: [URL] = []
    public func importCameraLUT(_ file: URL) throws {
        importedLUTs.append(file)
        let snap = Snapshot(clips: clips, zooms: zooms, settings: settings)
        settings = Self.setting(settings, ["camera", "style", "preset"][...], .string("lut"))
        settings = Self.setting(settings, ["camera", "style", "lut_path"][...], .string("assets/lut-1.cube"))
        undoStack.append(snap); redoStack.removeAll()
    }
    public private(set) var importedBackgrounds: [URL] = []
    public func importBackgroundImage(_ file: URL) throws {
        importedBackgrounds.append(file)
        let snap = Snapshot(clips: clips, zooms: zooms, settings: settings)
        settings = Self.setting(settings, ["canvas", "background", "kind"][...], .string("image"))
        undoStack.append(snap); redoStack.removeAll()
    }
    public private(set) var exportedPresets: [URL] = []
    public func exportPreset(to url: URL) throws { exportedPresets.append(url); try Data("{}".utf8).write(to: url) }
    public private(set) var importedPresets: [URL] = []
    public func importPreset(from url: URL) throws {
        importedPresets.append(url)
        let snap = Snapshot(clips: clips, zooms: zooms, settings: settings)
        settings = Self.setting(settings, ["canvas", "padding"][...], .number(99))
        undoStack.append(snap); redoStack.removeAll()
    }
    public var importedTranscripts = 0
    public func importTranscript(_ data: Data) throws {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let words = o["words"] as? [[String: Any]] else {
            throw NSError(domain: "Fake", code: 3, userInfo: [NSLocalizedDescriptionKey: "bad transcript"])
        }
        importedTranscripts += 1
        let rows: [JSONValue] = words.enumerated().map { i, w in
            .object(["id": .string("cap-\(i)"), "tl_start_ns": .number((w["src_start_ns"] as? Double) ?? 0), "tl_end_ns": .number((w["src_end_ns"] as? Double) ?? 1),
                     "text": .string(w["text"] as? String ?? "")])
        }
        let snap = Snapshot(clips: clips, zooms: zooms, settings: settings)
        settings = Self.setting(settings, ["canvas", "captions"][...], .array(rows))
        undoStack.append(snap); redoStack.removeAll()
    }
    public private(set) var importedMusic: [(URL, Int64)] = []
    public var importDelay: Duration = .zero
    public func importMusic(_ file: URL, startNs: Int64) async throws {
        try await Task.sleep(for: importDelay)
        importedMusic.append((file, startNs))
        let snap = Snapshot(clips: clips, zooms: zooms, settings: settings)
        var rows: [JSONValue] = []
        if case .object(let a)? = Optional(settings), case .object(let audio)? = a["audio"], case .array(let r)? = audio["music"] { rows = r }
        rows.append(.object(["id": .string("music-\(rows.count)"), "tl_start_ns": .number(Double(startNs)), "tl_end_ns": .number(Double(durationNs)),
                             "source": .string("file"), "path": .string("assets/\(file.lastPathComponent)"), "gain_db": .number(-18), "loop": .bool(true)]))
        settings = Self.setting(settings, ["audio", "music"][...], .array(rows))
        undoStack.append(snap); redoStack.removeAll()
    }
    public private(set) var closed = false
    public func close() { closed = true }
    public func silentSpans() async throws -> [TimeSpan] { try await Task.sleep(for: silenceDelay); return silences }
    public func save() throws {
        if failSave { throw NSError(domain: "Fake", code: 2, userInfo: [NSLocalizedDescriptionKey: "disk full"]) }
        saveCount += 1
    }
}

@MainActor
public final class FakePlayer: PlaybackEngine {
    public private(set) var currentNs: Int64 = 0
    public private(set) var isPlaying = false
    public var onChange: (@MainActor () -> Void)?
    public private(set) var invalidations = 0
    public private(set) var previewOptionCalls: [PreviewOptions] = []
    public func setPreviewOptions(_ o: PreviewOptions) throws { previewOptionCalls.append(o) }
    public private(set) var seeks: [(Int64, Bool)] = []
    public init() {}
    public func play() { isPlaying = true; onChange?() }
    public func pause() { isPlaying = false; onChange?() }
    public func seek(toNs ns: Int64, precise: Bool) { currentNs = ns; seeks.append((ns, precise)); onChange?() }
    public func invalidate() { invalidations += 1 }
    public private(set) var visualInvalidations = 0
    public func invalidateVisuals() { visualInvalidations += 1; invalidations += 1 }
    public private(set) var speechCalls: [SpeechEnhancement?] = []
    public var speechFailure: Error?
    public func setSpeechEnhancement(_ settings: SpeechEnhancement?) throws {
        if let speechFailure { throw speechFailure }
        speechCalls.append(settings)
    }
}

public struct FakeExporter: ExportEngine {
    public var failure: Error?
    public var steps = 5
    public init(failure: Error? = nil) { self.failure = failure }
    public func run(_ request: ExportRequest, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        for i in 1...steps {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
            progress(Double(i) / Double(steps))
        }
        if let failure { throw failure }
        return request.destination
    }
}
