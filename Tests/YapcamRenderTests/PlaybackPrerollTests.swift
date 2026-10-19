import XCTest
import CoreVideo
@testable import YapcamRender

/// Play after a pause: how long the first played camera frame takes, with and without the preroll.
/// Measures a real camera file when YAPCAM_PREROLL_CAMERA points at one; otherwise the synthetic fixture.
final class PlaybackPrerollTests: XCTestCase {
    func testPrerollMovesTheColdDecoderStartBeforeTheClock() throws {
        let device=try requireRenderDevice()
        let env=ProcessInfo.processInfo.environment["YAPCAM_PREROLL_CAMERA"].flatMap { $0.isEmpty ? nil : $0 }
        let url=env.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/synthetic/basic.yapcam/recording/seg-000/screen.mov")
        var cache: CVMetalTextureCache?
        XCTAssertEqual(CVMetalTextureCacheCreate(nil,nil,device,nil,&cache),kCVReturnSuccess)
        let paused: Int64 = env == nil ? 1_900_000_000 : 13_900_000_000   // just before a keyframe: worst case
        /// `idle`: after 30 s the preview drops every decoder, so Play opens the file cold.
        func firstPlayedFrameMs(preroll: Bool, idle: Bool = false) throws -> (prerollMs: Double, frameMs: Double) {
            let source=try FrameSource(url: url,cache: XCTUnwrap(cache))
            if !idle {
                _=try source.frame(atNs: max(0, paused - 2_000_000_000))
                _=try source.frame(atNs: paused)              // scrub: leaves only a random-access window
            }
            var t=CFAbsoluteTimeGetCurrent()
            if preroll { try source.prepareForPlayback(atNs: paused) }
            let prerollMs=(CFAbsoluteTimeGetCurrent()-t)*1000
            t=CFAbsoluteTimeGetCurrent()
            _=try source.frame(atNs: paused + 33_000_000)     // first frame after Play, clock already running
            _=try source.frame(atNs: paused + 66_000_000)
            return (prerollMs,(CFAbsoluteTimeGetCurrent()-t)*1000)
        }
        let cold=try (0..<3).map { _ in try firstPlayedFrameMs(preroll: false).frameMs }.min()!
        let warm=try (0..<3).map { _ in try firstPlayedFrameMs(preroll: true) }.min { $0.frameMs < $1.frameMs }!
        let idleCold=try (0..<3).map { _ in try firstPlayedFrameMs(preroll: false,idle: true).frameMs }.min()!
        let idleWarm=try (0..<3).map { _ in try firstPlayedFrameMs(preroll: true,idle: true) }.min { $0.frameMs < $1.frameMs }!
        print(String(format: "PREROLL-MEASURE file=%@ afterPause: without=%.1fms with: preroll=%.1fms firstFrames=%.1fms | afterIdle: without=%.1fms with: preroll=%.1fms firstFrames=%.1fms",
                     url.lastPathComponent,cold,warm.prerollMs,warm.frameMs,idleCold,idleWarm.prerollMs,idleWarm.frameMs))
        XCTAssertLessThanOrEqual(warm.frameMs,cold+1)
        XCTAssertLessThanOrEqual(idleWarm.frameMs,idleCold+1)
    }
}
