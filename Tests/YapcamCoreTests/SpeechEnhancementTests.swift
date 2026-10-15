import Foundation
@preconcurrency import AVFoundation
import Testing
import YapcamCore

private actor SpeechProcessorCalls {
    var count = 0
    func record() { count += 1 }
}
private func withSpeechFixture<T>(_ body: (URL, Project) async throws -> T) async throws -> T {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let package = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-core-speech-\(UUID().uuidString).yapcam")
    defer { try? FileManager.default.removeItem(at: package) }
    try FileManager.default.copyItem(at: root.appendingPathComponent("Fixtures/synthetic/basic.yapcam"), to: package)
    let url = package.appendingPathComponent("recording/seg-000/mic.wav")
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for n in 0..<4_800 { buffer.floatChannelData![0][n] = Float(sin(Double(n) * 2 * .pi * 440 / 48_000) * 0.2) }
        try file.write(from: buffer)
    }
    let sessionURL = package.appendingPathComponent("recording/session.json")
    var session = try JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL)) as! [String: Any]
    var tracks = session["tracks"] as! [String: Any]
    tracks["mic"] = ["sample_rate": 48_000, "channels": 1, "device_name": "Procedural"]
    session["tracks"] = tracks
    var segments = session["segments"] as! [[String: Any]]
    var files = segments[0]["files"] as! [String: Any]
    files["mic"] = "seg-000/mic.wav"; segments[0]["files"] = files
    var starts = segments[0]["track_start_ns"] as? [String: Any] ?? [:]
    starts["mic"] = 50_000_000; segments[0]["track_start_ns"] = starts
    session["segments"] = segments
    try JSONSerialization.data(withJSONObject: session).write(to: sessionURL)
    return try await body(package, Project.create(package: package))
}

@Test func speechEnhancementPlanPersistsAndProcessesUniqueMicWithoutChangingClocks() async throws {
    try await withSpeechFixture { package, p in
        let calls = SpeechProcessorCalls()
        #expect(try !p.speechEnhancementPlan().enabled)
        let disabled = try await p.prepareSpeechEnhancement { _, _, _ in await calls.record() }
        #expect(disabled.isEmpty)
        #expect(await calls.count == 0)
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("cache").path))
        try p.apply(.batch([
            .set(path: "audio.speech_enhancement", value: .bool(true)),
            .set(path: "audio.speech_enhancement_settings.high_pass_hz", value: .number(100)),
            .set(path: "audio.speech_enhancement_settings.normalize_loudness", value: .bool(false))
        ]))
        let plan = try p.speechEnhancementPlan()
        #expect(plan.media.count == 1 && plan.settings.highPassHz == 100)
        let path = plan.media[0].path
        let source = package.appendingPathComponent(path)
        let original = try Data(contentsOf: source)
        let before = try p.toJSON()
        let frame = try p.frame(atNs: 100_000_000)
        let results = try await p.prepareSpeechEnhancement { input, output, settings in
            await calls.record()
            #expect(settings.highPassHz == 100 && !settings.normalizeLoudness)
            for _ in 0..<100 { #expect(try p.frame(atNs: 100_000_000).screen.src_ns == frame.screen.src_ns) }
            // Injected identity PCM processor tests preparation/validation only.
            // Render owns the actual high-pass/expansion/compression DSP tests.
            try FileManager.default.copyItem(at: input, to: output)
        }
        #expect(await calls.count == 1)
        #expect(results.count == 1 && results[0].originalPath == path)
        #expect(results[0].durationNs == 100_000_000 && results[0].sampleRate == 48_000)
        #expect(try Data(contentsOf: results[0].processedURL) == original)
        #expect(try Data(contentsOf: source) == original)
        #expect(try p.toJSON() == before)
        #expect(results[0].processedURL.path.contains("cache/speech/"))
        let snap = try p.snapshot()
        try p.apply(.set(path: "audio.speech_enhancement", value: .bool(false)))
        #expect(try snap.speechEnhancementPlan().enabled && !p.speechEnhancementPlan().enabled)
        try p.undo()
        try p.save()
        #expect(try Project.open(package: package).speechEnhancementPlan() == plan)
        #expect(throws: CoreError.self) { try p.apply(.set(path: "audio.speech_enhancement_settings.compressor_ratio", value: .number(0))) }
        try p.apply(.deleteRange(startNs: 0, endNs: 3_000_000_000))
        #expect(try p.speechEnhancementPlan().media.isEmpty)
        #expect(try await p.prepareSpeechEnhancement { _, _, _ in await calls.record() }.isEmpty)
        #expect(await calls.count == 1)
    }
}

@Test func enhancedMicrophoneSelectionPersistsWithoutChangingEditedAudioClocks() async throws {
    try await withSpeechFixture { package, p in
        let path = "recording/seg-000/mic.wav"
        let identity = try p.microphoneIdentity(path: path)
        let source = package.appendingPathComponent(path)
        let bytes = try Data(contentsOf: source)
        let manifest = try Data(contentsOf: package.appendingPathComponent("recording/session.json"))
        try p.apply(.split(atNs: 90_000_000))
        let first = try p.query("{\"q\":\"clips\"}", as: [ClipInfo].self)[0]
        try p.apply(.setSpeed(clipID: first.id, speed: 1.4))
        try p.apply(.setClipSettings(clipID: first.id, patch: ["mic_gain":.number(0.5)]))
        let query = "{\"q\":\"audio_ranges\"}"
        let before = try p.query(query, as: [[String:JSONValue]].self)
        let snapshot = try p.snapshot()
        let undoSteps = try p.historyState().undoSteps
        // Identity PCM tests the selection contract, not native isolation quality.
        try await p.importEnhancedMicrophone(source, forOriginal: identity)
        let selected = try #require(p.microphoneMedia().first)
        #expect(selected.enhanced && !selected.stale && selected.original == identity)
        #expect(selected.path.hasPrefix("assets/mic-") && selected.mediaIndex != selected.originalMediaIndex)
        #expect(try p.historyState().undoSteps == undoSteps + 1)
        var expected = before
        for i in expected.indices where expected[i]["track"] == .string("mic") { expected[i]["path"] = .string(selected.path) }
        #expect(try p.query(query, as: [[String:JSONValue]].self) == expected)
        #expect(try snapshot.query(query, as: [[String:JSONValue]].self) == before)
        #expect(try !snapshot.microphoneMedia()[0].enhanced)
        #expect(try p.speechEnhancementPlan().media[0].path == selected.path)
        let local = [SilenceRange(startNs: 0, endNs: 50_000_000)]
        #expect(try p.mapAudioRanges(local, track: "mic", mediaPath: selected.path) == p.mapAudioRanges(local, track: "mic", mediaPath: path))
        try p.undo(); #expect(try p.query(query, as: [[String:JSONValue]].self) == before)
        try p.redo(); #expect(try p.query(query, as: [[String:JSONValue]].self) == expected)
        try p.save()
        #expect(try Project.open(package: package).microphoneMedia() == [selected])
        try p.useOriginalMicrophone(path: path)
        #expect(try !p.microphoneMedia()[0].enhanced)
        #expect(try p.query(query, as: [[String:JSONValue]].self) == before)
        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent(selected.path).path))
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: package.appendingPathComponent("recording/session.json")) == manifest)
    }
}

@Test func enhancedMicrophoneImportRejectsInvalidStaleAndClosedResultsWithoutLeakingAssets() async throws {
    try await withSpeechFixture { package, p in
        let path = "recording/seg-000/mic.wav"
        let source = package.appendingPathComponent(path)
        let identity = try p.microphoneIdentity(path: path)
        let before = try p.toJSON()
        let assets = package.appendingPathComponent("assets")
        func assetNames() throws -> [String] {
            FileManager.default.fileExists(atPath: assets.path) ? try FileManager.default.contentsOfDirectory(atPath: assets.path) : []
        }
        let initialAssets = try assetNames()
        let bad = package.appendingPathComponent("wrong-duration.caf")
        defer { try? FileManager.default.removeItem(at: bad) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        do {
            let output = try AVAudioFile(forWriting: bad, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48)!
            buffer.frameLength = 48
            buffer.floatChannelData![0].initialize(repeating: 0, count: 48)
            try output.write(from: buffer)
        }
        do {
            try await p.importEnhancedMicrophone(bad, forOriginal: identity)
            Issue.record("Wrong-duration derivative was selected")
        } catch {}
        #expect(try p.toJSON() == before)
        #expect(try assetNames() == initialAssets)
        var stale = identity; stale.size += 1
        do {
            try await p.importEnhancedMicrophone(source, forOriginal: stale)
            Issue.record("Stale processing identity was accepted")
        } catch {}
        #expect(try p.toJSON() == before)
        #expect(try assetNames() == initialAssets)
        p.close()
        do {
            try await p.importEnhancedMicrophone(source, forOriginal: identity)
            Issue.record("Closed project accepted a derivative")
        } catch {}
        #expect(try p.toJSON() == before)
        #expect(try assetNames() == initialAssets)
    }
}

@Test func failedAndCancelledSpeechRunsCleanCacheAndPreserveOriginals() async throws {
    try await withSpeechFixture { package, p in
        try p.apply(.set(path: "audio.speech_enhancement", value: .bool(true)))
        let path = try p.speechEnhancementPlan().media[0].path
        let source = package.appendingPathComponent(path)
        let original = try Data(contentsOf: source)
        enum Injected: Error { case failure }
        do {
            _ = try await p.prepareSpeechEnhancement { input, output, _ in
                try FileManager.default.copyItem(at: input, to: output)
                throw Injected.failure
            }
            Issue.record("Speech processor error was hidden")
        } catch Injected.failure {}
        let cache = package.appendingPathComponent("cache/speech")
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        do {
            _ = try await p.prepareSpeechEnhancement { _, output, _ in
                try Data("invalid PCM".utf8).write(to: output)
                throw CancellationError()
            }
            Issue.record("Speech cancellation was hidden")
        } catch is CancellationError {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        #expect(try Data(contentsOf: source) == original)
        #expect(try p.speechEnhancementPlan().enabled)
    }
}

@Test func speechPreparationRejectsChangedMediaAndWrongDuration() async throws {
    try await withSpeechFixture { package, p in
        try p.apply(.set(path: "audio.speech_enhancement", value: .bool(true)))
        let path = try p.speechEnhancementPlan().media[0].path
        let source = package.appendingPathComponent(path)
        let calls = SpeechProcessorCalls()
        do {
            _ = try await p.prepareSpeechEnhancement { _, output, _ in
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
                let file = try AVAudioFile(forWriting: output, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
                buffer.frameLength = 100; buffer.floatChannelData![0].initialize(repeating: 0, count: 100)
                try file.write(from: buffer)
            }
            Issue.record("Wrong speech duration accepted")
        } catch CoreError.status(let code, _) { #expect(code == 1) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("cache/speech").path).isEmpty)
        var data = try Data(contentsOf: source); data[data.count - 1] ^= 1; try data.write(to: source)
        do {
            _ = try await p.prepareSpeechEnhancement { _, _, _ in await calls.record() }
            Issue.record("Changed source accepted")
        } catch CoreError.missingMedia(let paths) { #expect(paths == [path]) }
        #expect(await calls.count == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("cache/speech").path).isEmpty)
    }
}
