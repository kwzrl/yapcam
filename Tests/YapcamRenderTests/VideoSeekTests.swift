import XCTest
@preconcurrency import AVFoundation
@testable import YapcamRender

final class VideoSeekTests: XCTestCase {
    func testIrregularPresentationTimesAndColdStaticTailUseTheActualPredecessor() throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else {
            throw XCTSkip("ffmpeg is required only to generate the tiny VFR metadata fixture")
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-vfr-seek-\(UUID().uuidString)")
        defer { print("Cleanup render-owned VFR metadata fixture: \(root.lastPathComponent)"); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let movie=root.appendingPathComponent("vfr.mov")
        _ = try Round3Child().run("/opt/homebrew/bin/ffmpeg",["-nostdin","-v","error","-f","lavfi","-i","testsrc2=size=64x48:rate=30:duration=3",
            "-vf","select=eq(n\\,0)+eq(n\\,6)+eq(n\\,51)+eq(n\\,89)","-fps_mode","vfr","-c:v","libx264","-bf","0","-an",movie.path],in: root,timeout: 30)
        let asset=AVURLAsset(url: movie,options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let track=try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        for (requested,expected): (Int64,Int64) in [(0,0),(200_000_000,6),(1_000_000_000,6),(2_000_000_000,51),(5_000_000_000,89)] {
            let actual=VideoSeekStart.time(asset: asset,track: track,requested: CMTime(value: requested,timescale: 1_000_000_000))
            XCTAssertEqual(CMTimeCompare(actual,CMTime(value: expected,timescale: 30)),0,"VFR source ns=\(requested)")
        }
    }
    func testPreciseStartMatchesThePreviousRealPresentationSample() throws {
        let url=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/synthetic/basic.yapcam/recording/seg-000/screen.mov")
        let asset=AVURLAsset(url: url,options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let track=try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        // The checked-in fixture is exactly 90 frames at 30fps. The independent
        // file PTS grid avoids AVAssetReader's compressed-output B-frame offset.
        XCTAssertEqual(track.nominalFrameRate,30)
        XCTAssertEqual(track.timeRange.duration.seconds,3,accuracy: 0.000001)
        let times=(0..<90).map { CMTime(value: Int64($0),timescale: 30) }
        for ns: Int64 in [0,1,400_000_000,1_001_000_000,2_611_000_000,2_999_999_999,5_000_000_000] {
            let requested=CMTime(value: ns,timescale: 1_000_000_000)
            let expected=try XCTUnwrap(times.last { $0<=requested } ?? times.first)
            let start=VideoSeekStart.time(asset: asset,track: track,requested: requested)
            XCTAssertEqual(CMTimeCompare(start,expected),0,"source ns=\(ns), firstPTS=\(times.first?.seconds ?? -1), start=\(start.seconds), expected=\(expected.seconds)")
        }
    }
}
