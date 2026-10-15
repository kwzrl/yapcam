import XCTest
import AVFoundation
import YapcamCore
@testable import YapcamRender

final class AudioTailTests: XCTestCase {
    private var root: URL!
    private let duration: Int64=2_000_000_000
    private let offset: Int64=26_123_457
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-audio-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func package(frames: Int, aac: Bool = false) throws -> URL {
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let package=root.appendingPathComponent("tail-\(frames)-\(aac).yapcam")
        try FileManager.default.copyItem(at: fixture,to: package)
        let url=package.appendingPathComponent("recording/session.json")
        var session=try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var segment=try XCTUnwrap((session["segments"] as? [[String: Any]])?.first)
        segment["duration_ns"]=duration
        var files=try XCTUnwrap(segment["files"] as? [String: String])
        files["system_audio"]=aac ? "seg-000/tail.m4a" : "seg-000/tail.wav"; segment["files"]=files
        segment["track_start_ns"]=["screen":0,"system_audio":offset]
        session["segments"]=[segment]
        try JSONSerialization.data(withJSONObject: session).write(to: url)
        let samples=(0..<frames).map { Int16((sin(2*Double.pi*1000*Double($0)/48_000)*10_000).rounded()) }
        try ProceduralAudio.wav(samples).write(to: package.appendingPathComponent("recording/seg-000/tail.wav"))
        if aac {
            _ = try LongRunDecoder.capture(["-v","error","-i",package.appendingPathComponent("recording/seg-000/tail.wav").path,"-c:a","aac","-b:a","128k",package.appendingPathComponent("recording/seg-000/tail.m4a").path],timeout: 30)
        }
        return package
    }

    private func sources(_ package: URL, edited: Bool = false) throws -> [(String, any RenderProjectSource)] {
        let project=try Project.create(package: package)
        if edited {
            try project.apply(.deleteRange(startNs: 400_000_000,endNs: 800_000_000))
            struct Clip: Decodable { var id: String }
            for clip in try project.query("{\"q\":\"clips\"}",as: [Clip].self) {
                try project.apply(.setSpeed(clipID: clip.id,speed: 1.3))
            }
        }
        let legacy=TestSource(package: package,duration: project.durationNs,clips: try project.renderClips()) { ns in
            var f=YcFrame(); f.tl_ns=ns; f.canvas_w=320; f.canvas_h=200; f.system_gain=1; return f
        }
        return [("core",project),("legacy",legacy)]
    }

    func testOffsetPCMTailsShorterAndLongerThanVideoDrainToRequestedEnd() throws {
        _ = try requireRenderDevice() // Native AVAssetReader/mixer services are unavailable here too.
        // A fractional source-clock offset also exercises non-sample-aligned trims.
        // Global audio ends about 16ms before / 10ms after the 2s video endpoint.
        for frames in [93_986,95_234] {
            let package=try package(frames: frames)
            for (name,source) in try sources(package) {
                for range in [Int64(0)..<duration,Int64(1_800_000_000)..<duration,Int64(1_900_000_000)..<duration] {
                    let timeline=try AudioTimeline(project: source,range: range)
                    let (reader,output)=try XCTUnwrap(timeline.reader(rangeDuration: Int64(range.count)))
                    defer { reader.cancelReading() }
                    var count=0, end=CMTime.zero
                    while let sample=output.copyNextSampleBuffer() {
                        end=CMSampleBufferGetPresentationTimeStamp(sample)+CMSampleBufferGetDuration(sample)
                        count+=CMSampleBufferGetNumSamples(sample)
                    }
                    let detail="\(name) frames=\(frames) range=\(range) error=\(String(describing: reader.error))"
                    XCTAssertEqual(reader.status,.completed,detail)
                    XCTAssertGreaterThan(count,0,detail)
                    XCTAssertEqual(end.seconds,Double(range.count)/1e9,accuracy: 1/48_000,detail)
                }
            }
        }
    }

    func testCompositionSelectionsNeverExtendBeyondThePhysicalTrackAndTailIsRealSilence() throws {
        for aac in [false,true] {
            let package=try package(frames: 93_986,aac: aac)
            let audio=package.appendingPathComponent(aac ? "recording/seg-000/tail.m4a" : "recording/seg-000/tail.wav")
            for (_,source) in try sources(package) {
                let timeline=try AudioTimeline(project: source,range: 0..<duration)
                try assertSelections(timeline,audio: audio,duration: duration,expectTailSilence: true)
            }
        }
    }

    private func assertSelections(_ timeline: AudioTimeline, audio: URL, duration: Int64, expectTailSilence: Bool) throws {
        let media=try XCTUnwrap(AVURLAsset(url: audio).tracks(withMediaType: .audio).first).timeRange
        let segments=timeline.composition.tracks(withMediaType: .audio).flatMap { $0.segments ?? [] }.filter { !$0.isEmpty }
        let recorded=segments.filter { $0.sourceURL==audio }
        XCTAssertFalse(recorded.isEmpty)
        for segment in recorded {
            XCTAssertGreaterThanOrEqual(CMTimeCompare(segment.timeMapping.source.start,media.start),0)
            XCTAssertLessThanOrEqual(CMTimeCompare(segment.timeMapping.source.end,media.end),0,"Never round a physical EOF upward into a nonexistent sample")
        }
        let end=CMTime(value: duration,timescale: 1_000_000_000)
        let silence=segments.filter { $0.sourceURL != audio }
        if expectTailSilence {
            let lastAudioEnd=try XCTUnwrap(recorded.map { $0.timeMapping.target.end }.max())
            XCTAssertTrue(silence.contains { $0.timeMapping.target.start<=lastAudioEnd && $0.timeMapping.target.end>=end },"EOF padding must contain actual zero samples across the whole missing tail, not only a one-sample endpoint marker")
        }
        for url in Set(silence.compactMap { $0.sourceURL }) {
            let wav=try Data(contentsOf: url)
            XCTAssertTrue(wav.dropFirst(44).allSatisfy { $0==0 },"Padding is digital silence")
            XCTAssertLessThanOrEqual(wav.count,96_044,"Silence storage stays bounded to one second")
        }
        var covered=CMTime.zero
        for interval in segments.map({ $0.timeMapping.target }).sorted(by: { $0.start<$1.start }) {
            XCTAssertLessThanOrEqual(CMTimeCompare(interval.start,covered),0,"No empty leading, interior or trailing edits in mixed coverage")
            covered=max(covered,interval.end)
        }
        XCTAssertEqual(covered.seconds,end.seconds,accuracy: 1/48_000)
    }

    func testLongerAudioAndRetimedCutsRespectPhysicalEOFAndRequestedClock() throws {
        for frames in [93_986,95_234] {
            let package=try package(frames: frames)
            for (_,source) in try sources(package,edited: true) {
                let start=source.durationNs-200_000_000
                let timeline=try AudioTimeline(project: source,range: start..<source.durationNs)
                try assertSelections(timeline,audio: package.appendingPathComponent("recording/seg-000/tail.wav"),duration: source.durationNs-start,expectTailSilence: frames==93_986)
            }
        }
    }

    func testRangeEntirelyAfterAudioEOFStillHasASilentAudioClock() throws {
        let package=try package(frames: 93_986)
        for (_,source) in try sources(package) {
            let timeline=try AudioTimeline(project: source,range: 1_990_000_000..<duration)
            XCTAssertTrue(timeline.hasAudio,"A known audio track's missing tail must be padded, not dropped")
            XCTAssertEqual(timeline.composition.duration.seconds,0.01,accuracy: 1/48_000)
        }
    }

    func testUnreadableAudioStillFailsInsteadOfBeingReplacedWithSilence() throws {
        let package=try package(frames: 93_986)
        try Data("invalid audio".utf8).write(to: package.appendingPathComponent("recording/seg-000/tail.wav"))
        for (_,source) in try sources(package) {
            XCTAssertThrowsError(try AudioTimeline(project: source,range: 0..<duration)) { error in
                guard case RenderError.decode = error else { return XCTFail("Expected a real decode failure, got \(error)") }
            }
        }
    }

    func testVideoOnlyRecordingDoesNotGainAnAudioTrack() throws {
        let package=try package(frames: 93_986)
        let url=package.appendingPathComponent("recording/session.json")
        var session=try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var segments=try XCTUnwrap(session["segments"] as? [[String: Any]])
        var files=try XCTUnwrap(segments[0]["files"] as? [String: String])
        files.removeValue(forKey: "system_audio"); segments[0]["files"]=files
        session["segments"]=segments
        try JSONSerialization.data(withJSONObject: session).write(to: url)
        for (_,source) in try sources(package) {
            XCTAssertFalse(try AudioTimeline(project: source,range: 0..<duration).hasAudio)
        }
    }

    func testOffsetAACTailsShorterAndLongerThanVideoExportFullAndLast100ms() async throws {
        _ = try requireRenderDevice()
        for frames in [93_986,95_234] {
            let package=try package(frames: frames,aac: true)
            for (name,source) in try sources(package) {
                for start: Int64 in [0,1_900_000_000] {
                    let timeline=try AudioTimeline(project: source,range: start..<duration)
                    let (reader,output)=try XCTUnwrap(timeline.reader(rangeDuration: duration-start))
                    defer { reader.cancelReading() }
                    var end=CMTime.zero
                    while let sample=output.copyNextSampleBuffer() {
                        end=CMSampleBufferGetPresentationTimeStamp(sample)+CMSampleBufferGetDuration(sample)
                    }
                    XCTAssertEqual(reader.status,.completed,String(describing: reader.error))
                    XCTAssertEqual(end.seconds,Double(duration-start)/1e9,accuracy: 1/48_000)
                    let url=root.appendingPathComponent("\(frames)-\(name)-\(start).mp4")
                    let settings=ExportSettings(outputHeight: 720,includeAudio: true,rangeStartNs: start,rangeEndNs: duration)
                    let exporter=try Exporter(project: source,settings: settings,destination: url)
                    let task=Task { try await exporter.run { _ in } }
                    let deadline=Task { do { try await Task.sleep(for: .seconds(60)); task.cancel() } catch {} }
                    defer { deadline.cancel() }
                    _ = try await task.value
                    let asset=AVURLAsset(url: url)
                    let audioTracks=try await asset.loadTracks(withMediaType: .audio)
                    XCTAssertEqual(audioTracks.count,1)
                    let actual=try await asset.load(.duration)
                    XCTAssertEqual(actual.seconds,Double(duration-start)/1e9,accuracy: 1/30)
                }
            }
        }
    }
}
