import XCTest
import YapcamCore
@testable import YapcamRender

final class Round3PerformanceTests: XCTestCase {
    func testScrubPercentilesUseNearestRankAndExcludeNonfiniteSamples() throws {
        let values=(1...100).map(Double.init)
        XCTAssertEqual(Round3Data.percentile(values,0.5),50)
        XCTAssertEqual(Round3Data.percentile(values,0.95),95)
        XCTAssertEqual(Round3Data.percentile([.nan,12,.infinity],0.95),12)
        XCTAssertNil(Round3Data.percentile([],0.95))
    }
    func testFirstPresentationRejectsOldRequestsAndDuplicateDrawables() throws {
        let log=Round3Presentations()
        let old=Round3Presentations.Event(ns: 123,generation: 1,time: 20,drawable: 1)
        log.record(old); log.record(old)
        XCTAssertEqual(log.total,1)
        XCTAssertNil(log.first(ns: 123,generation: 2,after: 19))
        XCTAssertNil(log.first(ns: 123,generation: 1,after: 21))
        log.record(.init(ns: 123,generation: 2,time: 21.02,drawable: 2))
        XCTAssertEqual(try XCTUnwrap(log.first(ns: 123,generation: 2,after: 21)).time-21,0.02,accuracy: 0.000001)
        log.record(.init(ns: 123,generation: 2,time: .nan,drawable: 3))
        log.record(.init(ns: 123,generation: 2,time: 0,drawable: 4))
        XCTAssertEqual(log.total,2)
    }
    func testLongRepeatedTimelineKeepsExactSourceAndAudioClocksAtWrapBoundaries() throws {
        let source=try Round3RepeatedSource(base: Round3ClockSource(),minimumSeconds: 660)
        XCTAssertEqual(source.durationNs,660_000_000_000)
        for time: Int64 in [0,1_999_999_999,2_000_000_000,650_123_456_789] {
            let frame=try source.frame(atNs: time)
            XCTAssertEqual(frame.tl_ns,time)
            XCTAssertEqual(frame.screen.file_ns,time % 2_000_000_000)
        }
        let ranges=try XCTUnwrap(source.renderAudioRanges())
        XCTAssertEqual(ranges.count,330)
        XCTAssertEqual(ranges[1].tlStartNs,2_200_000_000)
        XCTAssertEqual(ranges.last?.tlEndNs,659_800_000_000)
        XCTAssertTrue(ranges.allSatisfy { $0.fileStartNs==100_000_000 && $0.fileEndNs==1_700_000_000 })
        XCTAssertEqual(try source.renderClips().count,330)
    }
    func testFingerprintDetectsSourceMutationWithoutReadingImagesOrAudioIntoMemory() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-round3-hash-\(UUID().uuidString)")
        defer { print("Cleanup render-owned fingerprint fixture: \(root.lastPathComponent)"); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let file=root.appendingPathComponent("fixture.bin")
        try Data(repeating: 123,count: 2_000_000).write(to: file)
        let before=try Round3Data.fingerprints(root)
        XCTAssertEqual(try Round3Data.fingerprints(root),before)
        let handle=try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 1_500_000); try handle.write(contentsOf: Data([0])); try handle.close()
        XCTAssertNotEqual(try Round3Data.fingerprints(root),before,"The check covers the entire original, not just its first MiB")
    }
    func testSynthetic4KRecipeCreatesActualHEVC60FPSAndAudioWhenOptedIn() throws {
        guard ProcessInfo.processInfo.environment["YAPCAM_RENDER_ROUND3_SYNTHETIC_SMOKE"]=="1" else {
            throw XCTSkip("Set YAPCAM_RENDER_ROUND3_SYNTHETIC_SMOKE=1 for a short software HEVC generator check")
        }
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Yapcam/QA/render/round3-generator-\(UUID().uuidString)")
        defer { print("Cleanup render-owned generated media: \(root.lastPathComponent)"); try? FileManager.default.removeItem(at: root) }
        let seconds=Double(ProcessInfo.processInfo.environment["YAPCAM_RENDER_ROUND3_GENERATOR_SECONDS"] ?? "0.2") ?? 0
        guard seconds.isFinite,(0.1...120).contains(seconds) else { throw RenderError.invalidSettings("Round3 generator check duration must be 0.1...120 seconds") }
        try Round3Synthetic.create(at: root,seconds: seconds)
        let movie=root.appendingPathComponent("recording/screen.mov")
        let result=try Round3Child().run("/opt/homebrew/bin/ffprobe",["-v","error","-count_frames","-show_entries",
            "stream=codec_name,width,height,r_frame_rate,nb_read_frames,codec_type","-of","json",movie.path],in: root)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String:Any])
        let streams=try XCTUnwrap(object["streams"] as? [[String:Any]])
        let video=try XCTUnwrap(streams.first { $0["codec_type"] as? String == "video" })
        XCTAssertEqual(video["codec_name"] as? String,"hevc")
        XCTAssertEqual(video["width"] as? Int,3840); XCTAssertEqual(video["height"] as? Int,2160)
        XCTAssertEqual(video["r_frame_rate"] as? String,"60/1")
        XCTAssertEqual(video["nb_read_frames"] as? String,String(Int((seconds*60).rounded())))
        XCTAssertTrue(streams.contains { $0["codec_type"] as? String == "audio" })
        let project=try Project.create(package: root)
        XCTAssertEqual(project.durationNs,Int64((seconds*1e9).rounded()))
        XCTAssertFalse(try XCTUnwrap(project.renderAudioRanges()).isEmpty)
        let metadata: [String:Any] = ["procedure":"software input generation and independent ffprobe; not a Render performance result",
            "revision":ProcessInfo.processInfo.environment["YAPCAM_RENDER_ROUND3_REVISION"] ?? "unspecified",
            "source":"synthetic 4K","width":3840,"height":2160,"fps":60,"seconds":seconds,
            "frames":Int((seconds*60).rounded()),"audio":true,
            "file_bytes":try movie.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0]
        print("RENDER_ROUND3_INPUT \(String(decoding: try JSONSerialization.data(withJSONObject: metadata,options: [.sortedKeys]),as: UTF8.self))")
    }
    func testAvailableRealRecordingIsCopiedBeforeCoreEditsAndOriginalStaysIntactWhenOptedIn() throws {
        guard ProcessInfo.processInfo.environment["YAPCAM_RENDER_ROUND3_REAL_COPY"]=="1" else {
            throw XCTSkip("Set YAPCAM_RENDER_ROUND3_REAL_COPY=1 for the read-only real-package copy check")
        }
        let media=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Yapcam")
        let packages=try FileManager.default.contentsOfDirectory(at: media,includingPropertiesForKeys: nil).filter {
            guard $0.lastPathComponent.hasPrefix("Recording-"),$0.pathExtension=="yapcam",
                  let data=try? Data(contentsOf: $0.appendingPathComponent("recording/session.json")),
                  let row=try? JSONSerialization.jsonObject(with: data) as? [String:Any] else { return false }
            return row["status"] as? String == "complete"
        }
        let original=try XCTUnwrap(packages.first)
        let before=try Round3Data.fingerprints(original)
        let root=media.appendingPathComponent("QA/render/round3-real-copy-\(UUID().uuidString).yapcam")
        defer { print("Cleanup render-owned real copy: \(root.lastPathComponent)"); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(),withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original,to: root)
        let project=try Project.create(package: root)
        try project.apply(.set(path: "canvas.aspect",value: .string("16:9")))
        let source=try Round3RepeatedSource(base: project,minimumSeconds: 1260)
        XCTAssertGreaterThanOrEqual(source.durationNs,1_260_000_000_000)
        let t: Int64=650_000_000_000
        let real=try project.frame(atNs: t % project.durationNs), repeated=try source.frame(atNs: t)
        XCTAssertEqual(real.screen.file_ns,repeated.screen.file_ns)
        XCTAssertEqual(repeated.tl_ns,t)
        XCTAssertFalse(try XCTUnwrap(source.renderAudioRanges()).isEmpty)
        try project.save()
        XCTAssertEqual(try Round3Data.fingerprints(original),before,"The original is never opened through Core or edited")
    }
}

private final class Round3ClockSource: RenderProjectSource, @unchecked Sendable {
    let packageURL=FileManager.default.temporaryDirectory
    let durationNs: Int64=2_000_000_000
    func frame(atNs ns: Int64) throws -> YcFrame {
        var f=YcFrame(); f.tl_ns=ns; f.screen.present=1; f.screen.file_ns=ns; return f
    }
    func renderSnapshot() throws -> any RenderProjectSource { self }
    func renderBackgroundAsset(index: UInt32) throws -> URL { throw RenderError.unavailable("Clock fixture has no image") }
    func renderClips() throws -> [RenderClip] { [.init(srcStartNs: 0,srcEndNs: durationNs)] }
    func renderAudioRanges() throws -> [RenderAudioRange]? {
        [.init(track: .systemAudio,path: "clock.mov",fileStartNs: 100_000_000,fileEndNs: 1_700_000_000,tlStartNs: 200_000_000,tlEndNs: 1_800_000_000)]
    }
}
