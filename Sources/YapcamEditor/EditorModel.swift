import AVFoundation
import Foundation
import Combine
import YapcamCore
import CoreGraphics

@MainActor public final class PlayheadState: ObservableObject {
    @Published public var ns: Int64 = 0
    @Published public var isPlaying = false
}

public enum EditorSelection: Equatable, Sendable {
    case none
    case clip(String)
    case zoom(String)
    case layout(String)
    case cursorHide(Int)
    case highlight(String)
    case text(TextKind, String)
    case music(String)
}

public let minZoomDurationNs: Int64 = 300_000_000
/// Projects shorter than the usual minimum (e.g. 0.2 s) still accept items that span the whole project.
public let defaultZoomDurationNs: Int64 = 3_000_000_000

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
    /// Playhead and play state live in their own observable so that scrubbing and playback redraw only
    /// the playhead marker and time label, not the (potentially 700-item) tracks.
    public let playhead = PlayheadState()
    public private(set) var playheadNs: Int64 { get { playhead.ns } set { if playhead.ns != newValue { playhead.ns = newValue } } }
    public private(set) var isPlaying: Bool { get { playhead.isPlaying } set { if playhead.isPlaying != newValue { playhead.isPlaying = newValue } } }
    /// Where this document's presets and remembered settings live (injectable; isolated outside the real app).
    public var presetStore: PresetStore = EditorPresets.currentStore
    /// `cursor.set_id` values the open core accepts (from its `cursor_library` query); drives the cursor set carousel.
    public var cursorSetIDs: [String] = []
    public var defaults: UserDefaults = EditorPresets.currentStore.defaults
    @Published public var paletteVisible = false
    @Published public var previewOptions = PreviewOptions()
    @Published public var silenceRangesState: SilenceRangesState = .idle
    var silenceRangesTask: Task<Void, Never>?
    @Published public var speedMenuVisible = false
    var lastRegionStyle: HighlightRegion?
    /// Typing suggestion whose popover is open (start of its span), and the ones the user dismissed.
    @Published public var typingPopover: Int64?
    @Published public var volumeMenuVisible = false
    public var volumeMenuSystem = false
    public var itemClipboard: ItemClipboard?
    /// Visible width of the timeline in points (set by the view); bounds the timeline zoom window to 2 s…10 min.
    /// Microphone level across the edited timeline, drawn in the clip track (reference: "audio waveform on/off").
    @Published public internal(set) var waveform: [WavePoint] = []
    @Published public internal(set) var showWaveform = true
    @Published public internal(set) var smoothWaveform = false
    /// The document's export model (set by `EditorDocument`) and what the window does to show its export sheet.
    weak var exportModel: ExportModel?
    var showExportPickerHandler: (@MainActor () -> Void)?
    var exportTitle = "Recording"
    /// Rebindable single-key shortcuts (the app's Settings edit `EditorKeyBindings.shared`; tests inject their own).
    var keyBindings: EditorKeyBindings = .shared
    var lastInset: (size: Double, color: [Double])?
    /// Wallpapers starred by the user (right-click in the picker); remembered across projects.
    @Published public internal(set) var favoriteWallpapers: Set<String> = []
    public func toggleFavoriteWallpaper(_ id: String) {
        if favoriteWallpapers.contains(id) { favoriteWallpapers.remove(id) } else { favoriteWallpapers.insert(id) }
        defaults.set(Array(favoriteWallpapers).sorted(), forKey: "editor.favoriteWallpapers")
    }
    public var timelineViewportWidth: Double = 900
    /// Set once the timeline view has fitted the project to its real width.
    var timelineFitted = false
    /// Raised by the toolbar-less "Move to Trash" command; the editor shows its confirmation.
    @Published public var trashRequested = false
    /// Raised by the File menu's crop command; the editor opens its crop popover.
    @Published public var cropRequested = false
    /// Inspector section chosen in the icon rail (⌘1…⌘0 select by position).
    @Published public var inspectorSection: InspectorSection = .background
    @Published public var textRectPreview: (key: String, rect: [Double])?
    public enum CaptionState: Equatable { case idle, working, failed(String) }
    @Published public var captionState: CaptionState = .idle
    /// Supplies transcript JSON (RecordingTranscript). Set by the document; nil = transcription unavailable.
    public var captionSource: (@Sendable () async throws -> Data)?
    /// Options-aware transcription (keyterms, language); `force` = ignore an existing transcript file and recognize again.
    public var captionSourceWithOptions: (@Sendable (TranscriptionOptions, Bool) async throws -> Data)?
    var captionTask: Task<Void, Never>?
    /// Project changed through a path that bypassed `perform` (transcript import, music import).
    func noteExternalEdit() { didEdit() }
    /// Rect drag in progress on the preview (normalized rect), committed once on release.
    @Published public var highlightRectPreview: (id: String, rect: [Double])?
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
    /// True once the document window closed. Everything after that is inert: edits, saves and the
    /// completion of background work (music import, wallpaper, transcript, silence) are refused so a
    /// stale model can never journal over a reopened document's newer state.
    public private(set) var isClosed = false
    var musicTask: Task<Void, Never>?
    /// Background-audio library UI state: track being previewed, the user's own audio folder, volumes remembered while muted.
    @Published public internal(set) var previewingMusicID: String?
    public var userMusicFolder = EditorModel.defaultMusicFolder
    var musicPreviewTask: Task<Void, Never>?
    var musicPlayer: AVAudioPlayer?
    var musicPreviewFile: URL?
    var mutedMusicGains: [String: Double] = [:]

    /// Saves pending edits, cancels all background work and makes the model inert.
    public func close() {
        guard !isClosed else { return }
        saveNow()
        isClosed = true
        autosaveTask?.cancel()
        stopMusicPreview()
        for t in [silenceTask, captionTask, wallpaperTask, musicTask, pendingInvalidate, silenceRangesTask] { t?.cancel() }
        player.pause()
        project.close()      // core refuses any mutation from now on, even from work that was already past its last cancellation check
    }
    /// Same policy as core's `ProjectAutosaver`: save 30 s after the last edit, and only if nothing changed meanwhile.
    /// (Unsaved edits are covered by core's recovery journal; closing the window saves at once.)
    public var autosaveDelay: Duration = .seconds(30)
    /// Asked before each autosave is scheduled; defaults to the app-wide setting (`EditorWindows.autosaveEnabled`).
    public var autosaveAllowed: () -> Bool = { EditorWindows.autosaveEnabled }

    public init(project: EditingProject, player: PlaybackEngine) {
        self.project = project
        self.player = player
        self.player.onChange = { [weak self] in self?.syncFromPlayer() }
        syncFromPlayer()
        applySpeechToPlayer()
    }

    // MARK: derived

    public var clips: [TimelineClip] { project.clips }
    public var zooms: [TimelineZoom] { project.zooms }
    public var durationNs: Int64 { project.durationNs }
    public var canUndo: Bool { project.canUndo }
    public var canRedo: Bool { project.canRedo }
    public var settings: JSONValue { project.settings }
    var minItemNs: Int64 { min(minZoomDurationNs, max(durationNs, 1)) }

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

    public func set(_ path: String, _ value: JSONValue) {
        if path == "canvas.background.kind" { selectedWallpaperID = nil }
        perform(.set(path: path, value: value))
    }
    /// Several settings as one command = one undo step.
    public func setMany(_ items: [(path: String, value: JSONValue)]) {
        guard !items.isEmpty else { return }
        perform(.batch(items.map { .set(path: $0.path, value: $0.value) }))
    }
    public func set(_ path: String, number v: Double) { set(path, .number(v)) }
    public func set(_ path: String, bool v: Bool) { set(path, .bool(v)) }
    public func set(_ path: String, string v: String) { set(path, .string(v)) }
    public func set(_ path: String, color c: [Double]) { set(path, .array(c.map { .number($0) })) }
    public var hasCamera: Bool { project.hasCamera }
    public var hasMic: Bool { project.hasMic }
    public var hasMouseData: Bool { project.hasMouseData }
    public var hasKeystrokes: Bool { project.hasKeystrokes }

    public var previewAspect: Double { project.frameGeometry(atNs: playheadNs)?.aspect ?? 16.0 / 9 }

    /// Focus drags preview locally and commit one command on release (one undo step per gesture).
    @Published public private(set) var focusPreview: (id: String, x: Double, y: Double)?

    public func previewFocus(fromPreview p: CGPoint) {
        guard let z = selectedZoom, let g = project.frameGeometry(atNs: playheadNs), let s = g.sourcePoint(fromPreview: p) else { return }
        let half = 0.5 / max(z.scale, 1)
        focusPreview = (z.id, min(max(Double(s.x), half), 1 - half), min(max(Double(s.y), half), 1 - half))
    }
    public func commitFocusPreview() {
        guard let f = focusPreview else { return }
        focusPreview = nil
        guard let z = zooms.first(where: { $0.id == f.id }), z.focusX != f.x || z.focusY != f.y else { return }
        perform(.updateZoom(id: f.id, startNs: nil, endNs: nil, scale: nil, focusX: f.x, focusY: f.y))
    }

    /// Keyboard / VoiceOver equivalent of dragging the focus point (normalized source units).
    public func nudgeFocus(dx: Double, dy: Double) {
        guard let z = selectedZoom else { return }
        setZoomFocus(id: z.id, x: z.focusX + dx, y: z.focusY + dy)
    }

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

    private var silenceTask: Task<Void, Never>?
    /// Suspends until a running silence analysis has finished (for deterministic tests).
    public func waitForSilenceAnalysis() async { await silenceTask?.value }

    public func findSilences() {
        guard silenceState != .analyzing else { return }
        silenceState = .analyzing
        let started = revision
        silenceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let spans = try await project.silentSpans()
                guard !isClosed, !Task.isCancelled else { return }
                // Timeline coordinates are only valid for the revision they were measured on.
                silenceState = revision == started ? .found(spans) : .idle
            } catch {
                guard !isClosed else { return }
                silenceState = revision == started ? .failed(error.localizedDescription) : .idle
            }
        }
    }
    /// Cut (`speed == nil`) or speed up the silences found by `findSilences()` in one undo step.
    public func applySilences(speed: Double?) {
        guard case .found(let spans) = silenceState, !spans.isEmpty else { return }
        perform(.processSilence(spans: spans, speed: speed))
        silenceState = .idle
    }
    public func dismissSilences() { silenceState = .idle }

    public var wallpapers: [WallpaperInfo] { project.wallpapers }
    /// The wallpaper applied in this session (not persisted: core stores colors/image, not the library id).
    @Published public var selectedWallpaperID: String?
    /// Split-on-click mode of the scissors tool.
    @Published public var cutToolActive = false
    /// Preview view magnification (1 = fit) and pan offset in points; purely a view setting.
    @Published public var previewZoom = 1.0
    @Published public var previewPan = CGSize.zero

    public func zoomPreview(by factor: Double) {
        previewZoom = min(max(previewZoom * factor, 1), 4)
        if previewZoom == 1 { previewPan = .zero }
    }
    public func resetPreviewZoom() { previewZoom = 1; previewPan = .zero }

    /// Uses an image file as the background (copied into the package; one undo step).
    public func importBackgroundImage(_ url: URL) {
        guard !isClosed else { return }
        do { try project.importBackgroundImage(url); selectedWallpaperID = nil; noteExternalEdit() }
        catch { lastError = "Couldn't use the image: \(error.localizedDescription)" }
    }

    public func applyRandomWallpaper() {
        let options = wallpapers.filter { $0.id != selectedWallpaperID }
        if let pick = options.randomElement() { applyWallpaper(id: pick.id) }
    }
    @Published public var wallpaperBusy: String?
    /// Applies a library wallpaper (gradients set colors; artwork imports a generated image) as one undo step.
    public func applyWallpaper(id: String) {
        guard wallpaperBusy == nil else { return }
        wallpaperBusy = id
        wallpaperTask = Task { [weak self] in
            guard let self else { return }
            defer { wallpaperBusy = nil }
            guard !isClosed else { return }
            do {
                try Task.checkCancellation()
                try await project.applyWallpaper(id: id)
                if !isClosed { selectedWallpaperID = id; noteExternalEdit() }
            } catch is CancellationError {
            } catch { if !isClosed { lastError = "Couldn't apply the wallpaper: \(error.localizedDescription)" } }
        }
    }
    var wallpaperTask: Task<Void, Never>?
    public func waitForWallpaper() async { await wallpaperTask?.value }

    /// Microphone clean-up from project settings (nil when off or the recording has no microphone).
    public var speechEnhancement: SpeechEnhancement? {
        guard hasMic, bool("audio.speech_enhancement") else { return nil }
        var s = SpeechEnhancement(), d = "audio.speech_enhancement_settings."
        s.highPassHz = number(d + "high_pass_hz", default: s.highPassHz)
        s.noiseThresholdDB = number(d + "noise_threshold_db", default: s.noiseThresholdDB)
        s.noiseReductionDB = number(d + "noise_reduction_db", default: s.noiseReductionDB)
        s.compressorThresholdDB = number(d + "compressor_threshold_db", default: s.compressorThresholdDB)
        s.compressorRatio = number(d + "compressor_ratio", default: s.compressorRatio)
        s.targetLUFS = number(d + "target_lufs", default: s.targetLUFS)
        s.peakCeilingDBFS = number(d + "peak_ceiling_dbfs", default: s.peakCeilingDBFS)
        s.normalizeLoudness = bool(d + "normalize_loudness", default: s.normalizeLoudness)
        return s
    }
    private var lastSpeech: SpeechEnhancement??
    /// Pushes the (possibly changed) clean-up settings to the preview; render re-prepares audio only on change.
    func applySpeechToPlayer() {
        let current = speechEnhancement
        if let last = lastSpeech, last == current { return }
        do { try player.setSpeechEnhancement(current); lastSpeech = .some(current) }
        catch { lastError = "Voice clean-up unavailable: \(error.localizedDescription)" }
    }

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
        guard !isClosed else { return }
        do {
            try project.apply(command)
            didEdit(visualOnly: command.isVisualOnly)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func didEdit(visualOnly: Bool = false) {
        revision += 1
        applySpeechToPlayer()
        if case .found = silenceState { silenceState = .idle }   // stale after any edit
        requestPlayerRefresh(visualOnly: visualOnly)
        if playheadNs > durationNs { seek(toNs: durationNs) }
        saveState = .dirty
        scheduleAutosave()
    }

    /// Remove everything before (`keepAfter`) or after the playhead; one undo step.
    public func trim(keepAfter: Bool) {
        guard playheadNs > 0, playheadNs < durationNs else { lastError = "Move the playhead inside the clip first."; return }
        perform(keepAfter ? .deleteRange(startNs: 0, endNs: playheadNs) : .deleteRange(startNs: playheadNs, endNs: durationNs))
    }

    /// For state restored from an autosave journal: it exists only in the journal until saved.
    public func markRecoveredUnsaved() { saveState = .dirty; scheduleAutosave() }

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
        case .highlight(let id): removeHighlight(id: id); selection = .none
        case .text(let kind, let id): removeText(kind, id: id); selection = .none
        case .music(let id): removeMusic(id: id); selection = .none
        case .clip(let id):
            guard let entry = clipStarts().first(where: { $0.clip.id == id }) else { return }
            if clips.count == 1 { lastError = "Can't delete the only clip."; return }
            perform(.deleteRange(startNs: entry.startNs, endNs: entry.startNs + entry.clip.timelineDurationNs))
            selection = .none
        }
    }

    public func addZoomAtPlayhead() {
        // Near the end of the project the zoom is moved earlier instead of being refused.
        let start = max(0, min(playheadNs, durationNs - minItemNs))
        let end = min(start + defaultZoomDurationNs, durationNs)
        guard end - start >= minItemNs else {
            lastError = "Not enough room for a zoom at the end of the project."
            return
        }
        let before = Set(zooms.map(\.id))
        perform(.insertZoom(startNs: start, endNs: end))
        if let new = zooms.first(where: { !before.contains($0.id) }) { selection = .zoom(new.id) }
    }

    /// Click (default length) or drag (that range) in the empty zoom track. One undo step; the new zoom is selected.
    public func addZoom(fromNs a: Int64, toNs b: Int64? = nil) {
        var start = max(0, min(a, durationNs)), end = b.map { max(0, min($0, durationNs)) } ?? start + defaultZoomDurationNs
        if end < start { swap(&start, &end) }
        if end - start < minItemNs { end = start + defaultZoomDurationNs }
        if end > durationNs { end = durationNs; start = max(0, min(start, end - minItemNs)) }
        guard end - start >= minItemNs else { lastError = "Not enough room for a zoom here."; return }
        let before = Set(zooms.map(\.id))
        perform(.insertZoom(startNs: start, endNs: end))
        if let new = zooms.first(where: { !before.contains($0.id) }) { selection = .zoom(new.id) }
    }
    /// Range being dragged out in the zoom track (nil when not dragging).
    @Published var zoomCreatePreview: (start: Int64, end: Int64)?

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
            if let startNs { s = max(0, min(startNs, e - minItemNs)) }
            if let endNs { e = min(durationNs, max(endNs, s + minItemNs)) }
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
    /// Auto ↔ manual: a manual zoom keeps its position when the user edits it by hand.
    public func setZoomMode(id: String, _ mode: TimelineZoom.Mode) {
        perform(.updateZoom(id: id, startNs: nil, endNs: nil, scale: nil, focusX: nil, focusY: nil, mode: mode))
    }
    public func setZoomEase(id: String, inNs: Int64, outNs: Int64) {
        perform(.updateZoom(id: id, startNs: nil, endNs: nil, scale: nil, focusX: nil, focusY: nil, easeInNs: max(0, inNs), easeOutNs: max(0, outNs)))
    }

    /// Classic ↔ glass loupe; `lens` carries the (clamped) loupe parameters.
    public func setZoomLens(id: String, _ lens: ZoomLensParams?) {
        var l = lens
        if l != nil {
            l!.radius = min(max(l!.radius, ZoomLensParams.radiusRange.lowerBound), ZoomLensParams.radiusRange.upperBound)
            l!.bevel = min(max(l!.bevel, 0), 1); l!.chromaticAberration = min(max(l!.chromaticAberration, 0), 1)
        }
        perform(.setZoomLens(id: id, lens: l))
    }

    public func setZoomScale(id: String, _ scale: Double) {
        perform(.updateZoom(id: id, startNs: nil, endNs: nil, scale: min(max(scale, 1), 6), focusX: nil, focusY: nil))
    }


    public func undo() {
        guard !isClosed, canUndo else { return }
        do { try project.undo(); didEdit(); selection = .none } catch { lastError = error.localizedDescription }
    }
    public func redo() {
        guard !isClosed, canRedo else { return }
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

    public func snapTargets(excludingZoom id: String? = nil, includePlayhead: Bool = true) -> [SnapTarget] {
        Snapping.targets(clips: clips, zooms: zooms, clicks: project.clickTimesNs,
                         playheadNs: playheadNs, durationNs: durationNs, markers: project.markerTimesNs, excludingZoom: id, includePlayhead: includePlayhead)
    }

    /// `includePlayhead: false` while scrubbing — the playhead must not snap to itself.
    public func snapped(_ ns: Int64, excludingZoom id: String? = nil, includePlayhead: Bool = true) -> Int64 {
        let r = Snapping.snap(ns, targets: snapTargets(excludingZoom: id, includePlayhead: includePlayhead), geometry: geometry, enabled: snappingEnabled)
        snapGuideNs = r.target?.ns
        return r.ns
    }

    // MARK: preview refresh (coalesced)

    /// Every edit must reach the preview, but rebuilding it (project snapshot + audio) costs several ms at large
    /// sizes. The first edit of a burst refreshes at once; further edits within `invalidateInterval` collapse into one
    /// trailing refresh, so typing, steppers and repeated clicks do not queue a rebuild each.
    public var invalidateInterval: Duration = .milliseconds(120)
    private var lastInvalidate: ContinuousClock.Instant?
    private var pendingInvalidate: Task<Void, Never>?

    /// `visualOnly`: a known appearance edit (background, padding, corners, shadow, cursor artwork, camera grading) that cannot
    /// change clip mapping or audio, so the player keeps its audio and snapshots. Anything else needs a full rebuild; a burst
    /// that mixes both is refreshed fully.
    func requestPlayerRefresh(visualOnly: Bool = false) {
        if !visualOnly { pendingFullRefresh = true }
        let now = ContinuousClock.now
        if pendingInvalidate == nil, lastInvalidate.map({ now - $0 >= invalidateInterval }) ?? true {
            lastInvalidate = now; refreshPlayer(); return
        }
        guard pendingInvalidate == nil else { return }
        let wait = invalidateInterval - (lastInvalidate.map { now - $0 } ?? .zero)
        pendingInvalidate = Task { [weak self] in
            try? await Task.sleep(for: max(wait, .milliseconds(1)))
            guard let self, !Task.isCancelled else { return }
            pendingInvalidate = nil; lastInvalidate = .now
            if !isClosed { refreshPlayer() }
        }
    }
    private var pendingFullRefresh = false
    private func refreshPlayer() {
        let full = pendingFullRefresh; pendingFullRefresh = false
        if full { player.invalidate() } else { player.invalidateVisuals() }
    }
    /// Test hook: wait for a trailing refresh.
    public func waitForPlayerRefresh() async { await pendingInvalidate?.value }

    // MARK: save

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard autosaveAllowed() else { return }
        let delay = autosaveDelay, expected = revision
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            guard let self, self.revision == expected else { return }     // a newer edit scheduled its own save
            self.saveNow()
        }
    }

    /// Immediate save: used by the debounce and on window close.
    public func saveNow() {
        autosaveTask?.cancel()
        guard !isClosed, saveState != .clean else { return }
        let wasFailing: Bool = { if case .failed = saveState { true } else { false } }()
        do { try project.save(); saveState = .clean }
        catch {
            // The project stays dirty (the revision is untouched); only the first failure interrupts with a message.
            saveState = .failed(error.localizedDescription)
            if !wasFailing { lastError = "Couldn't save: \(error.localizedDescription)" }
            scheduleSaveRetry()
        }
    }

    /// After a failed save the next try comes one autosave delay later without needing another edit. A new edit restarts the
    /// normal timer (and cancels this one); closing, or autosave switched off, ends the retries.
    private func scheduleSaveRetry() {
        guard !isClosed, autosaveAllowed() else { return }
        let delay = autosaveDelay
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            guard let self, !self.isClosed else { return }
            if case .failed = self.saveState { self.saveNow() }
        }
    }

    // MARK: timeline zoom

    /// Native horizontal scrolling owns the offset, so the model only changes the scale.
    public func zoomTimeline(by factor: Double, anchorX: Double = 0) {
        // The visible window stays between 2 s and min(project length, 10 min).
        let maxPPS = timelineViewportWidth / 2
        let minPPS = timelineViewportWidth / max(min(Double(durationNs) / 1e9, 600), 2)
        let target = min(max(geometry.pixelsPerSecond * factor, min(minPPS, maxPPS)), maxPPS)
        geometry = TimelineGeometry(pixelsPerSecond: target)
    }
    public func fitTimeline(width: Double) { geometry = .fitting(durationNs: durationNs, width: width) }
}
