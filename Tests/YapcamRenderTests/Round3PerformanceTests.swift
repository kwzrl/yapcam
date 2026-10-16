import XCTest
import YapcamCore
@preconcurrency import AVFoundation
@testable import YapcamRender

final class Round3PerformanceTests: XCTestCase {
    func testRSSGrowthNumericallyConvertsByteCountsAndRetainsSign() {
        let mib: UInt64=1_048_576
        let early=[511*mib,512*mib,513*mib]
        XCTAssertEqual(Round3Data.rssMedianGrowth(early: early,late: [514*mib,513*mib,512*mib]),Double(mib))
        XCTAssertEqual(Round3Data.rssMedianGrowth(early: early,late: [512*mib,510*mib,511*mib]),-Double(mib))
        XCTAssertEqual(Round3Data.rssMedianGrowth(early: early,late: early),0)
    }
    func testLongConstantAudioKeepsOneRampPerCoreInterval() throws {
        let root=try audioFixture()
        defer { cleanup(root) }
        let base=Round3AudioSource(package: root,duration: 1_000_000_000,ranges: [
            .init(track: .systemAudio,path: "recording/clock.wav",fileStartNs: 0,fileEndNs: 1_000_000_000,
                  tlStartNs: 0,tlEndNs: 1_000_000_000,gainStart: 0.75,gainEnd: 0.75)
        ])
        let source=try Round3RepeatedSource(base: base,minimumSeconds: 660)
        let timeline=try AudioTimeline(project: source,range: 0..<source.durationNs)
        let parameter=try XCTUnwrap(timeline.mix.inputParameters.first)
        XCTAssertEqual(timeline.composition.duration.seconds,660,accuracy: 0.000_001)
        // Structural complexity regression: the old implementation built 33,000
        // redundant 20ms ramps and took >60s on the real repeated recording.
        // Inspect AVFoundation's resulting intervals without a flaky time limit.
        for second in [0,1,329,659] {
            var a: Float=0,b: Float=0,range=CMTimeRange.zero
            XCTAssertTrue(parameter.getVolumeRamp(for: CMTime(seconds: Double(second)+0.5,preferredTimescale: 1_000_000_000),
                                                 startVolume: &a,endVolume: &b,timeRange: &range))
            XCTAssertEqual(a,0.75); XCTAssertEqual(b,0.75)
            XCTAssertEqual(range.start.seconds,Double(second),accuracy: 0.000_001)
            XCTAssertEqual(range.duration.seconds,1,accuracy: 0.000_001)
        }
    }
    func testConstantAudioOptimizationPreservesMuteStepsAndClippedDBAutomation() throws {
        let root=try audioFixture()
        defer { cleanup(root) }
        let gains: [(Float,Float)]=[(0.7,0.7),(0,0),(0.2,0.8),(1,1)]
        let rows=gains.enumerated().map { index,gain in
            RenderAudioRange(track: .systemAudio,path: "recording/clock.wav",fileStartNs: 0,fileEndNs: 1_000_000_000,
                             tlStartNs: Int64(index)*1_000_000_000+100_000_000,
                             tlEndNs: Int64(index+1)*1_000_000_000+100_000_000,gainStart: gain.0,gainEnd: gain.1)
        }
        let source=Round3AudioSource(package: root,duration: 4_200_000_000,ranges: rows)
        let timeline=try AudioTimeline(project: source,range: 600_000_000..<3_600_000_000)
        let parameter=try XCTUnwrap(timeline.mix.inputParameters.first)
        for ns: Int64 in [600_000_000,1_099_999_000,1_100_000_000,2_099_999_000,
                          2_100_000_000,2_611_000_000,3_099_999_000,3_100_000_000,3_599_999_000] {
            let time=CMTime(value: ns-600_000_000,timescale: 1_000_000_000)
            var a: Float=0,b: Float=0,range=CMTimeRange.zero
            XCTAssertTrue(parameter.getVolumeRamp(for: time,startVolume: &a,endVolume: &b,timeRange: &range))
            let fraction=Float((time-range.start).seconds/range.duration.seconds)
            let row=try XCTUnwrap(rows.first { $0.tlStartNs<=ns && ns<$0.tlEndNs })
            XCTAssertEqual(a+(b-a)*fraction,row.gain(atTimelineNs: ns),accuracy: 0.005,"timeline ns=\(ns)")
        }
        XCTAssertEqual(timeline.composition.duration.seconds,3,accuracy: 0.000_001)
    }
    private func audioFixture() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-round3-audio-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("recording"),withIntermediateDirectories: true)
            try Data(#"{"segments":[]}"#.utf8).write(to: root.appendingPathComponent("recording/session.json"))
            try ProceduralAudio.wav(Array(repeating: 1_000,count: ProceduralAudio.sampleRate)).write(to: root.appendingPathComponent("recording/clock.wav"))
            return root
        } catch { cleanup(root); throw error }
    }
    private func cleanup(_ root: URL) {
        print("Cleanup render-owned audio fixture: \(root.lastPathComponent)")
        try? FileManager.default.removeItem(at: root)
    }
    func testRealAudioPreparationAtPhysicalAndRepeatedLengthsWhenOptedIn() throws {
        guard let path=ProcessInfo.processInfo.environment["YAPCAM_RENDER_ROUND3_AUDIO_PACKAGE"] else {
            throw XCTSkip("Opt in to local audio-composition preparation diagnostics")
        }
        let original=URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let media=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Yapcam")
        guard original.path.hasPrefix(media.path+"/") else { throw RenderError.invalidSettings("Audio diagnostic input must stay under Movies/Yapcam") }
        let before=try Round3Data.fingerprints(original)
        let copy=media.appendingPathComponent("QA/render/round3-audio-diagnostic-\(UUID().uuidString).yapcam")
        defer { print("Cleanup render-owned audio diagnostic copy: \(copy.lastPathComponent)"); try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: original,to: copy)
        let physical=try Project.create(package: copy)
        for seconds in [0.0,660.0] {
            let source: any RenderProjectSource=seconds==0 ? physical : try Round3RepeatedSource(base: physical,minimumSeconds: seconds)
            let start=DispatchTime.now().uptimeNanoseconds
            print("RENDER_ROUND3_AUDIO_PREP_START timeline_seconds=\(Double(source.durationNs)/1e9)")
            let timeline=try AudioTimeline(project: source,range: 0..<source.durationNs)
            let elapsed=Double(DispatchTime.now().uptimeNanoseconds-start)/1e9
            let tracks=timeline.composition.tracks(withMediaType: .audio)
            let row: [String:Any]=["timeline_seconds":Double(source.durationNs)/1e9,"preparation_seconds":elapsed,
                                  "tracks":tracks.count,"segments":tracks.reduce(0) { $0+($1.segments?.count ?? 0) },
                                  "mix_parameters":timeline.mix.inputParameters.count,"audio":timeline.hasAudio]
            print("RENDER_ROUND3_AUDIO_PREP \(String(decoding: try JSONSerialization.data(withJSONObject: row,options: [.sortedKeys]),as: UTF8.self))")
            XCTAssertTrue(timeline.hasAudio)
        }
        XCTAssertEqual(try Round3Data.fingerprints(original),before)
    }
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

private final class Round3AudioSource: RenderProjectSource, @unchecked Sendable {
    let packageURL: URL
    let durationNs: Int64
    let ranges: [RenderAudioRange]
    init(package: URL,duration: Int64,ranges: [RenderAudioRange]) {
        packageURL=package; durationNs=duration; self.ranges=ranges
    }
    func frame(atNs ns: Int64) throws -> YcFrame { var f=YcFrame(); f.tl_ns=ns; return f }
    func renderSnapshot() throws -> any RenderProjectSource { self }
    func renderBackgroundAsset(index: UInt32) throws -> URL { throw RenderError.unavailable("Audio fixture has no image") }
    func renderClips() throws -> [RenderClip] { [.init(srcStartNs: 0,srcEndNs: durationNs)] }
    func renderAudioRanges() throws -> [RenderAudioRange]? { ranges }
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
