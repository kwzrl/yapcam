@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import YapcamCapture

private struct SpeechFixture {
    let root: URL
    let package: URL
    let manifest: SessionManifest
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-transcription-\(UUID())")
        package = root.appendingPathComponent("Speech.yapcam")
        for dir in ["seg-000", "seg-001"] {
            let directory = package.appendingPathComponent("recording/\(dir)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in ["mic.m4a", "system.m4a"] { try Data("injected recognizer fixture".utf8).write(to: directory.appendingPathComponent(file)) }
        }
        manifest = SessionManifest(status: "complete", source: SourceMetadata(kind: "display", displayID: 2,
            contentRectPoints: [0, 0, 64, 64], scale: 1), tracks: TrackMetadata(screen: ScreenMetadata(pixelSize: [64, 64], maxFPS: 60)), segments: [
                SegmentMetadata(index: 0, dir: "seg-000", srcStartNs: 0, durationNs: 5_000_000_000, hostStartNs: 10_000_000_000,
                    files: ["mic": "seg-000/mic.m4a", "system_audio": "seg-000/system.m4a"],
                    trackStartNs: ["mic": 100_000_000, "system_audio": 50_000_000]),
                SegmentMetadata(index: 1, dir: "seg-001", srcStartNs: 5_000_000_000, durationNs: 3_000_000_000, hostStartNs: 100_000_000_000,
                    files: ["system_audio": "seg-001/system.m4a"], trackStartNs: ["system_audio": 200_000_000])
            ])
        try save(manifest)
    }
    func save(_ manifest: SessionManifest) throws {
        try PackageIO.write(manifest, to: package.appendingPathComponent("recording/session.json"))
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    var transcript: URL { package.appendingPathComponent("recording/transcript.json") }
}

@Test func transcriptPrefersMicFallsBackPerSegmentAndUsesPauseRemovedSourceTime() async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    let service = TranscriptionService { url, locale in
        #expect(locale == "en-US")
        if url.deletingLastPathComponent().lastPathComponent == "seg-000" {
            #expect(url.lastPathComponent == "mic.m4a")
            return [RecognizedSpeechWord(text: "Hello", startNs: 0, endNs: 400_000_000, confidence: 0.9)]
        }
        #expect(url.lastPathComponent == "system.m4a")
        return [RecognizedSpeechWord(text: "again", startNs: 100_000_000, endNs: 600_000_000, confidence: 0.8),
                RecognizedSpeechWord(text: "tail", startNs: 2_600_000_000, endNs: 4_000_000_000, confidence: 0.7)]
    }
    let transcript = try await service.transcribe(package: fixture.package, localeIdentifier: "en-US")
    #expect(transcript.words.map(\.text) == ["Hello", "again", "tail"])
    #expect(transcript.words.map(\.srcStartNs) == [100_000_000, 5_300_000_000, 7_800_000_000])
    #expect(transcript.words.map(\.srcEndNs) == [500_000_000, 5_800_000_000, 8_000_000_000])
    #expect(transcript.words.map(\.track) == [.microphone, .systemAudio, .systemAudio])
    let data = try Data(contentsOf: fixture.transcript)
    #expect(try JSONDecoder().decode(RecordingTranscript.self, from: data) == transcript)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["schema_version"] as? Int == 1)
    #expect(json["engine"] as? String == "apple_speech_on_device")
    let words = try #require(json["words"] as? [[String: Any]])
    #expect(words[0]["src_start_ns"] as? Int64 == 100_000_000)
    #expect(words[0]["segment_index"] as? Int == 0)
    #expect(words[0]["track"] as? String == "mic")
}

@Test func explicitTranscriptionTrackDoesNotSwitchToAnotherTrack() async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    let service = TranscriptionService { url, _ in
        #expect(url.lastPathComponent == "mic.m4a")
        return [RecognizedSpeechWord(text: "mic", startNs: 0, endNs: 1, confidence: 1)]
    }
    let result = try await service.transcribe(package: fixture.package, track: .microphone)
    #expect(result.words.count == 1)
    #expect(result.words[0].segmentIndex == 0)
}

@Test func transcriptClipsOvershootingWordsAndRejectsInvalidRecognitionTimes() async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    let service = TranscriptionService { _, _ in [
        RecognizedSpeechWord(text: "negative", startNs: -1, endNs: 1, confidence: 1),
        RecognizedSpeechWord(text: "zero", startNs: 0, endNs: 0, confidence: 1),
        RecognizedSpeechWord(text: "late", startNs: Int64.max, endNs: Int64.max, confidence: 1),
        RecognizedSpeechWord(text: "clip", startNs: 4_800_000_000, endNs: Int64.max, confidence: .nan)
    ] }
    let result = try await service.transcribe(package: fixture.package)
    #expect(result.words.map(\.text) == ["clip"])
    #expect(result.words[0].srcStartNs == 4_900_000_000)
    #expect(result.words[0].srcEndNs == 5_000_000_000)
    #expect(result.words[0].confidence == 0)
}

@Test func successfulTranscriptionReplacementKeepsPreviousVersion() async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    let previous = Data("previous transcript".utf8)
    try previous.write(to: fixture.transcript)
    let service = TranscriptionService { _, _ in [] }
    _ = try await service.transcribe(package: fixture.package)
    #expect(try Data(contentsOf: fixture.transcript.appendingPathExtension("prev")) == previous)
    #expect(try JSONDecoder().decode(RecordingTranscript.self, from: Data(contentsOf: fixture.transcript)).words.isEmpty)
}

@Test func failedTranscriptionKeepsExistingTranscriptAndReleasesPackage() async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    let old = Data("previous transcript".utf8)
    try old.write(to: fixture.transcript)
    let service = TranscriptionService { url, _ in
        if url.deletingLastPathComponent().lastPathComponent == "seg-001" { throw TranscriptionError.onDeviceUnavailable("en-US") }
        return [RecognizedSpeechWord(text: "partial", startNs: 0, endNs: 1, confidence: 1)]
    }
    await #expect(throws: TranscriptionError.onDeviceUnavailable("en-US")) {
        try await service.transcribe(package: fixture.package)
    }
    #expect(try Data(contentsOf: fixture.transcript) == old)
    #expect(RecordingPackageLease.isAvailable(fixture.package))
}

@Test func cancelledTranscriptionDoesNotPublishPartialOutput() async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    let (started, signal) = AsyncStream<Void>.makeStream()
    let service = TranscriptionService { _, _ in
        signal.yield(()); signal.finish()
        try await Task.sleep(for: .seconds(60))
        return []
    }
    let task = Task { try await service.transcribe(package: fixture.package) }
    for await _ in started { break }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: fixture.transcript.path))
    #expect(RecordingPackageLease.isAvailable(fixture.package))
}

@Test func activeAndUnfinishedPackagesAreNotTranscribed() async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    let service = TranscriptionService { _, _ in Issue.record("Should not recognize an active recording"); return [] }
    var lease: RecordingPackageLease? = try RecordingPackageLease(package: fixture.package)
    await #expect(throws: CaptureError.self) { try await service.transcribe(package: fixture.package) }
    withExtendedLifetime(lease) {}; lease = nil
    var manifest = fixture.manifest; manifest.status = "recording"
    try fixture.save(manifest)
    await #expect(throws: TranscriptionError.self) { try await service.transcribe(package: fixture.package) }
}

@Test(arguments: ["../outside.m4a", "/tmp/outside.m4a", "seg-000/../../outside.m4a"])
func transcriptionRejectsEscapingMediaPaths(path: String) async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    var manifest = fixture.manifest; manifest.segments[0].files["mic"] = path
    try fixture.save(manifest)
    let service = TranscriptionService { _, _ in Issue.record("Escaping path reached recognizer"); return [] }
    await #expect(throws: TranscriptionError.self) { try await service.transcribe(package: fixture.package) }
}

@Test func transcriptionRejectsEscapingSymlinksAndMissingOffsets() async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    let external = fixture.root.appendingPathComponent("external.m4a")
    try Data().write(to: external)
    let mic = fixture.package.appendingPathComponent("recording/seg-000/mic.m4a")
    try FileManager.default.removeItem(at: mic)
    try FileManager.default.createSymbolicLink(at: mic, withDestinationURL: external)
    let service = TranscriptionService { _, _ in Issue.record("Invalid media reached recognizer"); return [] }
    await #expect(throws: TranscriptionError.self) { try await service.transcribe(package: fixture.package) }
    var manifest = fixture.manifest; manifest.segments[0].trackStartNs.removeValue(forKey: "mic")
    try fixture.save(manifest)
    await #expect(throws: TranscriptionError.self) { try await service.transcribe(package: fixture.package) }
}

@Test func speechChunkWindowsAreBoundedAndOwnershipIsContiguous() throws {
    let windows = try SpeechChunking.windows(frameCount: 100 * 48_000, sampleRate: 48_000)
    let starts: [Int64] = [0, 2_112_000, 4_224_000]
    let lengths: [AVAudioFrameCount] = [2_160_000, 2_160_000, 576_000]
    #expect(windows.map(\.startFrame) == starts)
    #expect(windows.map(\.frameCount) == lengths)
    for pair in zip(windows, windows.dropFirst()) {
        #expect(pair.0.startFrame + pair.0.ownedEndFrame == pair.1.startFrame + pair.1.ownedStartFrame)
    }
    #expect(windows.last!.startFrame + windows.last!.ownedEndFrame == 100 * 48_000)
    #expect(SpeechChunking.nanoseconds(.nan) == nil)
    #expect(SpeechChunking.nanoseconds(.infinity) == nil)
    #expect(SpeechChunking.nanoseconds(-1) == nil)
    #expect(SpeechChunking.nanoseconds(0.123456789) == 123_456_789)
}

@Test func overlappedSpeechWordsAreOwnedOnceAtTheBoundary() {
    let first = RecognizedSpeechWord(text: "boundary", startNs: 44_400_000_000, endNs: 44_600_000_000, confidence: 1)
    #expect(SpeechChunking.shifted([first], startNs: 0, ownedStartNs: 0, ownedEndNs: 44_500_000_000).isEmpty)
    let next = RecognizedSpeechWord(text: "boundary", startNs: 400_000_000, endNs: 600_000_000, confidence: 1)
    let result = SpeechChunking.shifted([next], startNs: 44_000_000_000, ownedStartNs: 500_000_000, ownedEndNs: 44_500_000_000)
    #expect(result.count == 1)
    #expect(result[0].startNs == first.startNs)
    #expect(result[0].endNs == first.endNs)
}

private final class SpeechCancellationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Test func speechJobResolvesOnceAndCancelsEvenWithImmediateFinalCallback() async throws {
    let counter = SpeechCancellationCount()
    let result = try await SpeechRecognitionJob().run { complete in
        complete(.success([RecognizedSpeechWord(text: "hello", startNs: 0, endNs: 1, confidence: 1)]))
        complete(.failure(TranscriptionError.timedOut))
        return { counter.increment() }
    }
    #expect(result.map(\.text) == ["hello"])
    #expect(counter.count == 1)
}

@Test func speechJobTimesOutAndCancelsUnresponsiveRecognition() async {
    let counter = SpeechCancellationCount()
    await #expect(throws: TranscriptionError.timedOut) {
        try await SpeechRecognitionJob().run(timeout: .milliseconds(1)) { _ in { counter.increment() } }
    }
    #expect(counter.count == 1)
}

@Test func speechJobCancellationStopsInFlightRecognition() async {
    let counter = SpeechCancellationCount()
    let (started, signal) = AsyncStream<Void>.makeStream()
    let task = Task {
        try await SpeechRecognitionJob().run { _ in
            signal.yield(()); signal.finish()
            return { counter.increment() }
        }
    }
    for await _ in started { break }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(counter.count == 1)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["YAPCAM_TRANSCRIPTION_MEDIA_TESTS"] == "1"))
func actualOnDeviceTranscriptionOfSaySpeech() async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    print("TRANSCRIPTION speech permission: \(TranscriptionService.authorizationState)")
    let audio = fixture.package.appendingPathComponent("recording/seg-000/speech.aiff")
    let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Samantha", "-r", "140", "-o", audio.path, "Hello. This is a local speech transcription test."]
    try say.run(); say.waitUntilExit()
    #expect(say.terminationStatus == 0)
    let file = try AVAudioFile(forReading: audio)
    guard file.length > 0 else { throw TranscriptionError.recognitionFailed("say produced zero audio frames; run this test on the host") }
    var manifest = fixture.manifest
    manifest.segments = [manifest.segments[0]]
    manifest.segments[0].files = ["mic": "seg-000/speech.aiff"]
    manifest.segments[0].durationNs = 100_000_000 + Int64(Double(file.length) / file.processingFormat.sampleRate * 1_000_000_000) + 100_000_000
    try fixture.save(manifest)
    let transcript = try await TranscriptionService().transcribe(package: fixture.package, localeIdentifier: "en-US")
    let text = transcript.words.map(\.text).joined(separator: " ").lowercased()
    #expect(text.contains("hello") && text.contains("speech") && text.contains("test"))
    #expect(transcript.words.allSatisfy { $0.srcStartNs >= 100_000_000 && $0.srcEndNs <= manifest.segments[0].durationNs })
    #expect(FileManager.default.fileExists(atPath: fixture.transcript.path))
}
