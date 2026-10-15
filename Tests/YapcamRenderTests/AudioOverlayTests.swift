import XCTest
@testable import YapcamRender
import AVFoundation

final class AudioOverlayTests: XCTestCase {
    var temp: URL!
    override func setUpWithError() throws {
        temp=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-audio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("recording"),withIntermediateDirectories: true)
        try Data("{\"segments\":[]}".utf8).write(to: temp.appendingPathComponent("recording/session.json"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }
    func testProceduralClicksAreDistinctFiniteAndHaveCorrectWAVHeader() throws {
        let soft=try ProceduralAudio.samples(for: .click(.soft)), crisp=try ProceduralAudio.samples(for: .click(.crisp))
        XCTAssertEqual(soft.count,3840); XCTAssertEqual(crisp.count,2400)
        XCTAssertNotEqual(Array(soft.prefix(100)),Array(crisp.prefix(100)))
        XCTAssertLessThan(abs(Int(soft.last!)),20)
        let wav=ProceduralAudio.wav(soft)
        XCTAssertEqual(String(data: wav.prefix(4),encoding: .utf8),"RIFF")
        XCTAssertEqual(String(data: wav[8..<12],encoding: .utf8),"WAVE")
        XCTAssertEqual(wav.count,44+soft.count*2)
    }
    func testOriginalMusicHasContinuousEightSecondLoopBoundary() throws {
        let samples=try ProceduralAudio.samples(for: .music(.calm))
        XCTAssertEqual(samples.count,8*48_000)
        XCTAssertEqual(samples.first,0)
        XCTAssertLessThan(abs(Int(samples.last!)),3)
        XCTAssertGreaterThan(samples.map { abs(Int($0)) }.max()!,1000)
    }
    func testLoopFadeAndClickOverlayCompositionMapping() throws {
        let overlays: [AudioOverlay] = [
            .init(source: .music(.calm),startNs: 0,endNs: 10_000_000_000,gain: 0.3,loops: true,fadeInNs: 1_000_000_000,fadeOutNs: 1_000_000_000),
            .init(source: .click(.soft),startNs: 8_500_000_000,endNs: 8_580_000_000)
        ]
        let source=TestSource(package: temp,duration: 10_000_000_000,overlays: overlays)
        let timeline=try AudioTimeline(project: source,range: 7_500_000_000..<9_500_000_000)
        XCTAssertEqual(timeline.composition.duration.seconds,2,accuracy: 0.000_001)
        let tracks=timeline.composition.tracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count,2)
        let music=tracks[0].segments.filter { !$0.isEmpty }
        XCTAssertEqual(music.count,2)
        XCTAssertEqual(music[0].timeMapping.source.start.seconds,7.5,accuracy: 0.000_001)
        XCTAssertEqual(music[1].timeMapping.target.start.seconds,0.5,accuracy: 0.000_001)
        let click=tracks[1].segments.filter { !$0.isEmpty }
        XCTAssertEqual(click[0].timeMapping.target.start.seconds,1,accuracy: 0.000_001)
        XCTAssertEqual(timeline.mix.inputParameters.count,2)
    }
    func testEarlyDeviceLostAudioPadsPreviewClockThroughSilence() throws {
        let source=TestSource(package: temp,duration: 1_000_000_000,overlays: [.init(source: .click(.soft),startNs: 0,endNs: 80_000_000)])
        let timeline=try AudioTimeline(project: source,range: 0..<source.durationNs)
        XCTAssertEqual(timeline.composition.duration.seconds,1,accuracy: 0.000_001)
    }
    func testSubsampleLoopDurationIsRejectedBeforeUnboundedCompositionInsertion() throws {
        let source=TestSource(package: temp,duration: 1_000_000_000,overlays: [
            .init(source: .music(.calm),startNs: 0,endNs: 1_000_000_000,loops: true,sourceDurationNs: 1)
        ])
        XCTAssertThrowsError(try AudioTimeline(project: source,range: 0..<source.durationNs)) { error in
            guard case RenderError.invalidSettings = error else { return XCTFail("Expected a bounded invalid-loop error: \(error)") }
        }
    }
    func testOverlappingFadesRetainTheirPeakThroughAnExportRange() throws {
        let source=TestSource(package: temp,duration: 1_000_000_000,overlays: [
            .init(source: .music(.calm),startNs: 0,endNs: 1_000_000_000,gain: 0.8,fadeInNs: 1_000_000_000,fadeOutNs: 1_000_000_000)
        ])
        for range in [Int64(0)..<1_000_000_000,Int64(400_000_000)..<600_000_000] {
            let timeline=try AudioTimeline(project: source,range: range)
            let parameter=try XCTUnwrap(timeline.mix.inputParameters.first)
            for timestamp in [450_000_000,500_000_000,550_000_000] {
                let time=CMTime(value: Int64(timestamp)-range.lowerBound,timescale: 1_000_000_000)
                var initial: Float=0, final: Float=0, ramp=CMTimeRange.zero
                XCTAssertTrue(parameter.getVolumeRamp(for: time,startVolume: &initial,endVolume: &final,timeRange: &ramp))
                let fraction=Float((time-ramp.start).seconds/ramp.duration.seconds)
                let volume=initial+(final-initial)*fraction
                XCTAssertEqual(volume,Float(min(Double(timestamp)/1e9,1-Double(timestamp)/1e9))*0.8,accuracy: 0.000_001)
            }
        }
    }
}
