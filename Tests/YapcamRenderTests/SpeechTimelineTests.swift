import XCTest
import AVFoundation
@testable import YapcamRender

private final class SpeechRangeSource: RenderProjectSource, @unchecked Sendable {
    let packageURL: URL
    let rows: [RenderAudioRange]
    let durationNs: Int64=1_000_000_000
    init(package: URL,includeMic: Bool = true) {
        packageURL=package
        // Both roles deliberately reference one file: enhancement must not leak into system audio.
        rows=([RenderAudioRange.Track.systemAudio]+(includeMic ? [.mic] : [])).map {
            RenderAudioRange(track: $0,path: "recording/voice.wav",fileStartNs: 0,fileEndNs: 2_000_000_000,tlStartNs: 0,tlEndNs: 1_000_000_000,gainStart: 0.5,gainEnd: 0.5)
        }
    }
    func frame(atNs: Int64) throws -> YcFrame { var f=YcFrame(); f.tl_ns=atNs; f.canvas_w=320; f.canvas_h=200; f.background_color=(0.1,0.2,0.3,1); f.click_progress = -1; return f }
    func renderSnapshot() throws -> any RenderProjectSource { self }
    func renderClips() throws -> [RenderClip] { [.init(srcStartNs: 0,srcEndNs: 2_000_000_000,speed: 2)] }
    func renderBackgroundAsset(index: UInt32) throws -> URL { throw RenderError.missingMedia("No background") }
    func renderAudioRanges() throws -> [RenderAudioRange]? { rows }
}

private final class SpeechTimelineCancellation: @unchecked Sendable {
    private let lock=NSLock()
    private var task: Task<AudioTimeline,Error>?
    private var requested=false
    func attach(_ task: Task<AudioTimeline,Error>) { lock.withLock { self.task=task; if requested { task.cancel() } } }
    func cancel() { lock.withLock { requested=true; task?.cancel() } }
    func clear() { lock.withLock { task=nil } }
}

final class SpeechTimelineTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-speech-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recording"),withIntermediateDirectories: true)
        try Data("{\"segments\":[]}".utf8).write(to: root.appendingPathComponent("recording/session.json"))
        let samples=(0..<96_000).map { Int16(0.07*sin(2*Double.pi*1000*Double($0)/48_000)*32767) }
        try ProceduralAudio.wav(samples).write(to: root.appendingPathComponent("recording/voice.wav"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testEnhancementReplacesOnlyMicrophoneAndPreservesSpeedTrimGainsAndCacheLifetime() async throws {
        let source=SpeechRangeSource(package: root), original=root.appendingPathComponent("recording/voice.wav")
        let before=try Data(contentsOf: original)
        var timeline: AudioTimeline?=try await AudioTimeline.prepare(project: source,range: 100_000_000..<800_000_000,speechEnhancement: .init(),cacheRoot: root)
        let replacement=try XCTUnwrap(timeline?.processedMicrophoneFiles[original])
        XCTAssertNotEqual(replacement,original)
        XCTAssertEqual(try Data(contentsOf: original),before)
        XCTAssertEqual(try AVAudioFile(forReading: replacement).length,96_000)
        let report=try XCTUnwrap(timeline?.speechReports.first)
        XCTAssertEqual(report.outputLUFS ?? .nan,-16,accuracy: 0.2)
        XCTAssertEqual(report.frames,96_000)
        let tracks=try XCTUnwrap(timeline).composition.tracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count,2)
        for (index,track) in tracks.enumerated() {
            let segment=try XCTUnwrap(track.segments.first { !$0.isEmpty })
            XCTAssertEqual(segment.sourceURL,index==0 ? replacement : original)
            XCTAssertEqual(segment.timeMapping.source.start.seconds,0.2,accuracy: 0.000_001)
            XCTAssertEqual(segment.timeMapping.source.duration.seconds,1.4,accuracy: 0.000_001)
            XCTAssertEqual(segment.timeMapping.target.start.seconds,0,accuracy: 0.000_001)
            XCTAssertEqual(segment.timeMapping.target.duration.seconds,0.7,accuracy: 0.000_001)
        }
        for parameter in try XCTUnwrap(timeline).mix.inputParameters {
            var start: Float=0,end: Float=0,ramp=CMTimeRange.zero
            XCTAssertTrue(parameter.getVolumeRamp(for: CMTime(seconds: 0.1,preferredTimescale: 1_000_000_000),startVolume: &start,endVolume: &end,timeRange: &ramp))
            XCTAssertEqual(start,0.5); XCTAssertEqual(end,0.5)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
        timeline=nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.path),"Temporary microphone cache lives exactly as long as the audio timeline")
        XCTAssertEqual(try Data(contentsOf: original),before)
    }
    func testDisabledAndNoMicrophonePathsDoNotCreateSpeechCaches() async throws {
        for (includeMic,settings) in [(true,Optional<SpeechEnhancementSettings>.none),(false,SpeechEnhancementSettings())] {
            let source=SpeechRangeSource(package: root,includeMic: includeMic)
            let timeline=try await AudioTimeline.prepare(project: source,range: 0..<source.durationNs,speechEnhancement: settings,cacheRoot: root)
            XCTAssertTrue(timeline.processedMicrophoneFiles.isEmpty); XCTAssertTrue(timeline.speechReports.isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix("yapcam-speech-mix-") })
        }
    }
    func testLegacyClipMappingRetainsMicrophoneOffsetAfterEnhancement() async throws {
        try Data("{\"segments\":[{\"index\":0,\"dir\":\"\",\"src_start_ns\":0,\"duration_ns\":2000000000,\"files\":{\"mic\":\"voice.wav\",\"system_audio\":\"voice.wav\"},\"track_start_ns\":{\"mic\":250000000}}]}".utf8).write(to: root.appendingPathComponent("recording/session.json"))
        let source=TestSource(package: root,duration: 1_000_000_000,clips: [.init(srcStartNs: 0,srcEndNs: 2_000_000_000,speed: 2)]) { ns in
            var f=YcFrame(); f.tl_ns=ns; f.mic_gain=0.5; f.system_gain=0.25; return f
        }
        let timeline=try await AudioTimeline.prepare(project: source,range: 100_000_000..<800_000_000,speechEnhancement: .init(),cacheRoot: root)
        let mic=try XCTUnwrap(timeline.composition.tracks(withMediaType: .audio).first?.segments.first { !$0.isEmpty })
        XCTAssertEqual(mic.timeMapping.target.start.seconds,0.025,accuracy: 0.000_001)
        XCTAssertEqual(mic.timeMapping.source.start.seconds,0,accuracy: 0.000_001)
        XCTAssertEqual(mic.timeMapping.target.duration.seconds,0.675,accuracy: 0.000_001)
        XCTAssertEqual(mic.timeMapping.source.duration.seconds,1.35,accuracy: 0.000_001)
        XCTAssertEqual(timeline.speechReports.count,1)
    }
    func testCancellationDuringSpeechProcessingJoinsAndRemovesTemporaryMedia() async throws {
        let source=SpeechRangeSource(package: root), root=try XCTUnwrap(root), cancellation=SpeechTimelineCancellation()
        let before=try Data(contentsOf: root.appendingPathComponent("recording/voice.wav"))
        let task=Task { try await AudioTimeline.prepare(project: source,range: 0..<source.durationNs,speechEnhancement: .init(),cacheRoot: root) { value in
            if value>0.05 { cancellation.cancel() }
        } }
        cancellation.attach(task); defer { cancellation.clear() }
        do { _ = try await task.value; XCTFail("Cancelled preparation must not publish a timeline") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix("yapcam-speech-mix-") })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("recording/voice.wav")),before)
    }
    func testOldExportSettingsDecodeWithEnhancementOffAndNewSettingsRoundTrip() throws {
        let data=Data("{\"format\":\"mp4\",\"codec\":\"h264\",\"outputHeight\":1080,\"fps\":30,\"quality\":0.8,\"includeAudio\":true}".utf8)
        XCTAssertNil(try JSONDecoder().decode(ExportSettings.self,from: data).speechEnhancement)
        let settings=ExportSettings(speechEnhancement: .init())
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self,from: JSONEncoder().encode(settings)),settings)
        var invalid=settings; invalid.speechEnhancement?.targetLUFS = .nan
        XCTAssertThrowsError(try invalid.validatedRange(duration: 1_000_000_000))
    }
    func testEnhancedMicrophoneReachesExportWithVerifiedAudioAndReportsOnHost() async throws {
        _ = try requireRenderDevice()
        let source=SpeechRangeSource(package: root)
        let destination=root.appendingPathComponent("enhanced.mp4")
        let exporter=try Exporter(project: source,settings: .init(outputHeight: 720,rangeStartNs: 100_000_000,rangeEndNs: 800_000_000,speechEnhancement: .init()),destination: destination)
        _ = try await exporter.run { _ in }
        let report=try XCTUnwrap(exporter.speechEnhancementReports.first)
        XCTAssertTrue(report.reachedTarget)
        let asset=AVURLAsset(url: destination)
        let audio=try await asset.loadTracks(withMediaType: .audio)
        let duration=try await asset.load(.duration)
        XCTAssertEqual(audio.count,1)
        XCTAssertEqual(duration.seconds,0.7,accuracy: 1/30.0)
    }
    @MainActor func testEnhancedPreviewRetainsLatestSeekAndToggleClearsReportsOnHost() async throws {
        _ = try requireRenderDevice()
        let source=SpeechRangeSource(package: root)
        let player=try PreviewPlayer(project: source,speechEnhancement: .init())
        defer { player.pause() }
        player.seek(toNs: 650_000_000,precise: true)
        let deadline=ProcessInfo.processInfo.systemUptime+10
        while player.speechEnhancementReports.isEmpty && player.error==nil && ProcessInfo.processInfo.systemUptime<deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(player.error)
        XCTAssertTrue(try XCTUnwrap(player.speechEnhancementReports.first).reachedTarget)
        XCTAssertEqual(player.currentNs,650_000_000,"Preparation must honor the user's latest seek")
        try player.setSpeechEnhancement(nil)
        XCTAssertNil(player.speechEnhancementSettings)
        XCTAssertTrue(player.speechEnhancementReports.isEmpty)
        XCTAssertEqual(player.currentNs,650_000_000)
    }
}
