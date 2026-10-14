@preconcurrency import AVFoundation
import SwiftUI
import MetalKit
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
    private var player: AVPlayer?
    private var audioTimeline: AudioTimeline?
    private var audioTask: Task<Void, Never>?
    private var audioGeneration = 0
    private var audioLoading = false
    private var seekGeneration = 0
    private var seeking = false
    private var anchorHost = 0.0
    private var anchorNs: Int64 = 0
    private var metricStart: Double?
    private var lastMetricUpdate = 0.0
    private var frameCount = 0
    private var dropped = 0
    weak var view: MTKView?

    public init(project: any RenderProjectSource) throws {
        self.project = project
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw RenderError.metal("Metal preview unavailable") }
        self.queue = queue; compositor = try FrameCompositor(device: device, project: project)
        rebuildAudio()
    }
    public func play() {
        guard project.durationNs > 0 else { return }
        if currentNs >= project.durationNs { seek(toNs: 0, precise: true) }
        anchorNs = currentNs; anchorHost = ProcessInfo.processInfo.systemUptime
        isPlaying = true
        if !audioLoading && !seeking { player?.play() }
        metricStart = anchorHost; frameCount = 0; dropped = 0
        view?.enableSetNeedsDisplay = false; view?.isPaused = false
    }
    public func pause() {
        updateClock(); isPlaying = false; player?.pause(); view?.isPaused = true; view?.enableSetNeedsDisplay = true
    }
    public func togglePlay() { isPlaying ? pause() : play() }
    public func seek(toNs ns: Int64, precise: Bool) {
        currentNs = max(0, min(ns, max(0, project.durationNs - 1)))
        anchorNs = currentNs; anchorHost = ProcessInfo.processInfo.systemUptime
        seekGeneration += 1
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
        pause(); seek(toNs: currentNs, precise: true); rebuildAudio()
        if playing { play() }
        view?.needsDisplay = true
    }
    private func rebuildAudio() {
        audioTask?.cancel(); audioGeneration += 1; seekGeneration += 1
        let generation = audioGeneration
        player?.pause(); player = nil; audioTimeline = nil; audioLoading = true; seeking = false
        guard project.durationNs > 0 else { audioLoading = false; return }
        let source = project
        audioTask = Task { [weak self] in
            do {
                let snapshot = try source.renderSnapshot()
                let timeline = try await Task.detached(priority: .userInitiated) { try AudioTimeline(project: snapshot, range: 0..<snapshot.durationNs) }.value
                guard !Task.isCancelled, let self, self.audioGeneration == generation else { return }
                self.audioTimeline = timeline
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
                self.audioLoading = false; self.error = error.localizedDescription
                self.pause()
            }
        }
    }
    func updateClock() {
        guard isPlaying, !seeking, !audioLoading else { return }
        let time: Int64
        if let player {
            guard player.currentItem?.status != .failed else { error = player.currentItem?.error?.localizedDescription ?? "Audio playback failed"; isPlaying = false; player.pause(); view?.isPaused = true; return }
            guard player.currentItem?.status == .readyToPlay else { return }
            let seconds = player.currentTime().seconds
            time = seconds.isFinite ? Int64((seconds * 1e9).rounded()) : currentNs
        } else if audioLoading { return }
        else { time = anchorNs + Int64((ProcessInfo.processInfo.systemUptime - anchorHost) * 1e9) }
        if time >= project.durationNs {
            currentNs = max(0, project.durationNs - 1); isPlaying = false; player?.pause(); view?.isPaused = true; view?.enableSetNeedsDisplay = true
        } else { currentNs = max(0, time) }
    }
    func draw(in view: MTKView) {
        updateClock()
        guard let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { dropped += 1; return }
        do {
            let frame = try project.frame(atNs: currentNs)
            try compositor.encode(frame, to: drawable.texture, in: cb)
            cb.present(drawable)
            cb.addCompletedHandler { [weak self] buffer in
                let failed = buffer.status == .error
                let message = buffer.error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if failed { self.error = message ?? "Preview GPU failed"; self.pause(); self.dropped += 1 }
                    else { self.frameCount += 1 }
                    let now = ProcessInfo.processInfo.systemUptime
                    if let start = self.metricStart, now-self.lastMetricUpdate >= 0.5 {
                        self.metrics = PreviewMetrics(renderedFrames: self.frameCount, droppedFrames: self.dropped, elapsedSeconds: now-start)
                        self.lastMetricUpdate = now
                    }
                }
            }
            cb.commit()
        } catch { self.error = error.localizedDescription; pause() }
    }
}

public struct PreviewView: NSViewRepresentable {
    private let player: PreviewPlayer
    public init(player: PreviewPlayer) { self.player = player }
    public func makeCoordinator() -> Coordinator { Coordinator(player: player) }
    public func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: player.compositor.device)
        view.colorPixelFormat = .bgra8Unorm_srgb; view.framebufferOnly = true
        view.enableSetNeedsDisplay = true; view.isPaused = !player.isPlaying; view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator; player.view = view
        return view
    }
    public func updateNSView(_ view: MTKView, context: Context) { view.needsDisplay = true }
    public static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) { coordinator.player.pause(); view.delegate = nil }
    @MainActor public final class Coordinator: NSObject, MTKViewDelegate {
        let player: PreviewPlayer
        init(player: PreviewPlayer) { self.player = player }
        nonisolated public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        nonisolated public func draw(in view: MTKView) { MainActor.assumeIsolated { player.draw(in: view) } }
    }
}
