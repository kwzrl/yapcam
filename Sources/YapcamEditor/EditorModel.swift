import Foundation
import Combine

public enum EditorSelection: Equatable, Sendable {
    case none
    case clip(String)
    case zoom(String)
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
    @Published public var snapGuideNs: Int64?
    @Published public var lastError: String?
    @Published public private(set) var saveState: SaveState = .clean

    public enum SaveState: Equatable { case clean, dirty, failed(String) }

    private var autosaveTask: Task<Void, Never>?
    public var autosaveDelay: Duration = .seconds(2)

    public init(project: EditingProject, player: PlaybackEngine) {
        self.project = project
        self.player = player
        self.player.onChange = { [weak self] in self?.syncFromPlayer() }
        syncFromPlayer()
    }

    // MARK: derived

    public var clips: [ClipInfo] { project.clips }
    public var zooms: [ZoomInfo] { project.zooms }
    public var durationNs: Int64 { project.durationNs }
    public var canUndo: Bool { project.canUndo }
    public var canRedo: Bool { project.canRedo }
    public var canvas: CanvasSettings { project.canvas }

    public var selectedZoom: ZoomInfo? {
        if case .zoom(let id) = selection { return zooms.first { $0.id == id } }
        return nil
    }

    /// Timeline start (ns) of each clip, in order.
    public func clipStarts() -> [(clip: ClipInfo, startNs: Int64)] {
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

    private func perform(_ command: EditorCommand) {
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

    public func splitAtPlayhead() {
        guard playheadNs > 0, playheadNs < durationNs else { return }
        // No-op on an existing clip boundary.
        if clipStarts().contains(where: { $0.startNs == playheadNs }) { return }
        perform(.split(atNs: playheadNs))
    }

    public func deleteSelection() {
        switch selection {
        case .none: return
        case .zoom(let id): perform(.removeZoom(id: id)); selection = .none
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

    public func moveZoom(id: String, toStartNs start: Int64) {
        guard let z = zooms.first(where: { $0.id == id }) else { return }
        let len = z.endNs - z.startNs
        let s = min(max(start, 0), max(0, durationNs - len))
        perform(.updateZoom(id: id, startNs: s, endNs: s + len, scale: nil, focusX: nil, focusY: nil))
    }

    public func resizeZoom(id: String, startNs: Int64? = nil, endNs: Int64? = nil) {
        guard let z = zooms.first(where: { $0.id == id }) else { return }
        var s = startNs ?? z.startNs, e = endNs ?? z.endNs
        s = max(0, s); e = min(durationNs, e)
        if e - s < minZoomDurationNs { if startNs != nil { s = e - minZoomDurationNs } else { e = s + minZoomDurationNs } }
        guard s >= 0, e <= durationNs else { return }
        perform(.updateZoom(id: id, startNs: s, endNs: e, scale: nil, focusX: nil, focusY: nil))
    }

    public func setZoomScale(id: String, _ scale: Double) {
        perform(.updateZoom(id: id, startNs: nil, endNs: nil, scale: min(max(scale, 1), 6), focusX: nil, focusY: nil))
    }

    public func setCanvasNumber(_ path: String, _ value: Double) { perform(.setNumber(path: path, value: value)) }
    public func setCanvasString(_ path: String, _ value: String) { perform(.setString(path: path, value: value)) }

    public func undo() {
        guard canUndo else { return }
        do { try project.undo(); didEdit(); selection = .none } catch { lastError = error.localizedDescription }
    }
    public func redo() {
        guard canRedo else { return }
        do { try project.redo(); didEdit() } catch { lastError = error.localizedDescription }
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

    public func zoomTimeline(by factor: Double, anchorX: Double) { geometry = geometry.zoomed(by: factor, anchorX: anchorX) }
    public func fitTimeline(width: Double) { geometry = .fitting(durationNs: durationNs, width: width) }
}
