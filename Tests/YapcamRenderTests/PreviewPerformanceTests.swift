import XCTest
import AppKit
import MetalKit
@testable import YapcamRender

/// Shared decoded-video workload for preview/export; fixture is intentionally small.
/// This measures output resolution cost, not native 4K decode throughput or mixed audio.
func renderPerformanceSource() -> TestSource {
    let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
    return TestSource(package: fixture,duration: 5_000_000_000) { ns in
        var frame=YcFrame(); frame.tl_ns=ns; frame.canvas_w=1920; frame.canvas_h=1080
        frame.background_kind=1; frame.background_color=(0.15,0.2,0.4,1); frame.background_color2=(0.5,0.3,0.2,1)
        frame.screen.present=1; frame.screen.segment=ns<3_000_000_000 ? 0 : 1
        frame.screen.src_ns=ns; frame.screen.file_ns=ns<3_000_000_000 ? ns : ns-3_000_000_000
        frame.screen_dest = .init(x: 192,y: 60,w: 1536,h: 960)
        let zoom=1-0.25*(sin(Double(ns)/1e9*Double.pi)*0.5+0.5)
        frame.screen_crop = .init(x: (1-zoom)/2,y: (1-zoom)/2,w: zoom,h: zoom)
        frame.screen_corner_radius=24; frame.shadow_radius=32; frame.shadow_opacity=0.25
        frame.motion_blur=0.3; frame.click_progress = -1
        return frame
    }
}

final class PreviewPerformanceTests: XCTestCase {
    @MainActor func testLivePreviewPerformance1080And4K() async throws {
        _ = try requireRenderDevice()
        let environment=ProcessInfo.processInfo.environment
        guard environment["YAPCAM_RENDER_LIVE_PREVIEW"]=="1" || environment["YAPCAM_REQUIRE_RENDER_HARDWARE"]=="1" else {
            throw XCTSkip("Set YAPCAM_RENDER_LIVE_PREVIEW=1 to measure a visible MTKView in the host session")
        }
        _ = NSApplication.shared
        for height in [1080,2160] {
            let player=try PreviewPlayer(project: renderPerformanceSource())
            let view=MTKView(frame: NSRect(x: 0,y: 0,width: 640,height: 360),device: player.compositor.device)
            let delegate=PreviewView.Coordinator(player: player)
            view.colorPixelFormat = .bgra8Unorm_srgb; view.framebufferOnly=true
            view.autoResizeDrawable=false; view.drawableSize=CGSize(width: height*16/9,height: height)
            view.preferredFramesPerSecond=60; view.delegate=delegate; player.view=view
            let window=NSWindow(contentRect: view.frame,styleMask: [.titled],backing: .buffered,defer: false)
            window.isReleasedWhenClosed=false; window.contentView=view; window.orderFront(nil)
            defer { player.pause(); view.delegate=nil; window.close() }
            // Warm up native decode and shader caches, then start a fresh metric interval.
            player.play()
            try await Task.sleep(for: .seconds(1))
            player.pause(); player.seek(toNs: 0,precise: true)
            player.play()
            try await Task.sleep(for: .seconds(2))
            player.pause()
            let result=player.metrics
            XCTAssertNil(player.error)
            XCTAssertGreaterThan(result.renderedFrames,0,"No GPU frames completed in the live window")
            XCTAssertGreaterThan(player.currentNs,0,"The preview clock did not advance")
            XCTAssertEqual(Int(view.drawableSize.height),height)
            print("RENDER_PREVIEW_BENCHMARK source=synthetic_decoded_video audio=false height=\(height) frames=\(result.renderedFrames) dropped=\(result.droppedFrames) elapsed_s=\(result.elapsedSeconds) fps=\(result.framesPerSecond)")
        }
    }
}
