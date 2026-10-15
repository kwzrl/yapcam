import XCTest
import AVFoundation
import YapcamCore
@testable import YapcamRender

final class CoreAudioOverlayTests: XCTestCase {
    private struct ActiveEffects: Decodable {
        struct Audio: Decodable { let gainAt: Float }
        let audio: [Audio]
    }
    func testRealCoreDuckingProductFadesAndLoopClockSurviveSplitAndTrim() throws {
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let package=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-core-music-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: fixture,to: package)
        defer { try? FileManager.default.removeItem(at: package) }
        let project=try Project.create(package: package)
        try project.apply(.set(path: "audio.music",value: .array([.object([
            "id":.string("own-loop"),"source":.string("calm"),"tl_start_ns":.integer(0),"tl_end_ns":.integer(5_000_000_000),
            "file_start_ns":.integer(7_500_000_000),"gain_db":.number(-6),"fade_in_ns":.integer(2_000_000_000),"fade_out_ns":.integer(4_000_000_000),
            "ducking":.object(["enabled":.bool(true),"gain_db":.number(-18),"attack_ns":.integer(200_000_000),"release_ns":.integer(400_000_000),"ranges":.array([
                .object(["tl_start_ns":.integer(1_000_000_000),"tl_end_ns":.integer(1_300_000_000)]),
                .object(["tl_start_ns":.integer(1_400_000_000),"tl_end_ns":.integer(2_500_000_000)])
            ])])
        ])])))
        let snapshot=try project.renderSnapshot()
        let overlays=try snapshot.renderAudioOverlays()
        XCTAssertGreaterThan(overlays.count,5)
        XCTAssertTrue(overlays.allSatisfy { $0.multiplyFades && $0.envelopeStartNs==0 && $0.envelopeEndNs==5_000_000_000 })
        for t in stride(from: Int64(50_000_000),to: 4_950_000_000,by: 37_000_000) {
            let row=try XCTUnwrap(overlays.first { $0.startNs<=t && t<$0.endNs })
            let expected=try project.query("{\"q\":\"effects_at\",\"tl_ns\":\(t)}",as: ActiveEffects.self)
            XCTAssertEqual(row.gain(atTimelineNs: t),try XCTUnwrap(expected.audio.first).gainAt,accuracy: 0.000_001)
        }
        // A recording-free source isolates our original loop from the AAC fixture track.
        let empty=package.appendingPathComponent("mix-only")
        try FileManager.default.createDirectory(at: empty.appendingPathComponent("recording"),withIntermediateDirectories: true)
        try Data("{\"segments\":[]}".utf8).write(to: empty.appendingPathComponent("recording/session.json"))
        let source=TestSource(package: empty,duration: 5_000_000_000,overlays: overlays)
        for range in [Int64(0)..<5_000_000_000,Int64(900_000_000)..<2_800_000_000] {
            let timeline=try AudioTimeline(project: source,range: range)
            let music=try XCTUnwrap(timeline.composition.tracks(withMediaType: .audio).first)
            let segments=music.segments.filter { !$0.isEmpty }
            let first=try XCTUnwrap(segments.first)
            let expectedFile=Double((7_500_000_000+range.lowerBound)%8_000_000_000)/1e9
            XCTAssertEqual(first.timeMapping.source.start.seconds,expectedFile,accuracy: 0.000_001)
            XCTAssertEqual(timeline.composition.duration.seconds,Double(range.count)/1e9,accuracy: 0.000_001)
            let parameter=try XCTUnwrap(timeline.mix.inputParameters.first)
            for t in stride(from: range.lowerBound+10_000_000,to: range.upperBound,by: 37_000_000) {
                let row=try XCTUnwrap(overlays.first { $0.startNs<=t && t<$0.endNs })
                let time=CMTime(value: t-range.lowerBound,timescale: 1_000_000_000)
                var a: Float=0,b: Float=0,ramp=CMTimeRange.zero
                XCTAssertTrue(parameter.getVolumeRamp(for: time,startVolume: &a,endVolume: &b,timeRange: &ramp))
                let value=a+(b-a)*Float((time-ramp.start).seconds/ramp.duration.seconds)
                XCTAssertEqual(value,row.gain(atTimelineNs: t),accuracy: 0.003,"No restarted fade at duck boundary")
            }
        }
        try project.apply(.set(path: "audio.music",value: .array([])))
        XCTAssertTrue(try project.renderAudioOverlays().isEmpty)
        XCTAssertEqual(try snapshot.renderAudioOverlays(),overlays,"Frozen audio edit generation")
        let clicks=try project.clicks()
        XCTAssertFalse(clicks.isEmpty,"Fixture contains mapped mouse-down events")
        for (variant,duration) in [("soft",Int64(80_000_000)),("crisp",Int64(50_000_000))] {
            try project.apply(.batch([
                .set(path: "audio.click_sound.enabled",value: .bool(true)),
                .set(path: "audio.click_sound.variant",value: .string(variant))
            ]))
            let sounds=try project.renderAudioOverlays()
            XCTAssertEqual(sounds.count,clicks.count)
            for (sound,click) in zip(sounds,clicks) {
                XCTAssertEqual(sound.source,variant=="soft" ? .click(.soft) : .click(.crisp))
                XCTAssertEqual(sound.startNs,click.tlNs)
                XCTAssertEqual(sound.endNs,min(project.durationNs,click.tlNs+duration))
            }
        }
    }
    func testImportedOriginalPCMAddsARealProjectMixSource() async throws {
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-file-music-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package=root.appendingPathComponent("fixture.yapcam")
        try FileManager.default.copyItem(at: fixture,to: package)
        let original=root.appendingPathComponent("own.wav")
        try ProceduralAudio.wav(ProceduralAudio.samples(for: .music(.bright))).write(to: original)
        let project=try Project.create(package: package)
        try await project.importMusic(original,startNs: 250_000_000,endNs: 4_750_000_000)
        try FileManager.default.removeItem(at: original)
        let source=try project.renderSnapshot()
        let overlay=try XCTUnwrap(source.renderAudioOverlays().first)
        guard case .media(let relative)=overlay.source else { return XCTFail("Imported owned PCM must use media, not a generated replacement") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent(relative).path))
        let timeline=try AudioTimeline(project: source,range: 500_000_000..<4_500_000_000)
        let tracks=timeline.composition.tracks(withMediaType: .audio)
        XCTAssertGreaterThanOrEqual(tracks.count,2,"Recording and imported music are both composed")
        XCTAssertGreaterThanOrEqual(timeline.mix.inputParameters.count,2)
        let music=try XCTUnwrap(tracks.last?.segments.first { !$0.isEmpty })
        XCTAssertEqual(music.timeMapping.source.start.seconds,0.25,accuracy: 0.000_001)
        XCTAssertEqual(music.timeMapping.target.start.seconds,0,accuracy: 0.000_001)
        XCTAssertEqual(timeline.composition.duration.seconds,4,accuracy: 0.000_001)
    }
    func testCoreClickStylesAndFileSourceMapWithoutThirdPartySamples() throws {
        func row(_ source: String) throws -> AudioOverlay {
            let data=Data("{\"source\":\"\(source)\",\"path\":\"assets/own.wav\",\"tl_start_ns\":100,\"tl_end_ns\":200,\"file_start_ns\":0,\"file_duration_ns\":1000,\"loop\":false,\"gain\":1,\"gain_start\":1,\"gain_end\":0.1,\"fade_in_ns\":0,\"fade_out_ns\":0,\"envelope_start_ns\":100,\"envelope_end_ns\":200}".utf8)
            let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(EvaluatedAudioOverlay.self,from: data).overlay()
        }
        XCTAssertEqual(try row("soft").source,.click(.soft))
        XCTAssertEqual(try row("crisp").source,.click(.crisp))
        XCTAssertEqual(try row("bright").source,.music(.bright))
        XCTAssertEqual(try row("file").source,.media(relativePath: "assets/own.wav"))
        XCTAssertEqual(try row("file").gain(atTimelineNs: 150),sqrt(0.1),accuracy: 0.000_001)
        XCTAssertThrowsError(try row("unsupported"))
    }
}
