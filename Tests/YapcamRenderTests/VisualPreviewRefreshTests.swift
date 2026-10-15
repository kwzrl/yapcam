import XCTest
import Metal
@testable import YapcamRender

final class VisualPreviewRefreshTests: XCTestCase {
    @MainActor func testAppearanceRefreshChangesPixelsRetainsAudioAndDecoderAndFallsBackForTimingOnHost() throws {
        let device=try requireRenderDevice(), source=AppearanceSource()
        let player=try PreviewPlayer(project: source)
        defer { player.pause() }
        let queue=try XCTUnwrap(device.makeCommandQueue())
        let target=try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,width: 320,height: 200,mipmapped: false)))
        func pixels() throws -> [UInt8] {
            let frozen=player.renderProject, frame=try frozen.frame(atNs: player.currentNs)
            let cb=try XCTUnwrap(queue.makeCommandBuffer())
            try player.compositor.encode(frame,from: frozen,to: target,in: cb)
            cb.commit(); cb.waitUntilCompleted()
            XCTAssertEqual(cb.status,.completed,cb.error?.localizedDescription ?? "")
            var bytes=[UInt8](repeating: 0,count: 320*200*4)
            target.getBytes(&bytes,bytesPerRow: 320*4,from: MTLRegionMake2D(0,0,320,200),mipmapLevel: 0)
            return bytes
        }
        player.seek(toNs: 400_000_000,precise: true)
        let oldSnapshot=player.renderProject, original=try pixels()
        let audioGeneration=player.audioGeneration, opens=player.compositor.sourceOpenCount
        XCTAssertEqual(opens,1)
        XCTAssertEqual(Double(original[0]),0,accuracy: 1)
        source.setWhite(true)
        try player.invalidateVisuals()
        let changed=try pixels()
        XCTAssertEqual(Double(changed[0]),255,accuracy: 1)
        XCTAssertEqual(try oldSnapshot.frame(atNs: 0).background_color.0,0,"Queued old frames keep their own immutable snapshot")
        XCTAssertEqual(player.currentNs,400_000_000)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.audioGeneration,audioGeneration,"Appearance refresh must not cancel or rebuild audio")
        XCTAssertEqual(player.compositor.sourceOpenCount,opens,"Same-time visual edits must reuse the decoded recording")

        source.setFailure(true)
        XCTAssertThrowsError(try player.invalidateVisuals())
        XCTAssertEqual(player.audioGeneration,audioGeneration)
        XCTAssertEqual(try pixels(),changed,"Failed snapshots leave the last good appearance intact")
        source.setFailure(false)
        source.setDuration(100_000_000)
        try player.invalidateVisuals()
        XCTAssertGreaterThan(player.audioGeneration,audioGeneration,"Timeline length change must take the full refresh path")
        XCTAssertLessThan(player.currentNs,100_000_000)
        _ = try pixels()
        XCTAssertGreaterThan(player.compositor.sourceOpenCount,opens,"Full refresh still invalidates decoders")
    }

    @MainActor func testVisualRefreshWhilePlayingDoesNotPauseOrReanchorOnHost() throws {
        _ = try requireRenderDevice()
        let source=AppearanceSource(), player=try PreviewPlayer(project: source)
        defer { player.pause() }
        player.seek(toNs: 300_000_000,precise: true); player.play()
        let generation=player.audioGeneration
        source.setWhite(true); try player.invalidateVisuals()
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.currentNs,300_000_000)
        XCTAssertEqual(player.audioGeneration,generation)
        XCTAssertEqual(try player.renderProject.frame(atNs: 0).background_color.0,1)
    }
}

private final class AppearanceSource: RenderProjectSource, @unchecked Sendable {
    let packageURL=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
    private let lock=NSLock()
    private var white=false, fail=false
    private var duration: Int64=2_000_000_000
    var durationNs: Int64 { lock.withLock { duration } }
    func setWhite(_ value: Bool) { lock.withLock { white=value } }
    func setFailure(_ value: Bool) { lock.withLock { fail=value } }
    func setDuration(_ value: Int64) { lock.withLock { duration=value } }
    func renderSnapshot() throws -> any RenderProjectSource {
        try lock.withLock {
            if fail { throw RenderError.invalidSettings("Injected appearance snapshot failure") }
            let color: Float=white ? 1 : 0
            return TestSource(package: packageURL,duration: duration) { ns in Self.frame(ns,color: color) }
        }
    }
    func frame(atNs: Int64) throws -> YcFrame { lock.withLock { Self.frame(atNs,color: white ? 1 : 0) } }
    private static func frame(_ ns: Int64,color: Float) -> YcFrame {
        var f=YcFrame(); f.tl_ns=ns; f.canvas_w=320; f.canvas_h=200; f.background_color=(color,color,color,1); f.click_progress = -1
        f.screen.present=1; f.screen.segment=0; f.screen.file_ns=500_000_000
        f.screen_crop = .init(x: 0,y: 0,w: 1,h: 1); f.screen_dest = .init(x: 80,y: 50,w: 160,h: 100)
        return f
    }
    func renderClips() throws -> [RenderClip] { [] }
    func renderBackgroundAsset(index: UInt32) throws -> URL { throw RenderError.missingMedia("No background image") }
}
