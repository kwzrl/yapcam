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

@MainActor public final class PreviewPlayer: ObservableObject {
    @Published public private(set) var currentNs: Int64 = 0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var error: String?
    @Published public private(set) var metrics = PreviewMetrics()
    let project: any RenderProjectSource
    let compositor: FrameCompositor
    let queue: MTLCommandQueue
    private var observation: ProjectObservation?
    private var player: AVPlayer?
    private var audioTimeline: AudioTimeline?
    private var audioTask: Task<Void, Never>?
    private var audioGeneration = 0
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
    private var drawPending = false
    private var redrawRevision = 0
    weak var view: MTKView?

    public init(project: any RenderProjectSource) throws {
        self.project = project
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
                    if finished && self.isPlaying { player.play() }
                    self.view?.needsDisplay = true
                }
            }
        }
        view?.needsDisplay = true
    }
    public func invalidate() {
        // Rebuild the same clip mapping after edits; keep the current timeline location.
        let playing = isPlaying
        compositor.invalidateSources()
        pause(); seek(toNs: currentNs, precise: true); rebuildAudio()
        if playing { play() }
        view?.needsDisplay = true
    }
    private func rebuildAudio() {
        audioTask?.cancel(); audioGeneration += 1; seekGeneration += 1
        let generation = audioGeneration
        player?.pause(); player = nil; audioTimeline = nil; audioLoading = true; audioPreparationFailed = false; seeking = false
        guard project.durationNs > 0 else { audioLoading = false; return }
        let source = project
        audioTask = Task { [weak self] in
            do {
                let snapshot = try source.renderSnapshot()
                let timeline = try await Task.detached(priority: .userInitiated) { try AudioTimeline(project: snapshot, range: 0..<snapshot.durationNs) }.value
                guard !Task.isCancelled, let self, self.audioGeneration == generation else { return }
                self.audioTimeline = timeline; self.error = nil
                if timeline.hasAudio {
                    let item = AVPlayerItem(asset: timeline.composition); item.audioMix = timeline.mix; item.audioTimePitchAlgorithm = .spectral
                    let player = AVPlayer(playerItem: item); self.player = player
                    let time = CMTime(value: self.currentNs, timescale: 1_000_000_000)
                    await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                    guard !Task.isCancelled, self.audioGeneration == generation else { return }
                    if self.isPlaying { player.play() }
                }
                self.audioLoading = false
                self.anchorNs = self.currentNs; self.anchorHost = ProcessInfo.processInfo.systemUptime
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
        else { time = anchorNs + Int64((ProcessInfo.processInfo.systemUptime - anchorHost) * 1e9) }
        if time >= project.durationNs {
            currentNs = max(0, project.durationNs - 1); atEnd = true; isPlaying = false; player?.pause(); view?.isPaused = true; view?.enableSetNeedsDisplay = true
            finishMetrics()
        } else { currentNs = max(0, time) }
    }
    private func finishMetrics() {
        if let start = metricStart {
            metrics = PreviewMetrics(renderedFrames: frameCount,droppedFrames: dropped,elapsedSeconds: ProcessInfo.processInfo.systemUptime-start)
            metricStart = nil
        }
    }
    func draw(in view: MTKView) {
        updateClock()
        guard !drawPending else { dropped += 1; return }
        guard let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { dropped += 1; return }
        drawPending = true
        let ns = currentNs, revision = redrawRevision
        let source = project, compositor = compositor
        let resources = PreviewDrawResources(drawable: drawable,commandBuffer: cb)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let receiver = self else { return }
            do {
                let frame = try source.frame(atNs: ns)
                try compositor.encode(frame,to: resources.drawable.texture,in: resources.commandBuffer)
                resources.commandBuffer.present(resources.drawable)
                resources.commandBuffer.addCompletedHandler { buffer in
                    let message = buffer.status == .error ? (buffer.error?.localizedDescription ?? "Preview GPU failed") : nil
                    Task { @MainActor in receiver.drawFinished(ns: ns,revision: revision,error: message) }
                }
                resources.commandBuffer.commit()
            } catch {
                await receiver.drawFinished(ns: ns,revision: revision,error: error.localizedDescription)
            }
        }
    }
    private func drawFinished(ns: Int64,revision: Int,error: String?) {
        drawPending = false
        if let error { self.error = error; dropped += 1; pause() }
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
        let view = MTKView(frame: .zero, device: player.compositor.device)
        view.colorPixelFormat = .bgra8Unorm_srgb; view.framebufferOnly = true
        view.enableSetNeedsDisplay = !player.isPlaying; view.isPaused = !player.isPlaying; view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator; player.view = view
        return view
    }
    public func updateNSView(_ view: MTKView, context: Context) { view.needsDisplay = true }
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
