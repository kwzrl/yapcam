import XCTest
import AVFoundation
import YapcamCore
@testable import YapcamRender

final class EnhancedMicrophoneTests: XCTestCase {
    func testCoreSelectionFeedsOnlyMicrophoneThroughSharedPreparationAndKeepsSnapshotClocks() async throws {
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-selected-mic-\(UUID().uuidString).yapcam")
        defer { print("Cleanup render-owned selected microphone fixture: \(root.path)"); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture,to: root)
        let original=root.appendingPathComponent("recording/seg-000/voice.caf"), derivative=root.appendingPathComponent("silent.caf")
        try Self.writePCM(original,silent: false); try Self.writePCM(derivative,silent: true)
        let originalBytes=try Data(contentsOf: original)
        let session=root.appendingPathComponent("recording/session.json")
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: session)) as? [String:Any])
        var segment=try XCTUnwrap((json["segments"] as? [[String:Any]])?.first)
        var files=try XCTUnwrap(segment["files"] as? [String:String])
        files.removeValue(forKey: "events"); files.removeValue(forKey: "cursors")
        // Deliberately share the original file across mic/system tracks: selecting
        // a mic derivative must never redirect the system track to that derivative.
        files["mic"]="seg-000/voice.caf"; files["system_audio"]="seg-000/voice.caf"
        segment["files"]=files; segment["duration_ns"]=1_250_000_000
        segment["track_start_ns"]=["screen":0,"mic":250_000_000,"system_audio":250_000_000]
        json["segments"]=[segment]
        try JSONSerialization.data(withJSONObject: json).write(to: session)
        let manifestBytes=try Data(contentsOf: session), project=try Project.create(package: root)
        try project.apply(.split(atNs: 500_000_000))
        let first=try XCTUnwrap(project.query("{\"q\":\"clips\"}",as: [ClipInfo].self).first)
        try project.apply(.setSpeed(clipID: first.id,speed: 1.4))
        let frozen=try project.renderSnapshot(), originalRanges=try XCTUnwrap(frozen.renderAudioRanges())
        let identity=try project.microphoneIdentity(path: "recording/seg-000/voice.caf")
        try await project.importEnhancedMicrophone(derivative,forOriginal: identity)
        let selected=try XCTUnwrap(project.microphoneMedia().first)
        XCTAssertTrue(selected.enhanced)
        let effective=root.appendingPathComponent(selected.path)
        let rows=try XCTUnwrap(project.renderAudioRanges())
        XCTAssertEqual(rows.count,originalRanges.count)
        for (before,after) in zip(originalRanges,rows) {
            XCTAssertEqual(after.track,before.track)
            XCTAssertEqual(after.path,before.track == .mic ? selected.path : before.path)
            XCTAssertEqual(after.fileStartNs,before.fileStartNs); XCTAssertEqual(after.fileEndNs,before.fileEndNs)
            XCTAssertEqual(after.tlStartNs,before.tlStartNs); XCTAssertEqual(after.tlEndNs,before.tlEndNs)
            XCTAssertEqual(after.gainStart,before.gainStart); XCTAssertEqual(after.gainEnd,before.gainEnd)
        }
        let timeline=try await AudioTimeline.prepare(project: project.renderSnapshot(),range: 0..<project.durationNs,cacheRoot: root)
        let mono=try XCTUnwrap(timeline.processedMicrophoneFiles[effective])
        XCTAssertTrue(timeline.speechReports.isEmpty,"Selecting existing enhanced media does not implicitly enable another DSP pass")
        XCTAssertNil(timeline.processedMicrophoneFiles[original])
        let file=try AVAudioFile(forReading: mono,commonFormat: .pcmFormatFloat32,interleaved: false)
        XCTAssertEqual(file.processingFormat.channelCount,1); XCTAssertEqual(file.length,48_000)
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,frameCapacity: 4096))
        var count=0
        while file.framePosition<file.length {
            try file.read(into: buffer)
            guard buffer.frameLength>0 else { throw RenderError.decode("Selected microphone ended early") }
            let samples=UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0],count: Int(buffer.frameLength))
            XCTAssertTrue(samples.allSatisfy { $0==0 },"Render must read selected PCM bytes, not only return the new URL")
            count += samples.count
        }
        XCTAssertEqual(count,48_000)
        let urls=Set(timeline.composition.tracks(withMediaType: .audio).flatMap { $0.segments ?? [] }.compactMap(\.sourceURL))
        XCTAssertTrue(urls.contains(mono)); XCTAssertTrue(urls.contains(original)); XCTAssertFalse(urls.contains(effective))
        let prior=try await AudioTimeline.prepare(project: frozen,range: 0..<frozen.durationNs,cacheRoot: root)
        XCTAssertNotNil(prior.processedMicrophoneFiles[original]); XCTAssertNil(prior.processedMicrophoneFiles[effective])
        try project.save()
        let reopened=try Project.open(package: root)
        XCTAssertEqual(try reopened.renderAudioRanges()?.map(\.path),rows.map(\.path))
        try project.useOriginalMicrophone(path: identity.path)
        let restored=try await AudioTimeline.prepare(project: project.renderSnapshot(),range: 0..<project.durationNs,cacheRoot: root)
        XCTAssertNotNil(restored.processedMicrophoneFiles[original]); XCTAssertNil(restored.processedMicrophoneFiles[effective])
        XCTAssertEqual(try Data(contentsOf: original),originalBytes)
        XCTAssertEqual(try Data(contentsOf: session),manifestBytes)
    }

    private static func writePCM(_ url: URL,silent: Bool) throws {
        let format=try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,sampleRate: 48_000,channels: 2,interleaved: false))
        var settings=format.settings; settings[AVLinearPCMIsNonInterleaved]=false
        let file=try AVAudioFile(forWriting: url,settings: settings,commonFormat: .pcmFormatFloat32,interleaved: false)
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 48_000))
        buffer.frameLength=48_000
        let data=try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<48_000 { data[0][i]=silent ? 0 : 0.4; data[1][i]=silent ? 0 : 0.1 }
        try file.write(from: buffer)
    }
}
