import XCTest
import AppKit
import MetalKit
@testable import YapcamRender

final class AudioPreviewPerformanceTests: XCTestCase {
    @MainActor func testAudioPreview1080And4KReportsFPSDropsClockAndRSS() async throws {
        try RenderM3Artifacts.requireLongRun()
        let device=try requireRenderDevice()
        _ = NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-m3-audio-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let seconds=30.0
        let source=try LongRunSource(package: root,durationSeconds: 45,pulses: [],decodedVideo: true)
        for height in [1080,2160] {
            let player=try PreviewPlayer(project: source)
            let view=MTKView(frame: NSRect(x: 0,y: 0,width: 640,height: 360),device: device)
            let delegate=PreviewView.Coordinator(player: player)
            view.colorPixelFormat = .bgra8Unorm_srgb; view.framebufferOnly=true
            view.autoResizeDrawable=false; view.drawableSize=CGSize(width: height*16/9,height: height)
            view.preferredFramesPerSecond=60; view.delegate=delegate; player.view=view
            let window=NSWindow(contentRect: view.frame,styleMask: [.titled],backing: .buffered,defer: false)
            window.isReleasedWhenClosed=false; window.contentView=view; window.orderFront(nil)
            defer { player.pause(); view.delegate=nil; window.close() }
            player.play()
            let deadline=ContinuousClock.now.advanced(by: .seconds(30))
            while !player.audioClockReady || player.audioClockRate==0 || player.currentNs<500_000_000 {
                if let error=player.error { throw RenderError.verification(error) }
                guard ContinuousClock.now<deadline else { throw RenderError.verification("Audio preview clock never became ready") }
                try await Task.sleep(for: .milliseconds(25))
            }
            try await Task.sleep(for: .seconds(2)) // Decode/shader/audio warm-up.
            let initial=player.metricSnapshot()
            let audioStart=try XCTUnwrap(player.audioClockSeconds)
            let clockStart=player.currentNs
            let monitor=try RenderMemoryMonitor()
            try await Task.sleep(for: .seconds(seconds))
            let audioEnd=try XCTUnwrap(player.audioClockSeconds)
            let clockEnd=player.currentNs
            let rate=player.audioClockRate, ready=player.audioClockReady
            player.pause()
            let final=player.metricSnapshot(), memory=try monitor.finish()
            let elapsed=final.elapsedSeconds-initial.elapsedSeconds
            let frames=final.renderedFrames-initial.renderedFrames
            let dropped=final.droppedFrames-initial.droppedFrames
            let nominal=Int((elapsed*60).rounded(.down))
            let values: [String: Any]=[
                "source":"looping_320x200_decoded_video_zoom_shadow_with_streamed_pcm_audio",
                "device":device.name,"audio":true,"height":height,"width":height*16/9,
                "nominal_refresh_hz":60,"wall_seconds":elapsed,"completed_frames":frames,
                "fps":Double(frames)/max(elapsed,0.000_001),
                "dropped_submissions":dropped,"missed_nominal_refresh_opportunities":max(0,nominal-frames),
                "audio_clock_advance_s":audioEnd-audioStart,"audio_ready":ready,"audio_rate":rate,
                "timeline_advance_s":Double(clockEnd-clockStart)/1e9,
                "sampled_peak_rss_bytes":memory.peak,"process_highwater_rss_bytes":memory.processPeak,
                "drop_definition":"dropped_submissions counts busy GPU/no drawable; nominal misses also include callbacks never delivered; do not add the counts",
                "resolution_scope":"1080p/4K drawable output; 320x200 source decode; visible 640x360 window",
                "rss_scope":"measured interval after warm-up; process highwater spans fixture generation and both resolutions"
            ]
            try RenderM3Artifacts.write("audio-preview-\(height)",values: values,memory: memory)
            XCTAssertNil(player.error)
            XCTAssertTrue(ready); XCTAssertGreaterThan(rate,0)
            XCTAssertGreaterThan(frames,0)
            XCTAssertGreaterThan(audioEnd-audioStart,seconds*0.9,"Benchmark must exercise a running audio clock")
            XCTAssertEqual(Int(view.drawableSize.height),height)
            // Clock drift is reported separately from render drops; both use the
            // same AVPlayer-backed clock, with one drawable interval of tolerance.
            XCTAssertEqual(Double(clockEnd-clockStart)/1e9,audioEnd-audioStart,accuracy: 0.1)
        }
    }
}
