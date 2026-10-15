import XCTest
import MetalKit
@testable import YapcamRender

final class PreviewSettingsTests: XCTestCase {
    func testPixelCapsResolutionAndInvalidRequests() throws {
        let backing=CGSize(width: 3840,height: 2160)
        XCTAssertEqual(try PreviewSettings().drawableSize(forBackingSize: backing),backing)
        for height in PreviewSettings.maximumHeights {
            for resolution in PreviewSettings.Resolution.allCases {
                let settings=PreviewSettings(maximumHeight: height,resolution: resolution)
                let result=try settings.drawableSize(forBackingSize: backing)
                XCTAssertEqual(result.height,floor(Double(height)*resolution.rawValue))
                XCTAssertEqual(result.width,floor(3840*Double(height)/2160*resolution.rawValue))
            }
        }
        let small=CGSize(width: 300,height: 500)
        XCTAssertEqual(try PreviewSettings(maximumHeight: 2160).drawableSize(forBackingSize: small),small)
        XCTAssertEqual(try PreviewSettings(resolution: .quarter).drawableSize(forBackingSize: small),CGSize(width: 75,height: 125))
        XCTAssertEqual(try PreviewSettings(resolution: .quarter).drawableSize(forBackingSize: CGSize(width: 1,height: 1)),CGSize(width: 1,height: 1))
        for rate in PreviewSettings.playbackRates { XCTAssertNoThrow(try PreviewSettings(playbackRate: rate).validate()) }
        for rate in [Double.nan,.infinity,-1,0,0.1,1.5,9] { XCTAssertThrowsError(try PreviewSettings(playbackRate: rate).validate()) }
        for height in [-1,0,540,Int.max] { XCTAssertThrowsError(try PreviewSettings(maximumHeight: height).validate()) }
        for size in [CGSize.zero,CGSize(width: -1,height: 100),CGSize(width: CGFloat.infinity,height: 100)] {
            XCTAssertThrowsError(try PreviewSettings().drawableSize(forBackingSize: size))
        }
    }

    func testHostClockRateChangesAreContinuousAndSaturateAtEnd() {
        let duration: Int64=10_000_000_000
        for rate in PreviewSettings.playbackRates {
            XCTAssertEqual(PreviewClock.time(anchorNs: 500_000_000,elapsed: 0.25,rate: rate,durationNs: duration),500_000_000+Int64(rate*250_000_000))
        }
        let before=PreviewClock.time(anchorNs: 1_000_000_000,elapsed: 2,rate: 0.5,durationNs: duration)
        XCTAssertEqual(before,2_000_000_000)
        XCTAssertEqual(PreviewClock.time(anchorNs: before,elapsed: 0,rate: 8,durationNs: duration),before)
        XCTAssertEqual(PreviewClock.time(anchorNs: before,elapsed: 0.25,rate: 8,durationNs: duration),4_000_000_000)
        XCTAssertEqual(PreviewClock.time(anchorNs: before,elapsed: 100,rate: 8,durationNs: duration),duration)
        XCTAssertEqual(PreviewClock.time(anchorNs: 0,elapsed: Double.greatestFiniteMagnitude,rate: 8,durationNs: .max),.max)
        XCTAssertEqual(PreviewClock.time(anchorNs: 100,elapsed: -1,rate: 1,durationNs: duration),100)
    }

    @MainActor func testControlsResizeBackingRestoreDefaultsAndKeepSnapshotOnHost() throws {
        let device=try requireRenderDevice()
        let source=CountingSource()
        let player=try PreviewPlayer(project: source)
        defer { player.pause() }
        let view=PreviewMetalView(frame: NSRect(x: 0,y: 0,width: 1920,height: 1080),device: device)
        view.isPaused=true; view.player=player; player.view=view
        let selected=PreviewSettings(maximumHeight: 480,resolution: .half,playbackRate: 2)
        try player.setPreviewSettings(selected)
        XCTAssertFalse(view.autoResizeDrawable)
        XCTAssertEqual(view.drawableSize,try selected.drawableSize(forBackingSize: view.convertToBacking(view.bounds).size))
        view.setFrameSize(NSSize(width: 300,height: 300))
        XCTAssertEqual(view.drawableSize,try selected.drawableSize(forBackingSize: view.convertToBacking(view.bounds).size))
        XCTAssertThrowsError(try player.setPreviewSettings(.init(playbackRate: 0)))
        XCTAssertEqual(player.previewSettings,selected)
        XCTAssertFalse(player.isPlaying,"Changing settings while paused must not start audio/playback")
        XCTAssertEqual(player.currentNs,0)
        try player.setPreviewSettings(.init())
        XCTAssertTrue(view.autoResizeDrawable)
        XCTAssertEqual(view.drawableSize,view.convertToBacking(view.bounds).size)
        XCTAssertEqual(source.snapshotCount,1,"Local preview controls must not rebuild the project snapshot")
    }

    @MainActor func testAudioRateSurvivesLoadingSeekPauseAndRebuildOnHost() async throws {
        _ = try requireRenderDevice()
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let source=TestSource(package: fixture,duration: 2_000_000_000,clips: [.init(srcStartNs: 0,srcEndNs: 2_000_000_000)])
        let player=try PreviewPlayer(project: source)
        defer { player.pause() }
        func waitForAudio(rate: Float) async throws {
            let deadline=ContinuousClock.now.advanced(by: .seconds(10))
            while !player.audioClockReady || abs(player.audioClockRate-rate)>0.001 {
                if let error=player.error { throw RenderError.verification(error) }
                guard ContinuousClock.now<deadline else { throw RenderError.verification("Preview audio failed to resume at selected rate") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try player.setPreviewSettings(.init(playbackRate: 0.5))
        player.play(); try await waitForAudio(rate: 0.5)
        try player.setPreviewSettings(.init(playbackRate: 2))
        try await waitForAudio(rate: 2)
        player.seek(toNs: 500_000_000,precise: true)
        try await waitForAudio(rate: 2)
        player.pause()
        try player.setPreviewSettings(.init(playbackRate: 8))
        XCTAssertEqual(player.audioClockRate,0)
        XCTAssertFalse(player.isPlaying)
        player.invalidate(); player.play()
        try await waitForAudio(rate: 8)
        XCTAssertEqual(player.previewSettings.playbackRate,8)
    }
}

private final class CountingSource: RenderProjectSource, @unchecked Sendable {
    let packageURL=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
    let durationNs: Int64=2_000_000_000
    private let lock=NSLock()
    private var snapshots=0
    var snapshotCount: Int { lock.withLock { snapshots } }
    func renderSnapshot() throws -> any RenderProjectSource { lock.withLock { snapshots += 1 }; return self }
    func renderClips() throws -> [RenderClip] { [] }
    func renderBackgroundAsset(index: UInt32) throws -> URL { throw RenderError.missingMedia("No background in preview-control fixture") }
    func frame(atNs: Int64) throws -> YcFrame {
        var frame=YcFrame(); frame.tl_ns=atNs; frame.canvas_w=320; frame.canvas_h=200; frame.background_color=(0,0,0,1); frame.click_progress = -1
        return frame
    }
}
