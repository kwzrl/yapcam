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
    #expect(!FileManager.default.fileExists(atPath: fixture.package.appendingPathComponent("recording/.capture.lock").path))
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

private final class SpeechLocaleCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ locale: String) { lock.withLock { values.append(locale) } }
    var locales: [String] { lock.withLock { values } }
}

@Test func automaticLanguageDetectionRetranscribesGermanAndPersistsDetectedLocale() async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    let calls = SpeechLocaleCalls()
    let service = TranscriptionService(
        recognizeRequest: { _, locale, _ in
            calls.append(locale)
            return RecognizedSpeech(words: [RecognizedSpeechWord(
                text: "Guten", startNs: 0, endNs: 100_000_000, confidence: 1
            )])
        },
        recognizePreview: { _, locale, _ in
            #expect(locale == "en-US")
            return RecognizedSpeech(words: [
                RecognizedSpeechWord(text: "Guten Morgen.", startNs: 0, endNs: 500_000_000, confidence: 1),
                RecognizedSpeechWord(text: "Heute testen wir die automatische Spracherkennung mit einem längeren deutschen Beispielsatz.",
                                     startNs: 500_000_000, endNs: 2_000_000_000, confidence: 1)
            ])
        },
        detectLanguage: {
            SpeechLanguageDetection.localeIdentifier(in: $0, supported: [Locale(identifier: "en-US"), Locale(identifier: "de-DE")],
                                                        systemLocaleIdentifier: "en-US")
        },
        systemLocaleIdentifier: "en-US"
    )

    let transcript = try await service.transcribe(package: fixture.package, localeIdentifier: "auto")

    #expect(calls.locales == ["de-DE", "de-DE"])
    #expect(transcript.locale == "de-DE")
    let persisted = try JSONDecoder().decode(RecordingTranscript.self, from: Data(contentsOf: fixture.transcript))
    #expect(persisted.locale == "de-DE")
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

@Test func noSpeechMiddleWindowKeepsBothSpokenWindowsAndPublishesPartialWarning() async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    var manifest = fixture.manifest
    manifest.segments = [manifest.segments[0]]
    manifest.segments[0].durationNs = 100_000_000_000
    try fixture.save(manifest)
    let cancellations = SpeechCancellationCount()
    let service = TranscriptionService(recognizeWithWarnings: { _, _ in
        let windows = try SpeechChunking.windows(frameCount: 100 * 48_000, sampleRate: 48_000)
        return try await SpeechChunking.collect(windows: windows, sampleRate: 48_000) { window in
            try await SpeechRecognitionJob().run { complete in
                switch window.startFrame {
                case 0:
                    complete(.success([RecognizedSpeechWord(text: "before", startNs: 2_000_000_000, endNs: 3_000_000_000, confidence: 1)]))
                case 44 * 48_000:
                    complete(.failure(NSError(domain: "kAFAssistantErrorDomain", code: 1110,
                                              userInfo: [NSLocalizedDescriptionKey: "No speech detected"])))
                default:
                    complete(.success([RecognizedSpeechWord(text: "after", startNs: 4_000_000_000, endNs: 5_000_000_000, confidence: 1)]))
                }
                return { cancellations.increment() }
            }
        }
    })
    let result = try await service.transcribe(package: fixture.package, localeIdentifier: "en-US")
    #expect(cancellations.count == 3)
    #expect(result.words.map(\.text) == ["before", "after"])
    #expect(result.words.map(\.srcStartNs) == [2_100_000_000, 92_100_000_000])
    #expect(result.isPartial)
    let warning = try #require(result.warnings.first)
    #expect(result.warnings.count == 1 && warning.code == "no_speech_detected")
    #expect(warning.message.contains("Partial transcript"))
    #expect(warning.srcStartNs == 44_600_000_000 && warning.srcEndNs == 88_600_000_000)
    #expect(warning.segmentIndex == 0 && warning.track == .microphone)
    let saved = try Data(contentsOf: fixture.transcript)
    #expect(try JSONDecoder().decode(RecordingTranscript.self, from: saved) == result)
    let json = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    let warnings = try #require(json["warnings"] as? [[String: Any]])
    #expect(warnings[0]["src_start_ns"] as? Int64 == warning.srcStartNs)
    #expect(RecordingPackageLease.isAvailable(fixture.package))
}

@Test(arguments: [NSError(domain: "OtherDomain", code: 1110),
                  NSError(domain: "kAFAssistantErrorDomain", code: 1101)])
func unrelatedSpeechWindowErrorsRemainFatalAndPreservePreviousTranscript(error: NSError) async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    let previous = Data("previous transcript".utf8)
    try previous.write(to: fixture.transcript)
    let service = TranscriptionService(recognizeWithWarnings: { _, _ in
        let windows = try SpeechChunking.windows(frameCount: 100 * 48_000, sampleRate: 48_000)
        return try await SpeechChunking.collect(windows: windows, sampleRate: 48_000) { window in
            if window.startFrame > 0 { throw error }
            return [RecognizedSpeechWord(text: "before", startNs: 0, endNs: 1, confidence: 1)]
        }
    })
    await #expect(throws: TranscriptionError.recognitionFailed(error.localizedDescription)) {
        try await service.transcribe(package: fixture.package)
    }
    #expect(try Data(contentsOf: fixture.transcript) == previous)
    #expect(RecordingPackageLease.isAvailable(fixture.package))
}

@Test func cancellationAfterNoSpeechWindowStillAbortsWithoutPublishing() async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    let (started, signal) = AsyncStream<Void>.makeStream()
    let service = TranscriptionService(recognizeWithWarnings: { _, _ in
        let windows = try SpeechChunking.windows(frameCount: 100 * 48_000, sampleRate: 48_000)
        return try await SpeechChunking.collect(windows: windows, sampleRate: 48_000) { window in
            if window.startFrame == 0 { throw NSError(domain: "kAFAssistantErrorDomain", code: 1110) }
            signal.yield(()); signal.finish()
            try await Task.sleep(for: .seconds(60))
            return []
        }
    })
    let task = Task { try await service.transcribe(package: fixture.package) }
    for await _ in started { break }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: fixture.transcript.path))
    #expect(RecordingPackageLease.isAvailable(fixture.package))
}

@Test func allNoSpeechWindowsProduceEmptyTranscriptWithWarningsAndLegacyJSONStillDecodes() async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    let service = TranscriptionService(recognizeWithWarnings: { _, _ in
        let windows = try SpeechChunking.windows(frameCount: 100 * 48_000, sampleRate: 48_000)
        return try await SpeechChunking.collect(windows: windows, sampleRate: 48_000) { _ in
            throw NSError(domain: "kAFAssistantErrorDomain", code: 1110)
        }
    })
    let result = try await service.transcribe(package: fixture.package)
    #expect(result.words.isEmpty && result.isPartial)
    // Existing short segments clip the warning to each selected track's source end.
    #expect(result.warnings.map(\.srcStartNs) == [100_000_000, 5_200_000_000])
    #expect(result.warnings.map(\.srcEndNs) == [5_000_000_000, 8_000_000_000])
    let old = Data(#"{"schema_version":1,"engine":"apple_speech_on_device","locale":"en-US","words":[]}"#.utf8)
    let decoded = try JSONDecoder().decode(RecordingTranscript.self, from: old)
    #expect(decoded.warnings.isEmpty && !decoded.isPartial)
    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
    #expect(encoded["warnings"] == nil)
}

/// Generated speech at 2 s and 92 s; the entire 44–89 s request is silent.
/// Native no-speech is not guaranteed for every OS/model (some return []), so the
/// injected callback pass always verifies C1's exact error through real file IO.
@Suite(.serialized) struct SilentWindowSpeechMediaTests {
    private func makeSayFixture() throws -> (SpeechFixture, URL) {
        let fixture = try SpeechFixture()
        do {
            let speech = fixture.root.appendingPathComponent("say.caf")
            let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", "Samantha", "-r", "140", "-o", speech.path, "--data-format=LEF32@48000", "Hello. This is a spoken window."]
            try say.run(); say.waitUntilExit()
            guard say.terminationStatus == 0 else { throw TranscriptionError.recognitionFailed("say failed") }
            let spoken = try AVAudioFile(forReading: speech, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard spoken.length > 0, spoken.length < 40 * 48_000, spoken.processingFormat.sampleRate == 48_000 else {
                throw TranscriptionError.recognitionFailed("say produced no usable 48 kHz speech; run this test on the host")
            }
            let speechBuffer = AVAudioPCMBuffer(pcmFormat: spoken.processingFormat, frameCapacity: UInt32(spoken.length))!
            try spoken.read(into: speechBuffer)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let audio = fixture.package.appendingPathComponent("recording/seg-000/spoken-silent-spoken.caf")
            let frames = 92 * 48_000 + spoken.length + 48_000
            try autoreleasepool {
                var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
                let output = try AVAudioFile(forWriting: audio, settings: settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
                var position: Int64 = 0
                while position < frames {
                    let count = Int(min(8192, frames - position))
                    buffer.frameLength = UInt32(count)
                    buffer.floatChannelData![0].initialize(repeating: 0, count: count)
                    for voiceStart: Int64 in [2 * 48_000, 92 * 48_000] {
                        let start = max(position, voiceStart), end = min(position + Int64(count), voiceStart + spoken.length)
                        if end > start { for index in start..<end {
                            buffer.floatChannelData![0][Int(index - position)] = speechBuffer.floatChannelData![0][Int(index - voiceStart)]
                        } }
                    }
                    try output.write(from: buffer)
                    position += Int64(count)
                }
            }
            var manifest = fixture.manifest
            manifest.segments = [manifest.segments[0]]
            manifest.segments[0].files = ["mic": "seg-000/spoken-silent-spoken.caf"]
            manifest.segments[0].durationNs = 100_000_000 + Int64((Double(frames) / 48_000 * 1_000_000_000).rounded())
            try fixture.save(manifest)
            return (fixture, audio)
        } catch { fixture.cleanup(); throw error }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAPCAM_TRANSCRIPTION_MEDIA_TESTS"] == "1"))
    func saySpeechSilentWindowRetainsSpokenWindowsWithInjectedNoSpeech() async throws {
        let (fixture, _) = try makeSayFixture(); defer { fixture.cleanup() }
        let count = SpeechCancellationCount()
        let service = TranscriptionService(recognizeWithWarnings: { url, _ in
            try await AppleOnDeviceSpeech.recognizeFile(url) { buffer in
                let data = buffer.floatChannelData![0]
                let silent = (0..<Int(buffer.frameLength)).allSatisfy { data[$0] == 0 }
                return try await SpeechRecognitionJob().run { complete in
                    if silent { complete(.failure(NSError(domain: "kAFAssistantErrorDomain", code: 1110))) }
                    else { complete(.success([RecognizedSpeechWord(text: "spoken", startNs: 4_000_000_000, endNs: 5_000_000_000, confidence: 1)])) }
                    return { count.increment() }
                }
            }
        })
        let transcript = try await service.transcribe(package: fixture.package, localeIdentifier: "en-US")
        #expect(count.count == 3)
        #expect(transcript.words.map(\.text) == ["spoken", "spoken"])
        #expect(transcript.words.map(\.srcStartNs) == [4_100_000_000, 92_100_000_000])
        #expect(transcript.warnings.count == 1 && transcript.isPartial)
        #expect(transcript.warnings[0].srcStartNs == 44_600_000_000)
        #expect(transcript.warnings[0].srcEndNs == 88_600_000_000)
        #expect(try JSONDecoder().decode(RecordingTranscript.self, from: Data(contentsOf: fixture.transcript)) == transcript)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAPCAM_TRANSCRIPTION_MEDIA_TESTS"] == "1"))
    func actualOnDeviceSaySpeechAcrossSilentWindow() async throws {
        let (fixture, _) = try makeSayFixture(); defer { fixture.cleanup() }
        let transcript = try await TranscriptionService().transcribe(package: fixture.package, localeIdentifier: "en-US")
        let before = transcript.words.filter { $0.srcStartNs < 44_600_000_000 }.map(\.text).joined(separator: " ").lowercased()
        let after = transcript.words.filter { $0.srcStartNs >= 88_600_000_000 }.map(\.text).joined(separator: " ").lowercased()
        #expect(before.contains("hello") && before.contains("spoken"))
        #expect(after.contains("hello") && after.contains("spoken"))
        #expect(!transcript.words.contains { (44_600_000_000..<88_600_000_000).contains($0.srcStartNs) })
        #expect(transcript.warnings.allSatisfy { $0.code == "no_speech_detected" })
        print("SILENT_WINDOW_NATIVE words=\(transcript.words.count) warnings=\(transcript.warnings.count)")
        // An explicit no-speech error must be surfaced; successful [] needs no warning.
        if !transcript.warnings.isEmpty { #expect(transcript.isPartial) }
    }
}


@Test(arguments: [[], ["Yapcam", "Clara Weiß", "forty two"]])
func transcriptionForwardsKeytermsToEverySegment(keyterms: [String]) async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    let service = TranscriptionService(recognizeRequest: { url, locale, forwarded in
        #expect(locale == "de-DE")
        #expect(forwarded == keyterms)
        #expect(["seg-000", "seg-001"].contains(url.deletingLastPathComponent().lastPathComponent))
        return RecognizedSpeech(words: [RecognizedSpeechWord(text: "Clara", startNs: 0, endNs: 100_000_000, confidence: 1)])
    })
    let result: RecordingTranscript
    if keyterms.isEmpty { result = try await service.transcribe(package: fixture.package, localeIdentifier: "de-DE") }
    else { result = try await service.transcribe(package: fixture.package, localeIdentifier: "de-DE", keyterms: keyterms) }
    #expect(result.words.count == 2 && Set(result.words.map(\.segmentIndex)) == [0, 1])
    let json = try String(contentsOf: fixture.transcript, encoding: .utf8)
    #expect(!json.contains("keyterms") && !json.contains("forty two"))
}

@Test(arguments: [TranscriptionError.unsupportedLocale("zz-ZZ"), .onDeviceModelNotInstalled("de-DE")])
func typedSpeechAdmissionFailuresPreservePublishedTranscript(error: TranscriptionError) async throws {
    let fixture = try SpeechFixture(); defer { fixture.cleanup() }
    let previous = Data("previous transcript".utf8)
    try previous.write(to: fixture.transcript)
    let service = TranscriptionService(recognizeRequest: { _, _, _ in
        if case .unsupportedLocale(let locale) = error {
            _ = try OnDeviceSpeechPolicy.locale(locale, supported: [])
        }
        if case .onDeviceModelNotInstalled(let locale) = error {
            return try await SpeechChunking.collect(windows: SpeechChunking.windows(frameCount: 48_000, sampleRate: 48_000), sampleRate: 48_000) { _ in
                throw OnDeviceSpeechPolicy.recognitionError(NSError(domain: "kLSRErrorDomain", code: 102), locale: locale)
            }
        }
        throw error
    })
    await #expect(throws: error) { try await service.transcribe(package: fixture.package, keyterms: ["Yapcam"]) }
    #expect(try Data(contentsOf: fixture.transcript) == previous)
    #expect(!FileManager.default.fileExists(atPath: fixture.package.appendingPathComponent("recording/.capture.lock").path))
}
