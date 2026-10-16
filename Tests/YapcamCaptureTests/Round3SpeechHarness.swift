// Standalone integration runner, deliberately absent from the normal test target.
// Compile with Tools/run_speech.zsh, which links the real capture/core/render/editor
// modules. Generated audio and reports stay outside the repository.
#if ROUND3_SPEECH_HARNESS
@preconcurrency import AVFoundation
import Foundation
import Speech
@testable import YapcamCapture
import YapcamCore
import YapcamRender
import YapcamEditor

private enum HarnessError: LocalizedError {
    case assertion(String)
    var errorDescription: String? { switch self { case .assertion(let message): message } }
}
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw HarnessError.assertion(message) }
}
private func write(_ value: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
}

@main struct Round3SpeechHarness {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard (2...3).contains(args.count), args.count == 2 || args[2] == "--request-speech" else {
            throw HarnessError.assertion("Expected external fixture directory, --probe or --contract; optional --request-speech")
        }
        if args.contains("--request-speech") {
            // Explicit host-only opt-in; ordinary tests never trigger a permission dialog.
            _ = try await TranscriptionService.requestAuthorization()
        }
        let supported = SFSpeechRecognizer.supportedLocales()
        var probe: [String: Any] = ["permission": String(describing: TranscriptionService.authorizationState),
                                    "on_device_only": true, "build": "debug", "mode": "file processing; no mic or app launch"]
        for identifier in ["de-DE", "en-US", "zz-ZZ"] {
            let start = ContinuousClock.now
            do {
                try OnDeviceSpeechPolicy.authorize(TranscriptionService.authorizationState)
                let locale = try OnDeviceSpeechPolicy.locale(identifier, supported: supported)
                guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw TranscriptionError.onDeviceUnavailable(identifier) }
                let request = try OnDeviceSpeechPolicy.request(locale: identifier,
                    supportsOnDevice: recognizer.supportsOnDeviceRecognition, available: recognizer.isAvailable)
                probe[identifier] = ["requiresOnDeviceRecognition": request.requiresOnDeviceRecognition,
                                     "available": recognizer.isAvailable, "supportsOnDevice": recognizer.supportsOnDeviceRecognition]
            } catch { probe[identifier] = ["error": error.localizedDescription] }
            probe[identifier + "_elapsed"] = String(describing: start.duration(to: .now))
        }
        if args[1] == "--contract" {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-capture-round3-contract-\(UUID())")
            defer {
                print("Removing capture contract fixture: \(temp.lastPathComponent)")
                try? FileManager.default.removeItem(at: temp)
            }
            let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/Fixtures/synthetic/basic.yapcam")
            try FileManager.default.copyItem(at: fixture, to: temp)
            let times: [(String, Int64, Int64)] = [("Hello", 400_000_000, 800_000_000), ("um", 1_100_000_000, 1_300_000_000),
                ("Clara", 1_600_000_000, 1_900_000_000), ("äh", 3_000_000_000, 3_200_000_000), ("again", 4_200_000_000, 4_700_000_000)]
            let transcript: [String: Any] = ["schema_version": 1, "locale": "de-DE", "words": times.map {
                ["text": $0.0, "src_start_ns": $0.1, "src_end_ns": $0.2] as [String: Any]
            }]
            let result = try editing(package: temp, transcript: JSONSerialization.data(withJSONObject: transcript))
            print("DETERMINISTIC_EDIT_CONTRACT", result)
            return
        }
        if args[1] == "--probe" {
            print(String(decoding: try JSONSerialization.data(withJSONObject: probe, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self))
            return
        }
        let root = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL
        try require(!root.path.hasPrefix(FileManager.default.currentDirectoryPath + "/"), "Fixtures must be outside the repository")
        try write(probe, to: root.appendingPathComponent("speech-probe.json"))
        for identifier in ["de-DE", "en-US"] {
            let directory = root.appendingPathComponent(identifier, isDirectory: true)
            let truth = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("ground-truth.json"))) as! [String: Any]
            let duration = (truth["duration_ns"] as! NSNumber).int64Value
            var outcomes: [String: Any] = [:]
            for variant in ["clean", "noisy"] {
                let package = directory.appendingPathComponent("\(variant).yapcam", isDirectory: true)
                let recording = package.appendingPathComponent("recording", isDirectory: true)
                let segment = recording.appendingPathComponent("seg-000", isDirectory: true)
                // Refuse existing results. A second run must use a fresh fixture root.
                try require(!FileManager.default.fileExists(atPath: package.path), "Existing package: \(package.lastPathComponent)")
                try FileManager.default.createDirectory(at: segment, withIntermediateDirectories: true)
                try FileManager.default.linkItem(at: directory.appendingPathComponent("\(variant).wav"), to: segment.appendingPathComponent("mic.wav"))
                try FileManager.default.linkItem(at: directory.appendingPathComponent("screen.mov"), to: segment.appendingPathComponent("screen.mov"))
                try Data().write(to: segment.appendingPathComponent("events.jsonl"))
                try write([String: String](), to: segment.appendingPathComponent("cursors.json"))
                let manifest = SessionManifest(status: "complete", source: SourceMetadata(kind: "display", displayID: 0,
                    displayName: "Generated speech test", contentRectPoints: [0, 0, 64, 64], scale: 1),
                    tracks: TrackMetadata(screen: ScreenMetadata(pixelSize: [64, 64], maxFPS: 30, codec: "h264"),
                        mic: AudioMetadata(sampleRate: 48_000, channels: 1)),
                    segments: [SegmentMetadata(index: 0, dir: "seg-000", srcStartNs: 0, durationNs: duration, hostStartNs: 0,
                        files: ["screen": "seg-000/screen.mov", "mic": "seg-000/mic.wav", "events": "seg-000/events.jsonl", "cursors": "seg-000/cursors.json"],
                        trackStartNs: ["screen": 0, "mic": 0])])
                try PackageIO.write(manifest, to: recording.appendingPathComponent("session.json"))
                let started = ContinuousClock.now
                do {
                    let transcript = try await TranscriptionService().transcribe(package: package, localeIdentifier: identifier, track: .microphone)
                    let bytes = try JSONEncoder().encode(transcript)
                    try bytes.write(to: directory.appendingPathComponent("\(variant)-transcript.json"))
                    var result: [String: Any] = ["word_count": transcript.words.count, "warnings": transcript.warnings.count,
                                               "elapsed": String(describing: started.duration(to: .now))]
                    do { result["editing"] = try editing(package: package, transcript: bytes) }
                    catch { result["editing_error"] = error.localizedDescription }
                    outcomes[variant] = result
                } catch {
                    outcomes[variant] = ["error": error.localizedDescription, "elapsed": String(describing: started.duration(to: .now)),
                                         "editing": "not run: no recognized transcript"]
                }
            }
            do {
                let report = try await SpeechEnhancer.processFile(directory.appendingPathComponent("noisy.wav"), to: directory.appendingPathComponent("dsp.caf"))
                outcomes["dsp"] = ["frames": report.frames, "target_lufs_reached": report.reachedTarget,
                                   "reported_output_lufs": report.outputLUFS as Any? ?? NSNull(),
                                   "reported_peak_dbfs": report.samplePeakDBFS as Any? ?? NSNull()]
            } catch { outcomes["dsp"] = ["error": error.localizedDescription] }
            do {
                let report = try await VoiceIsolationService().processFile(directory.appendingPathComponent("noisy.wav"), to: directory.appendingPathComponent("isolated.caf"))
                outcomes["isolation"] = ["frames": report.frames, "latency_frames": report.compensatedLatencyFrames]
            } catch { outcomes["isolation"] = ["error": error.localizedDescription] }
            do {
                let silences = try await AudioAnalysis.silence(in: directory.appendingPathComponent("clean.wav"), thresholdDB: -45, minimumNs: 250_000_000)
                outcomes["silence_detection"] = silences.map { ["start_ns": $0.startNs, "end_ns": $0.endNs] }
            } catch { outcomes["silence_detection"] = ["error": error.localizedDescription] }
            try write(outcomes, to: directory.appendingPathComponent("outcomes.json"))
        }
    }

    static func verifyCuts(_ project: Project, duration: Int64, cuts: [TimeSpan]) throws {
        var source: Int64 = 0, timeline: Int64 = 0
        for cut in EditorSpans.merged(cuts) + [TimeSpan(startNs: duration, endNs: duration)] {
            if cut.startNs > source {
                let length = cut.startNs-source
                for offset in Set([Int64(0), length/2, length-1]) {
                    try require(try project.frame(atNs: timeline+offset).screen.src_ns == source+offset,
                                "Retained source range mismatch after transcript edit")
                }
                timeline += length
            }
            source = cut.endNs
        }
        try require(project.durationNs == timeline, "Complement duration mismatch")
    }

    @MainActor static func editing(package: URL, transcript: Data) throws -> [String: Any] {
        let project = try Project.create(package: package)
        try project.importTranscript(transcript)
        let model = EditorModel(project: CoreEditingProject(project: project), player: FakePlayer())
        defer { model.close() }
        let initial = project.durationNs
        guard let word = model.transcriptWords.first(where: { $0.span.startNs > 300_000_000 && $0.span.endNs < initial-300_000_000 }) else {
            throw HarnessError.assertion("No interior word available for a cut")
        }
        let fillers = model.fillerWordCount
        let pauses = model.pauseCuts()
        model.deleteWords(ids: [word.id])
        try require(model.lastError == nil, model.lastError ?? "")
        try require(project.durationNs == initial-word.span.durationNs, "Word cut duration mismatch")
        try verifyCuts(project, duration: initial, cuts: [word.span])
        model.undo()
        let expectedFiller = EditorSpans.merged(model.transcriptWords.filter { model.isFiller($0) }.map(\.span))
        model.removeFillerWords()
        try require(project.durationNs == initial-expectedFiller.reduce(0) { $0+$1.durationNs }, "Filler cut mismatch")
        try verifyCuts(project, duration: initial, cuts: expectedFiller)
        if !expectedFiller.isEmpty { model.undo() }
        model.tightenPauses()
        try require(project.durationNs == initial-pauses.reduce(0) { $0+$1.durationNs }, "Pause cut mismatch")
        try verifyCuts(project, duration: initial, cuts: pauses)
        return ["word_cut": "pass", "filler_count": fillers, "pause_count": pauses.count,
                "filler_cut": "pass", "pause_cut": "pass", "user_interaction": false]
    }
}

// Oracle for expected union duration only; actual cuts go through EditorModel + Rust.
private enum EditorSpans {
    static func merged(_ spans: [TimeSpan]) -> [TimeSpan] {
        var result: [TimeSpan] = []
        for span in spans.sorted(by: { $0.startNs < $1.startNs }) {
            if let last = result.last, span.startNs <= last.endNs {
                result[result.count-1] = TimeSpan(startNs: last.startNs, endNs: max(last.endNs, span.endNs))
            } else { result.append(span) }
        }
        return result
    }
}
#endif
