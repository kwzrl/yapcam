@preconcurrency import AVFoundation
import SwiftUI
@preconcurrency import MetalKit
import Combine

public struct PreviewMetrics: Sendable {
    public var renderedFrames: Int = 0
    public var droppedFrames: Int = 0
    public var elapsedSeconds: Double = 0
    public var framesPerSecond: Double { Double(renderedFrames) / max(elapsedSeconds, 0.000_001) }
}

struct PreviewSubmissionMetrics {
    var busy = 0
    var unavailableDrawable = 0
    var failed = 0
}

/// Internal host-benchmark diagnostics; no playback policy or public API change.
struct PreviewAudioStartupDiagnostics: Encodable {
    let phase: String
    let loading: Bool
    let seeking: Bool
    let playbackRequested: Bool
    let playerStatus: Int?
    let itemStatus: Int?
    let timeControlStatus: Int?
    let waitingReason: String?
    let rate: Float
    let seconds: Double?
    let failure: String?
}

@MainActor public final class PreviewPlayer: ObservableObject {
    @Published public private(set) var currentNs: Int64 = 0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var error: String?
    @Published public private(set) var metrics = PreviewMetrics()
    @Published public private(set) var speechEnhancementSettings: SpeechEnhancementSettings?
    @Published public private(set) var motionBlurEnabled = true
    @Published public private(set) var previewSettings = PreviewSettings()
    public var speechEnhancementReports: [SpeechEnhancementReport] { audioTimeline?.speechReports ?? [] }
    let project: any RenderProjectSource
    private(set) var renderProject: any RenderProjectSource
    let compositor: FrameCompositor
    let queue: MTLCommandQueue
    private var observation: ProjectObservation?
    private var player: AVPlayer?
    private var audioTimeline: AudioTimeline?
    private var audioTask: Task<Void, Never>?
    private(set) var audioGeneration = 0
    private var audioLoading = false
    private var audioPreparationFailed = false
    private var seekGeneration = 0
    private var seeking = false
    private var atEnd = false
    private var anchorHost = 0.0
    private var anchorNs: Int64 = 0
    private var metricStart: Double?
    private var lastMetricUpdate = 0.0
    private var frameCount = 0
    private var dropped = 0
    private let renderQueue = PreviewRenderQueue()
    private var submissions = PreviewSubmissionMetrics()
    private var redrawRevision = 0
    weak var view: MTKView?

    public init(project: any RenderProjectSource,speechEnhancement: SpeechEnhancementSettings? = nil) throws {
        try speechEnhancement?.validate()
        speechEnhancementSettings=speechEnhancement
        self.project = project
        renderProject = try project.renderSnapshot()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw RenderError.metal("Metal preview unavailable") }
        self.queue = queue; compositor = try FrameCompositor(device: device, project: project)
        rebuildAudio()
    }
    func observeChanges(name: Notification.Name,object: AnyObject) {
        observation=ProjectObservation(name: name,object: object) { [weak self] in
            Task { @MainActor [weak self] in self?.invalidate() }
        }
    }
    public func play() {
        guard !isPlaying, !audioPreparationFailed, project.durationNs > 0 else { return }
        if atEnd || currentNs >= project.durationNs { seek(toNs: 0, precise: true) }
        anchorNs = currentNs; anchorHost = ProcessInfo.processInfo.systemUptime
        isPlaying = true
        if !audioLoading && !seeking { player?.play() }
        metricStart = anchorHost; frameCount = 0; dropped = 0
        submissions = PreviewSubmissionMetrics()
        metrics = PreviewMetrics(); lastMetricUpdate = anchorHost
        view?.enableSetNeedsDisplay = false; view?.isPaused = false
    }
    public func pause() {
        updateClock(); isPlaying = false; player?.pause(); view?.isPaused = true; view?.enableSetNeedsDisplay = true
        finishMetrics()
    }
    public func togglePlay() { isPlaying ? pause() : play() }
    public func seek(toNs ns: Int64, precise: Bool) {
        atEnd = ns >= project.durationNs
        currentNs = max(0, min(ns, max(0, project.durationNs - 1)))
        anchorNs = currentNs; anchorHost = ProcessInfo.processInfo.systemUptime
        seekGeneration += 1; redrawRevision += 1
        let tolerance = precise ? CMTime.zero : CMTime(value: 1, timescale: 30)
        if let player {
            seeking = true
            let generation = seekGeneration
            player.pause()
            player.seek(to: CMTime(value: currentNs, timescale: 1_000_000_000), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
                Task { @MainActor [weak self] in
                    guard let self, self.seekGeneration == generation else { return }
                    self.seeking = false
                    if finished && self.isPlaying && !self.audioLoading { player.play() }
                    self.view?.needsDisplay = true
                }
            }
        }
        view?.needsDisplay = true
    }
    public func setSpeechEnhancement(_ settings: SpeechEnhancementSettings?) throws {
        try settings?.validate()
        guard settings != speechEnhancementSettings else { return }
        speechEnhancementSettings=settings
        invalidate()
    }
    public func setMotionBlurEnabled(_ enabled: Bool) {
        guard enabled != motionBlurEnabled else { return }
        motionBlurEnabled=enabled; compositor.setMotionBlurEnabled(enabled)
        redrawRevision += 1; view?.needsDisplay=true
    }
    public func setPreviewSettings(_ settings: PreviewSettings) throws {
        try settings.validate()
        guard settings != previewSettings else { return }
        try compositor.setScreenQualityOverride(settings.screenQuality)
        let rateChanged=settings.playbackRate != previewSettings.playbackRate
        if rateChanged {
            updateClock() // Finish the old rate before changing the host-clock anchor.
            anchorNs=currentNs; anchorHost=ProcessInfo.processInfo.systemUptime
        }
        previewSettings=settings
        if rateChanged {
            player?.defaultRate=Float(settings.playbackRate)
            if isPlaying && !audioLoading && !seeking { player?.play() }
        }
        if let view { applyPreviewSize(to: view); view.needsDisplay=true }
        redrawRevision += 1
    }
    func applyPreviewSize(to view: MTKView) {
        let automatic=previewSettings.maximumHeight == nil && previewSettings.resolution == .full
        view.autoResizeDrawable=automatic
        let backing=view.convertToBacking(view.bounds).size
        guard let size=try? previewSettings.drawableSize(forBackingSize: backing), size != view.drawableSize else { return }
        view.drawableSize=size
    }
    /// Refresh after an appearance-only edit. The caller must know that clip
    /// mapping, audio, source files and speech settings are unchanged; otherwise
    /// use invalidate(). Snapshot failure leaves the current generation intact.
    public func invalidateVisuals() throws {
        let snapshot=try project.renderSnapshot()
        guard snapshot.durationNs == renderProject.durationNs, !audioPreparationFailed else {
            invalidate(); return
        }
        renderProject=snapshot
        compositor.invalidateVisualAssets()
        redrawRevision += 1; view?.needsDisplay=true
    }
    public func invalidate() {
        // Rebuild the same clip mapping after edits; keep the current timeline location.
        let playing = isPlaying
        pause()
        do { renderProject = try project.renderSnapshot() }
        catch { self.error=error.localizedDescription; audioPreparationFailed=true; return }
        compositor.invalidateSources()
        seek(toNs: currentNs, precise: true); rebuildAudio()
        if playing { play() }
        view?.needsDisplay = true
    }
    private func rebuildAudio() {
        audioTask?.cancel(); audioGeneration += 1; seekGeneration += 1
        let generation = audioGeneration
        player?.pause(); player = nil; audioTimeline = nil; audioLoading = true; audioPreparationFailed = false; seeking = false
        guard project.durationNs > 0 else { audioLoading = false; return }
        let source = renderProject, settings=speechEnhancementSettings
        audioTask = Task { [weak self] in
            do {
                let timeline=try await AudioTimeline.prepare(project: source,range: 0..<source.durationNs,speechEnhancement: settings)
                defer { withExtendedLifetime(timeline) {} }
                guard !Task.isCancelled, let self, self.audioGeneration == generation else { return }
                self.audioTimeline = timeline; self.error = nil
                if timeline.hasAudio {
                    let item = AVPlayerItem(asset: timeline.composition); item.audioMix = timeline.mix; item.audioTimePitchAlgorithm = .spectral
                    let player = AVPlayer(playerItem: item)
                    player.defaultRate=Float(self.previewSettings.playbackRate); self.player = player
                    let time = CMTime(value: self.currentNs, timescale: 1_000_000_000)
                    await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                    guard !Task.isCancelled, self.audioGeneration == generation else { return }
                }
                self.audioLoading = false
                self.anchorNs = self.currentNs; self.anchorHost = ProcessInfo.processInfo.systemUptime
                // A user seek can supersede the initial audio positioning while it awaits.
                if self.isPlaying && !self.seeking { self.player?.play() }
            } catch {
                guard let self, self.audioGeneration == generation else { return }
                self.audioLoading = false; self.audioPreparationFailed = true; self.error = error.localizedDescription
                self.pause()
            }
        }
    }
    func updateClock() {
        guard isPlaying, !seeking, !audioLoading else { return }
        let time: Int64
        if let player {
            guard player.currentItem?.status != .failed else { error = player.currentItem?.error?.localizedDescription ?? "Audio playback failed"; isPlaying = false; player.pause(); view?.isPaused = true; finishMetrics(); return }
            guard player.currentItem?.status == .readyToPlay else { return }
            let seconds = player.currentTime().seconds
            time = seconds.isFinite ? Int64((seconds * 1e9).rounded()) : currentNs
        } else if audioLoading { return }
        else { time = PreviewClock.time(anchorNs: anchorNs,elapsed: ProcessInfo.processInfo.systemUptime-anchorHost,rate: previewSettings.playbackRate,durationNs: project.durationNs) }
        if time >= project.durationNs {
            currentNs = max(0, project.durationNs - 1); atEnd = true; isPlaying = false; player?.pause(); view?.isPaused = true; view?.enableSetNeedsDisplay = true
            finishMetrics()
        } else { currentNs = max(0, time) }
    }
    // Exact interval snapshots for host benchmarks; published metrics are throttled.
    func metricSnapshot() -> PreviewMetrics {
        guard let start=metricStart else { return metrics }
        return PreviewMetrics(renderedFrames: frameCount,droppedFrames: dropped,elapsedSeconds: ProcessInfo.processInfo.systemUptime-start)
    }
    var audioClockReady: Bool { !audioLoading && !seeking && player?.currentItem?.status == .readyToPlay }
    var audioClockSeconds: Double? { player?.currentTime().seconds }
    var audioClockRate: Float { player?.rate ?? 0 }
    var audioStartupDiagnostics: PreviewAudioStartupDiagnostics {
        let failure=error ?? player?.currentItem?.error?.localizedDescription ?? player?.error?.localizedDescription
        let phase: String
        if failure != nil { phase="failed" }
        else if audioLoading { phase=audioTimeline == nil ? "preparing_composition" : "initial_seek" }
        else if seeking { phase="seeking" }
        else if player == nil { phase="silent_host_clock" }
        else if !audioClockReady { phase="waiting_for_item" }
        else { phase=audioClockRate==0 ? "ready_paused" : "playing" }
        return .init(phase: phase,loading: audioLoading,seeking: seeking,playbackRequested: isPlaying,
                     playerStatus: player?.status.rawValue,itemStatus: player?.currentItem?.status.rawValue,
                     timeControlStatus: player?.timeControlStatus.rawValue,waitingReason: player?.reasonForWaitingToPlay?.rawValue,
                     rate: audioClockRate,seconds: audioClockSeconds.flatMap { $0.isFinite ? $0 : nil },failure: failure)
    }
    func submissionSnapshot() -> PreviewSubmissionMetrics { submissions }
    private func finishMetrics() {
        if let start = metricStart {
            metrics = PreviewMetrics(renderedFrames: frameCount,droppedFrames: dropped,elapsedSeconds: ProcessInfo.processInfo.systemUptime-start)
            metricStart = nil
        }
    }
    func draw(in view: MTKView) {
        updateClock()
        guard let ticket = renderQueue.reserve() else { dropped += 1; submissions.busy += 1; return }
        guard let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else {
            ticket.finish(); dropped += 1; submissions.unavailableDrawable += 1; return
        }
        let ns = currentNs, revision = redrawRevision
        let source = renderProject, compositor = compositor
        let resources = PreviewDrawResources(drawable: drawable,commandBuffer: cb)
        renderQueue.submit(ticket) { [weak self] ticket in
            guard let receiver = self else { ticket.finish(); return }
            do {
                let frame = try source.frame(atNs: ns)
                try compositor.encode(frame,from: source,to: resources.drawable.texture,in: resources.commandBuffer)
                resources.commandBuffer.present(resources.drawable)
                resources.commandBuffer.addCompletedHandler { buffer in
                    // Return admission before scheduling UI bookkeeping. A busy
                    // main actor must not hold the renderer's next frame hostage.
                    ticket.finish()
                    let message = buffer.status == .error ? (buffer.error?.localizedDescription ?? "Preview GPU failed") : nil
                    Task { @MainActor in receiver.drawFinished(ns: ns,revision: revision,error: message) }
                }
                resources.commandBuffer.commit()
            } catch {
                ticket.finish()
                let message=error.localizedDescription
                Task { @MainActor in receiver.drawFinished(ns: ns,revision: revision,error: message) }
            }
        }
    }
    private func drawFinished(ns: Int64,revision: Int,error: String?) {
        if let error { self.error = error; dropped += 1; submissions.failed += 1; pause() }
        else { frameCount += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        if let start = metricStart, now-lastMetricUpdate >= 0.5 {
            metrics = PreviewMetrics(renderedFrames: frameCount,droppedFrames: dropped,elapsedSeconds: now-start)
            lastMetricUpdate = now
        }
        if error == nil && (!isPlaying && ns != currentNs || revision != redrawRevision) { view?.needsDisplay = true }
    }

}

public struct PreviewView: NSViewRepresentable {
    private let player: PreviewPlayer
    public init(player: PreviewPlayer) { self.player = player }
    public func makeCoordinator() -> Coordinator { Coordinator(player: player) }
    public func makeNSView(context: Context) -> MTKView {
        let view = PreviewMetalView(frame: .zero, device: player.compositor.device)
        view.player=player
        view.colorPixelFormat = .bgra8Unorm_srgb; view.framebufferOnly = true
        view.enableSetNeedsDisplay = !player.isPlaying; view.isPaused = !player.isPlaying; view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator; player.view = view; player.applyPreviewSize(to: view)
        return view
    }
    public func updateNSView(_ view: MTKView, context: Context) { player.applyPreviewSize(to: view); view.needsDisplay = true }
    public static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) { coordinator.player.pause(); view.delegate = nil }
    @MainActor public final class Coordinator: NSObject, MTKViewDelegate {
        let player: PreviewPlayer
        init(player: PreviewPlayer) { self.player = player }
        nonisolated public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        nonisolated public func draw(in view: MTKView) {
            if Thread.isMainThread { MainActor.assumeIsolated { player.draw(in: view) } }
            else {
                let reference=PreviewViewReference(view)
                Task { @MainActor [weak self] in if let view=reference.view { self?.player.draw(in: view) } }
            }
        }
    }
}

/// Resize notifications remain necessary when MTKView automatic sizing is disabled.
@MainActor final class PreviewMetalView: MTKView {
    weak var player: PreviewPlayer?
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); player?.applyPreviewSize(to: self)
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties(); player?.applyPreviewSize(to: self)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); player?.applyPreviewSize(to: self)
    }
}

private final class ProjectObservation: @unchecked Sendable {
    let token: NSObjectProtocol
    init(name: Notification.Name,object: AnyObject,callback: @escaping @Sendable () -> Void) {
        token=NotificationCenter.default.addObserver(forName: name,object: object,queue: nil) { _ in callback() }
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}

private final class PreviewDrawResources: @unchecked Sendable {
    let drawable: CAMetalDrawable
    let commandBuffer: MTLCommandBuffer
    init(drawable: CAMetalDrawable,commandBuffer: MTLCommandBuffer) { self.drawable=drawable; self.commandBuffer=commandBuffer }
}

private final class PreviewViewReference: @unchecked Sendable {
    weak var view: MTKView?
    init(_ view: MTKView) { self.view=view }
}
