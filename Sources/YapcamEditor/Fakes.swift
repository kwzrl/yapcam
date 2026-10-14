import Foundation

/// In-memory project used for development and tests until the Rust-backed `Project` lands.
/// Mirrors core semantics: split creates clips, deleteRange ripples, each command = one undo step.
@MainActor
public final class FakeProject: EditingProject {
    public private(set) var clips: [ClipInfo]
    public private(set) var zooms: [ZoomInfo] = []
    public private(set) var canvas = CanvasSettings()
    public var clickTimesNs: [Int64] = []
    public private(set) var saveCount = 0
    public var failSave = false
    private var nextID = 1
    private struct Snapshot { var clips: [ClipInfo]; var zooms: [ZoomInfo]; var canvas: CanvasSettings }
    private var undoStack: [Snapshot] = [], redoStack: [Snapshot] = []

    public init(durationNs: Int64 = 10_000_000_000) {
        clips = [ClipInfo(id: "c0", srcStartNs: 0, srcEndNs: durationNs)]
    }

    public var durationNs: Int64 { clips.reduce(0) { $0 + $1.timelineDurationNs } }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func apply(_ command: EditorCommand) throws {
        let snap = Snapshot(clips: clips, zooms: zooms, canvas: canvas)
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
            var t: Int64 = 0
            var out: [ClipInfo] = []
            for clip in clips {
                let d = clip.timelineDurationNs
                defer { t += d }
                if t >= s && t + d <= e { continue }            // fully removed
                out.append(clip)
            }
            clips = out
            let removed = e - s
            zooms = zooms.compactMap { z in
                var z = z
                if z.startNs >= e { z.startNs -= removed; z.endNs -= removed }
                else if z.endNs > s { return nil }
                return z
            }
        case .setSpeed(let id, let speed):
            guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
            clips[i].speed = speed
        case .addZoom(let s, let e, let scale, let fx, let fy):
            zooms.append(ZoomInfo(id: newID("z"), startNs: s, endNs: e, mode: .manual, scale: scale, focusX: fx, focusY: fy))
        case .updateZoom(let id, let s, let e, let scale, let fx, let fy):
            guard let i = zooms.firstIndex(where: { $0.id == id }) else { return }
            if let s { zooms[i].startNs = s }; if let e { zooms[i].endNs = e }
            if let scale { zooms[i].scale = scale }; if let fx { zooms[i].focusX = fx }; if let fy { zooms[i].focusY = fy }
        case .removeZoom(let id): zooms.removeAll { $0.id == id }
        case .setNumber(let path, let v):
            switch path {
            case "canvas.padding": canvas.padding = v
            case "canvas.radius": canvas.cornerRadius = v
            case "canvas.shadow": canvas.shadow = v
            default: break
            }
        case .setString(let path, let v): if path == "canvas.background" { canvas.backgroundColorHex = v }
        }
    }

    public func undo() throws {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(Snapshot(clips: clips, zooms: zooms, canvas: canvas))
        clips = s.clips; zooms = s.zooms; canvas = s.canvas
    }
    public func redo() throws {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(Snapshot(clips: clips, zooms: zooms, canvas: canvas))
        clips = s.clips; zooms = s.zooms; canvas = s.canvas
    }
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
    public private(set) var seeks: [(Int64, Bool)] = []
    public init() {}
    public func play() { isPlaying = true; onChange?() }
    public func pause() { isPlaying = false; onChange?() }
    public func seek(toNs ns: Int64, precise: Bool) { currentNs = ns; seeks.append((ns, precise)); onChange?() }
    public func invalidate() { invalidations += 1 }
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
