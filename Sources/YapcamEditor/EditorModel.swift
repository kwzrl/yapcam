import Foundation
import Combine
import YapcamCore
import CoreGraphics

public enum EditorSelection: Equatable, Sendable {
    case none
    case clip(String)
    case zoom(String)
    case layout(String)
    case cursorHide(Int)
}

public let minZoomDurationNs: Int64 = 300_000_000
public let defaultZoomDurationNs: Int64 = 2_000_000_000

/// All editor state and actions. Views are thin; everything here is unit-testable
/// against fake backends.
@MainActor
public final class EditorModel: ObservableObject {
    public let project: EditingProject
    public let player: PlaybackEngine

    @Published public private(set) var revision = 0          // bumps on every project change
    @Published public var selection: EditorSelection = .none
    @Published public var geometry = TimelineGeometry(pixelsPerSecond: 60)
    @Published public var snappingEnabled = true
    @Published public private(set) var playheadNs: Int64 = 0
    @Published public private(set) var isPlaying = false
    @Published public var paletteVisible = false
    @Published public var snapGuideNs: Int64?
    /// Additional zooms selected with ⇧/⌘-click (the primary one is in `selection`).
    @Published public var extraZoomSelection: Set<String> = []
    /// Set by the document: renders the current preview frame to the clipboard.
    public var copyFrameHandler: (() -> Void)?
    @Published public var lastError: String?
    @Published public private(set) var silenceState: SilenceState = .idle
    @Published public private(set) var saveState: SaveState = .clean

    public enum SaveState: Equatable { case clean, dirty, failed(String) }
    public enum SilenceState: Equatable { case idle, analyzing, found([TimeSpan]), failed(String) }

    private var autosaveTask: Task<Void, Never>?
    public var autosaveDelay: Duration = .seconds(2)

    public init(project: EditingProject, player: PlaybackEngine) {
        self.project = project
        self.player = player
        self.player.onChange = { [weak self] in self?.syncFromPlayer() }
        syncFromPlayer()
    }

    // MARK: derived

    public var clips: [TimelineClip] { project.clips }
    public var zooms: [TimelineZoom] { project.zooms }
    public var durationNs: Int64 { project.durationNs }
    public var canUndo: Bool { project.canUndo }
    public var canRedo: Bool { project.canRedo }
    public var settings: JSONValue { project.settings }

    // Typed reads of project settings by dotted path (e.g. "canvas.padding").
    public func value(_ path: String) -> JSONValue? {
        var cur: JSONValue? = project.settings
        for part in path.split(separator: ".") {
            guard case .object(let o)? = cur else { return nil }
            cur = o[String(part)]
        }
        return cur
    }
    public func number(_ path: String, default d: Double = 0) -> Double { if case .number(let v)? = value(path) { v } else { d } }
    public func bool(_ path: String, default d: Bool = false) -> Bool { if case .bool(let v)? = value(path) { v } else { d } }
    public func string(_ path: String, default d: String = "") -> String { if case .string(let v)? = value(path) { v } else { d } }
    public func numbers(_ path: String) -> [Double] {
        if case .array(let a)? = value(path) { return a.compactMap { if case .number(let v) = $0 { v } else { nil } } }
        return []
    }
    /// RGBA color stored as [r,g,b,a] 0…1 under `path`.
    public func color(_ path: String) -> [Double] { let n = numbers(path); return n.count == 4 ? n : [0, 0, 0, 1] }

    public func set(_ path: String, _ value: JSONValue) { perform(.set(path: path, value: value)) }
    public func set(_ path: String, number v: Double) { set(path, .number(v)) }
    public func set(_ path: String, bool v: Bool) { set(path, .bool(v)) }
    public func set(_ path: String, string v: String) { set(path, .string(v)) }
    public func set(_ path: String, color c: [Double]) { set(path, .array(c.map { .number($0) })) }
    public var hasCamera: Bool { project.hasCamera }
    public var hasMic: Bool { project.hasMic }

    public var previewAspect: Double { project.frameGeometry(atNs: playheadNs)?.aspect ?? 16.0 / 9 }

    /// Click in the preview (0…1 of the whole preview) → focus point of the selected zoom.
    @discardableResult public func setFocus(fromPreview p: CGPoint) -> Bool {
        guard let z = selectedZoom, let g = project.frameGeometry(atNs: playheadNs), let s = g.sourcePoint(fromPreview: p) else { return false }
        setZoomFocus(id: z.id, x: Double(s.x), y: Double(s.y))
        return true
    }

    /// Aspect change updates the stored output size in the same undo step.
    public func setAspect(_ a: AspectPreset) {
        var cmds: [EditorCommand] = [.set(path: "canvas.aspect", value: .string(a.rawValue))]
        if let size = a.outputSize { cmds.append(.set(path: "canvas.output_size", value: .array(size.map { .number($0) }))) }
        perform(.batch(cmds))
    }
    public func speedUpTyping(speed: Double = 3) { perform(.autoSpeedTyping(speed: speed)) }

    public func findSilences() {
        guard silenceState != .analyzing else { return }
        silenceState = .analyzing
        Task { [weak self] in
            guard let self else { return }
            do { silenceState = .found(try await project.silentSpans()) }
            catch { silenceState = .failed(error.localizedDescription) }
        }
    }
    /// Cut (`speed == nil`) or speed up the silences found by `findSilences()` in one undo step.
    public func applySilences(speed: Double?) {
        guard case .found(let spans) = silenceState, !spans.isEmpty else { return }
        perform(.processSilence(spans: spans, speed: speed))
        silenceState = .idle
    }
    public func dismissSilences() { silenceState = .idle }

    public func regenerateAutoZooms() { perform(.autoZooms) }

    public var selectedZoom: TimelineZoom? {
        if case .zoom(let id) = selection { return zooms.first { $0.id == id } }
        return nil
    }

    /// Timeline start (ns) of each clip, in order.
    public func clipStarts() -> [(clip: TimelineClip, startNs: Int64)] {
        var t: Int64 = 0
        return clips.map { c in defer { t += c.timelineDurationNs }; return (c, t) }
    }

    private func syncFromPlayer() {
        playheadNs = player.currentNs
        isPlaying = player.isPlaying
    }

    // MARK: transport

    public func togglePlay() { isPlaying ? player.pause() : player.play(); syncFromPlayer() }
    public func pause() { player.pause(); syncFromPlayer() }

    public func seek(toNs ns: Int64, precise: Bool = true) {
        let clamped = min(max(ns, 0), durationNs)
        player.seek(toNs: clamped, precise: precise)
        playheadNs = clamped
    }

    public func step(bySeconds s: Double) { seek(toNs: playheadNs + Int64(s * 1e9)) }

    /// J/K/L: J steps back 1 s (pauses), K pauses, L plays; repeated L toggles nothing more
    /// in M1 (variable-rate shuttle needs player support; recorded in status as open).
    public func shuttle(_ key: Character) {
        switch key {
        case "j": pause(); step(bySeconds: -1)
        case "k": pause()
        case "l": if !isPlaying { player.play(); syncFromPlayer() }
        default: break
        }
    }

    // MARK: editing

    func perform(_ command: EditorCommand) {
        do {
            try project.apply(command)
            didEdit()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func didEdit() {
        revision += 1
        player.invalidate()
        if playheadNs > durationNs { seek(toNs: durationNs) }
        saveState = .dirty
        scheduleAutosave()
    }

    /// Remove everything before (`keepAfter`) or after the playhead; one undo step.
    public func trim(keepAfter: Bool) {
        guard playheadNs > 0, playheadNs < durationNs else { lastError = "Move the playhead inside the clip first."; return }
        perform(keepAfter ? .deleteRange(startNs: 0, endNs: playheadNs) : .deleteRange(startNs: playheadNs, endNs: durationNs))
    }

    public func splitAtPlayhead() {
        guard playheadNs > 0, playheadNs < durationNs else { return }
        // No-op on an existing clip boundary.
        if clipStarts().contains(where: { $0.startNs == playheadNs }) { return }
        perform(.split(atNs: playheadNs))
    }

    public func deleteSelection() {
        switch selection {
        case .none: return
        case .zoom(let id):
            let ids = [id] + extraZoomSelection.filter { $0 != id }.sorted()
            perform(ids.count == 1 ? .removeZoom(id: id) : .batch(ids.map { .removeZoom(id: $0) }))
            selection = .none; extraZoomSelection = []
        case .layout(let id): removeLayout(id: id); selection = .none
        case .cursorHide(let i): removeCursorHide(index: i); selection = .none
        case .clip(let id):
            guard let entry = clipStarts().first(where: { $0.clip.id == id }) else { return }
            if clips.count == 1 { lastError = "Can't delete the only clip."; return }
            perform(.deleteRange(startNs: entry.startNs, endNs: entry.startNs + entry.clip.timelineDurationNs))
            selection = .none
        }
    }

    public func addZoomAtPlayhead() {
        let start = playheadNs
        let end = min(start + defaultZoomDurationNs, durationNs)
        guard end - start >= minZoomDurationNs else {
            lastError = "Not enough room for a zoom at the end of the project."
            return
        }
        let before = Set(zooms.map(\.id))
        perform(.addZoom(startNs: start, endNs: end, scale: 2, focusX: 0.5, focusY: 0.5))
        if let new = zooms.first(where: { !before.contains($0.id) }) { selection = .zoom(new.id) }
    }

    // Zoom drags preview locally and commit once on release → one undo step per gesture.
    @Published public private(set) var zoomPreview: [String: (start: Int64, end: Int64)] = [:]
    func zoomPreviewSet(_ k: String, _ v: (start: Int64, end: Int64)) { zoomPreview[k] = v }
    func zoomPreviewTake(_ k: String) -> (start: Int64, end: Int64)? { zoomPreview.removeValue(forKey: k) }

    public func displayedRange(of z: TimelineZoom) -> (start: Int64, end: Int64) {
        zoomPreview[z.id] ?? (z.startNs, z.endNs)
    }

    public func previewZoom(id: String, startNs: Int64? = nil, endNs: Int64? = nil, moveToStartNs: Int64? = nil) {
        guard let z = zooms.first(where: { $0.id == id }) else { return }
        var s = z.startNs, e = z.endNs
        if let m = moveToStartNs {
            let len = z.endNs - z.startNs
            s = min(max(m, 0), max(0, durationNs - len)); e = s + len
        } else {
            if let startNs { s = max(0, min(startNs, e - minZoomDurationNs)) }
            if let endNs { e = min(durationNs, max(endNs, s + minZoomDurationNs)) }
        }
        zoomPreview[id] = (s, e)
    }

    public func commitZoomPreview(id: String) {
        guard let r = zoomPreview.removeValue(forKey: id), let z = zooms.first(where: { $0.id == id }),
              r.start != z.startNs || r.end != z.endNs else { return }
        perform(.updateZoom(id: id, startNs: r.start, endNs: r.end, scale: nil, focusX: nil, focusY: nil))
    }

    public func moveZoom(id: String, toStartNs start: Int64) { previewZoom(id: id, moveToStartNs: start); commitZoomPreview(id: id) }
    public func resizeZoom(id: String, startNs: Int64? = nil, endNs: Int64? = nil) {
        previewZoom(id: id, startNs: startNs, endNs: endNs); commitZoomPreview(id: id)
    }

    public func setZoomEnabled(id: String, _ on: Bool) {
        perform(.updateZoom(id: id, startNs: nil, endNs: nil, scale: nil, focusX: nil, focusY: nil, enabled: on))
    }
    public func setZoomEase(id: String, inNs: Int64, outNs: Int64) {
        perform(.updateZoom(id: id, startNs: nil, endNs: nil, scale: nil, focusX: nil, focusY: nil, easeInNs: max(0, inNs), easeOutNs: max(0, outNs)))
    }

    public func setZoomScale(id: String, _ scale: Double) {
        perform(.updateZoom(id: id, startNs: nil, endNs: nil, scale: min(max(scale, 1), 6), focusX: nil, focusY: nil))
    }


    public func undo() {
        guard canUndo else { return }
        do { try project.undo(); didEdit(); selection = .none } catch { lastError = error.localizedDescription }
    }
    public func redo() {
        guard canRedo else { return }
        do { try project.redo(); didEdit() } catch { lastError = error.localizedDescription }
    }

    public func setSpeed(clipID: String, _ speed: Double) {
        guard clips.contains(where: { $0.id == clipID }) else { return }
        perform(.setSpeed(clipID: clipID, speed: min(max(speed, 0.1), 16)))
    }

    /// Focus point in normalized source space, clamped so the zoomed crop stays inside the frame.
    public func setZoomFocus(id: String, x: Double, y: Double) {
        guard let z = zooms.first(where: { $0.id == id }) else { return }
        let half = 0.5 / max(z.scale, 1)
        perform(.updateZoom(id: id, startNs: nil, endNs: nil, scale: nil,
                            focusX: min(max(x, half), 1 - half), focusY: min(max(y, half), 1 - half)))
    }

    // MARK: snapping

    public func snapTargets(excludingZoom id: String? = nil) -> [SnapTarget] {
        Snapping.targets(clips: clips, zooms: zooms, clicks: project.clickTimesNs,
                         playheadNs: playheadNs, durationNs: durationNs, excludingZoom: id)
    }

    public func snapped(_ ns: Int64, excludingZoom id: String? = nil) -> Int64 {
        let r = Snapping.snap(ns, targets: snapTargets(excludingZoom: id), geometry: geometry, enabled: snappingEnabled)
        snapGuideNs = r.target?.ns
        return r.ns
    }

    // MARK: save

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let delay = autosaveDelay
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            self?.saveNow()
        }
    }

    /// Immediate save: used by the debounce and on window close.
    public func saveNow() {
        autosaveTask?.cancel()
        guard saveState != .clean else { return }
        do { try project.save(); saveState = .clean }
        catch { saveState = .failed(error.localizedDescription); lastError = "Couldn't save: \(error.localizedDescription)" }
    }

    // MARK: timeline zoom

    /// Native horizontal scrolling owns the offset, so the model only changes the scale.
    public func zoomTimeline(by factor: Double, anchorX: Double = 0) { geometry = TimelineGeometry(pixelsPerSecond: geometry.pixelsPerSecond * factor) }
    public func fitTimeline(width: Double) { geometry = .fitting(durationNs: durationNs, width: width) }
}
