import XCTest
import AVFoundation
import YapcamCore
@testable import YapcamRender

final class MicrophoneChannelTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-mic-channels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recording"),withIntermediateDirectories: true)
        try Data("{\"segments\":[]}".utf8).write(to: root.appendingPathComponent("recording/session.json"))
    }
    override func tearDownWithError() throws {
        if let root { print("Cleanup render-owned microphone fixture: \(root.path)"); try FileManager.default.removeItem(at: root) }
    }
    private func input(channels: AVAudioChannelCount,invalid: Bool = false) throws -> URL {
        let url=root.appendingPathComponent("recording/voice.caf")
        let format=try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,sampleRate: 48_000,channels: channels,interleaved: false))
        var settings=format.settings; settings[AVLinearPCMIsNonInterleaved]=false
        let file=try AVAudioFile(forWriting: url,settings: settings,commonFormat: .pcmFormatFloat32,interleaved: false)
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 48_000))
        buffer.frameLength=48_000
        let data=try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<48_000 {
            data[0][i]=Float(sin(Double(i)*2*Double.pi*880/48_000))*0.4
            if channels==2 { data[1][i]=Float(sin(Double(i)*2*Double.pi*440/48_000))*0.1 }
        }
        if invalid { data[0][1024] = .nan }
        try file.write(from: buffer)
        return url
    }
    func testMonoAveragesOnlyMicrophonePreservesTimingInputAndCacheLifetime() async throws {
        let original=try input(channels: 2), before=try Data(contentsOf: original)
        var timeline: AudioTimeline?=try await AudioTimeline.prepare(project: ChannelSource(package: root,stereo: false),range: 0..<800_000_000,cacheRoot: root)
        let converted=try XCTUnwrap(timeline?.processedMicrophoneFiles[original])
        let file=try AVAudioFile(forReading: converted,commonFormat: .pcmFormatFloat32,interleaved: false)
        XCTAssertEqual(file.length,48_000); XCTAssertEqual(file.processingFormat.channelCount,1)
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,frameCapacity: 48_000))
        var samples: [Float]=[]
        // A file read may return fewer frames than capacity before EOF.
        while file.framePosition<file.length {
            try file.read(into: buffer)
            guard buffer.frameLength>0 else { throw RenderError.decode("Converted microphone ended early") }
            samples.append(contentsOf: UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0],count: Int(buffer.frameLength)))
        }
        XCTAssertEqual(samples.count,48_000)
        for i in [1,117,2345,30_000,47_999] {
            let expected=(sin(Double(i)*2*Double.pi*880/48_000)*0.4+sin(Double(i)*2*Double.pi*440/48_000)*0.1)*0.5
            XCTAssertEqual(Double(samples[i]),expected,accuracy: 0.000001,"Channel conversion must not apply DSP, gain or limiting")
        }
        XCTAssertTrue(try XCTUnwrap(timeline).speechReports.isEmpty)
        let segments=try XCTUnwrap(timeline).composition.tracks(withMediaType: .audio).flatMap { $0.segments ?? [] }.filter { !$0.isEmpty }
        XCTAssertEqual(Set(segments.compactMap(\.sourceURL)),Set([original,converted]),"System audio must retain the original stereo source")
        for segment in segments {
            XCTAssertEqual(segment.timeMapping.source.start.seconds,0.1,accuracy: 0.000001)
            XCTAssertEqual(segment.timeMapping.source.duration.seconds,0.8,accuracy: 0.000001)
            XCTAssertEqual(segment.timeMapping.target.start.seconds,0,accuracy: 0.000001)
            XCTAssertEqual(segment.timeMapping.target.duration.seconds,0.8,accuracy: 0.000001)
        }
        XCTAssertEqual(try Data(contentsOf: original),before)
        timeline=nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: converted.path))
    }
    func testStereoAndAlreadyMonoNeedNoConvertedCacheAndDSPUsesChosenChannels() async throws {
        let original=try input(channels: 2)
        let preserved=try await AudioTimeline.prepare(project: ChannelSource(package: root,stereo: true),range: 0..<800_000_000,cacheRoot: root)
        XCTAssertTrue(preserved.processedMicrophoneFiles.isEmpty)
        for stereo in [false,true] {
            let enhanced=try await AudioTimeline.prepare(project: ChannelSource(package: root,stereo: stereo),range: 0..<800_000_000,speechEnhancement: .init(),cacheRoot: root)
            XCTAssertEqual(try XCTUnwrap(enhanced.speechReports.first).channels,stereo ? 2 : 1)
        }
        try FileManager.default.removeItem(at: original)
        _ = try input(channels: 1)
        let mono=try await AudioTimeline.prepare(project: ChannelSource(package: root,stereo: false),range: 0..<800_000_000,cacheRoot: root)
        XCTAssertTrue(mono.processedMicrophoneFiles.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix("yapcam-speech-mix-") })
    }
    func testCorePreferenceFollowsSnapshotsAndSaveReopen() throws {
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let package=root.appendingPathComponent("project.yapcam")
        try FileManager.default.copyItem(at: fixture,to: package)
        let project=try Project.create(package: package), frozen=try project.renderSnapshot()
        XCTAssertFalse(try project.renderStereoMicrophone())
        try project.apply(.set(path: "audio.stereo_mic",value: .bool(true)))
        XCTAssertTrue(try project.renderStereoMicrophone())
        XCTAssertFalse(try frozen.renderStereoMicrophone())
        try project.save()
        XCTAssertTrue(try Project.open(package: package).renderStereoMicrophone())
        XCTAssertTrue(try TestSource(package: package).renderStereoMicrophone(),"Custom-source default preserves legacy channels")
    }
    func testCancellationAndInvalidPCMRemoveConvertedFilesWithoutChangingInput() async throws {
        let original=try input(channels: 2), before=try Data(contentsOf: original)
        let cancellation=ChannelCancellation(), cache=try XCTUnwrap(root)
        let source=ChannelSource(package: cache,stereo: false)
        let task=Task { try await AudioTimeline.prepare(project: source,range: 0..<800_000_000,cacheRoot: cache) { progress in
            if progress>0.05 { cancellation.cancel() }
        } }
        cancellation.attach(task); defer { cancellation.clear() }
        do { _ = try await task.value; XCTFail("Cancelled mono preparation must not publish") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: original),before)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.path).allSatisfy { !$0.hasPrefix("yapcam-speech-mix-") })
        try FileManager.default.removeItem(at: original)
        _ = try input(channels: 2,invalid: true)
        let invalidBytes=try Data(contentsOf: original)
        do { _ = try await AudioTimeline.prepare(project: source,range: 0..<800_000_000,cacheRoot: cache); XCTFail("Nonfinite audio must fail explicitly") }
        catch is RenderError {} catch { XCTFail("Unexpected invalid-PCM error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: original),invalidBytes)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.path).allSatisfy { !$0.hasPrefix("yapcam-speech-mix-") })
    }
    func testCompressedMonoPreferencePreservesOffsetReaderTailAndExportOnHost() async throws {
        _ = try requireRenderDevice()
        let pcm=try input(channels: 2), aac=root.appendingPathComponent("recording/voice.m4a")
        let export=try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: pcm),presetName: AVAssetExportPresetAppleM4A))
        export.outputURL=aac; export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else { throw RenderError.write(export.error?.localizedDescription ?? "AAC fixture export failed") }
        let original=try Data(contentsOf: aac)
        try Data("{\"segments\":[{\"index\":0,\"dir\":\"\",\"src_start_ns\":0,\"duration_ns\":1250000000,\"files\":{\"mic\":\"voice.m4a\"},\"track_start_ns\":{\"mic\":250000000}}]}".utf8).write(to: root.appendingPathComponent("recording/session.json"))
        let source=ChannelSource(package: root,stereo: false,usesRanges: false)
        let timeline=try await AudioTimeline.prepare(project: source,range: 0..<source.durationNs,cacheRoot: root)
        let converted=try XCTUnwrap(timeline.processedMicrophoneFiles[aac])
        let audio=try AVAudioFile(forReading: converted)
        XCTAssertEqual(audio.processingFormat.channelCount,1)
        let media=try XCTUnwrap(AVURLAsset(url: aac).tracks(withMediaType: .audio).first).timeRange
        XCTAssertEqual(audio.length,CMTimeConvertScale(media.end,timescale: 48_000,method: .roundHalfAwayFromZero).value)
        let segment=try XCTUnwrap(timeline.composition.tracks(withMediaType: .audio).flatMap { $0.segments ?? [] }.first { $0.sourceURL==converted })
        XCTAssertEqual(segment.timeMapping.target.start.seconds,0.25,accuracy: 1/48_000)
        let (reader,output)=try XCTUnwrap(timeline.reader(rangeDuration: source.durationNs))
        var end=CMTime.zero
        while let sample=output.copyNextSampleBuffer() { end=CMSampleBufferGetPresentationTimeStamp(sample)+CMSampleBufferGetDuration(sample) }
        XCTAssertEqual(reader.status,.completed,String(describing: reader.error))
        XCTAssertEqual(end.seconds,1.25,accuracy: 1/48_000)
        let video=root.appendingPathComponent("mono.mp4")
        _ = try await Exporter(project: source,settings: .init(outputHeight: 720,fps: 30),destination: video).run { _ in }
        XCTAssertEqual(try Data(contentsOf: aac),original)
    }
}

private final class ChannelCancellation: @unchecked Sendable {
    private let lock=NSLock()
    private var task: Task<AudioTimeline,Error>?
    private var requested=false
    func attach(_ task: Task<AudioTimeline,Error>) { lock.withLock { self.task=task; if requested { task.cancel() } } }
    func cancel() { lock.withLock { requested=true; task?.cancel() } }
    func clear() { lock.withLock { task=nil } }
}

private final class ChannelSource: RenderProjectSource, @unchecked Sendable {
    let packageURL: URL
    var durationNs: Int64 { usesRanges ? 800_000_000 : 1_250_000_000 }
    let stereo: Bool
    let usesRanges: Bool
    init(package: URL,stereo: Bool,usesRanges: Bool = true) { packageURL=package; self.stereo=stereo; self.usesRanges=usesRanges }
    func renderStereoMicrophone() throws -> Bool { stereo }
    func renderSnapshot() throws -> any RenderProjectSource { self }
    func renderClips() throws -> [RenderClip] { usesRanges ? [] : [.init(srcStartNs: 0,srcEndNs: durationNs)] }
    func renderAudioRanges() throws -> [RenderAudioRange]? {
        usesRanges ? [.mic,.systemAudio].map { RenderAudioRange(track: $0,path: "recording/voice.caf",fileStartNs: 100_000_000,fileEndNs: 900_000_000,tlStartNs: 0,tlEndNs: 800_000_000,gainStart: 1,gainEnd: 1) } : nil
    }
    func renderBackgroundAsset(index: UInt32) throws -> URL { throw RenderError.missingMedia("No image") }
    func frame(atNs: Int64) throws -> YcFrame { var f=YcFrame(); f.canvas_w=320; f.canvas_h=200; f.tl_ns=atNs; f.click_progress = -1; f.background_color=(0,0,0,1); f.mic_gain=1; f.system_gain=1; return f }
}
