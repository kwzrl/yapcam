import XCTest
@testable import YapcamRender
import AVFoundation
import Metal

final class AudioTimelineTests: XCTestCase {
    var fixture: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam") }
    func source(clips: [RenderClip], duration: Int64) -> TestSource {
        TestSource(package: fixture, duration: duration, clips: clips) { ns in
            var f = YcFrame(); f.tl_ns = ns; f.canvas_w = 320; f.canvas_h = 200; f.mic_gain = 0.5; f.system_gain = 0.25; return f
        }
    }
    func testAudioKeepsSegmentPauseOutOfTimeline() throws {
        let source = source(clips: [.init(srcStartNs: 0, srcEndNs: 5_000_000_000)], duration: 5_000_000_000)
        let timeline = try AudioTimeline(project: source, range: 0..<source.durationNs)
        let track = try XCTUnwrap(timeline.composition.tracks(withMediaType: .audio).first)
        XCTAssertEqual(track.timeRange.duration.seconds,5,accuracy: 0.001)
        let segments = track.segments.filter { !$0.isEmpty }
        XCTAssertEqual(segments.count,2)
        XCTAssertEqual(segments[1].timeMapping.target.start.seconds,3,accuracy: 0.001)
        XCTAssertEqual(timeline.mix.inputParameters.count,1)
    }
    func testAudioCutsSpeedAndExportRangeShareClipMapping() throws {
        let source = source(clips: [.init(srcStartNs: 500_000_000, srcEndNs: 2_500_000_000, speed: 2), .init(srcStartNs: 3_250_000_000, srcEndNs: 4_250_000_000, speed: 0.5)], duration: 3_000_000_000)
        let timeline = try AudioTimeline(project: source, range: 500_000_000..<2_000_000_000)
        let track = try XCTUnwrap(timeline.composition.tracks(withMediaType: .audio).first)
        XCTAssertEqual(track.timeRange.duration.seconds,1.5,accuracy: 0.001)
        let segments = track.segments.filter { !$0.isEmpty }
        XCTAssertEqual(segments.count,2)
        XCTAssertEqual(segments[0].timeMapping.source.start.seconds,1.5,accuracy: 0.001)
        XCTAssertEqual(segments[0].timeMapping.target.duration.seconds,0.5,accuracy: 0.001)
        XCTAssertEqual(segments[1].timeMapping.source.start.seconds,0.25,accuracy: 0.001)
        XCTAssertEqual(segments[1].timeMapping.target.start.seconds,0.5,accuracy: 0.001)
    }
    func testMixedPCMReaderProducesZeroBasedMonotonicSamples() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Host media-service check required: sandbox AVAssetReader start fails -11800/-1 and Metal is unavailable") }
        let source = source(clips: [.init(srcStartNs: 1_000_000_000, srcEndNs: 2_000_000_000)], duration: 1_000_000_000)
        let timeline = try AudioTimeline(project: source, range: 0..<source.durationNs)
        let (reader, output) = try XCTUnwrap(timeline.reader(rangeDuration: source.durationNs))
        defer { reader.cancelReading() }
        var previous = -1.0, samples = 0
        while let buffer = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            XCTAssertGreaterThan(time,previous)
            if samples == 0 { XCTAssertEqual(time,0,accuracy: 1/48_000) }
            previous = time; samples += 1
        }
        XCTAssertEqual(reader.status,.completed,reader.error?.localizedDescription ?? "")
        XCTAssertGreaterThan(samples,0)
        XCTAssertLessThan(previous,1)
    }
}
