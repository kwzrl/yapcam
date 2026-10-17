@preconcurrency import AVFoundation
import Testing
import Foundation
import YapcamCore
@testable import YapcamUI

@Suite struct AgentVisionTests {
    @Test func validatesImageBudgetsTypesAndTimelineBounds() throws {
        let duration: Int64 = 10_000_000_000
        let request = try AgentVisionRequest(name: "capture", arguments: ["times": [0, 3, 6, 10]], durationNs: duration)
        #expect(request.times == [0, 3_000_000_000, 6_000_000_000, duration - 1])
        let strip = try AgentVisionRequest(name: "filmstrip", arguments: ["count": 4, "from_s": 1, "to_s": 7], durationNs: duration)
        #expect(strip.times == [1_000_000_000, 3_000_000_000, 5_000_000_000, 7_000_000_000])
        for args: [String: Any] in [["times": []], ["times": [true]], ["times": [-1]], ["times": [11]], ["times": [Double.nan]],
                                   ["times": [0], "separate": 1], ["times": [0], "per_sheet": 1.5],
                                   ["times": [0, 1, 2, 3, 4], "separate": true], ["times": [0], "typo": 1]] {
            #expect(throws: (any Error).self) { try AgentVisionRequest(name: "capture", arguments: args, durationNs: duration) }
        }
        #expect(throws: (any Error).self) { try AgentVisionRequest(name: "filmstrip", arguments: ["count": 13], durationNs: duration) }
        #expect(throws: (any Error).self) { try AgentVisionRequest(name: "waveform", arguments: ["from_s": 5, "to_s": 2], durationNs: duration) }
        #expect(throws: (any Error).self) { try AgentVisionRequest(name: "capture", arguments: ["times": [0]], durationNs: 0) }
    }
    @Test func clipsMergesAndComplementsAnalysisWithoutCallingUnknownTimeSpeech() {
        let ranges = [SilenceRange(startNs: 20, endNs: 40), SilenceRange(startNs: 0, endNs: 25), SilenceRange(startNs: 60, endNs: 120)]
        #expect(AgentVisionRanges.merge(ranges, within: 10..<100) == [SilenceRange(startNs: 10, endNs: 40), SilenceRange(startNs: 60, endNs: 100)])
        #expect(AgentVisionRanges.complement(ranges, within: 10..<100) == [SilenceRange(startNs: 40, endNs: 60)])
        #expect(AgentVisionRanges.complement([], within: 10..<100) == [SilenceRange(startNs: 10, endNs: 100)])
    }
    @MainActor @Test func waveformUsesExistingAnalysisAndDoesNotChangeHistory() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-vision-waveform-\(UUID()).yapcam")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: root)
        let project = try Project.create(package: root)
        try project.apply(.deleteRange(startNs: 0, endNs: 500_000_000))
        let before = try project.toJSON(), revision = project.revision
        let result = try await AgentVision.handle(name: "waveform", arguments: ["from_s": 0.25, "to_s": 3.5], project: project)
        let value = try #require(result["structuredContent"] as? [String: Any])
        #expect(value["analysis"] as? String == "audio_energy")
        #expect(value["track"] as? String == "system_audio")
        #expect(value["from_s"] as? Double == 0.25)
        #expect(value["to_s"] as? Double == 3.5)
        for key in ["silence_ranges", "speech_ranges", "coverage_ranges", "unknown_ranges"] {
            let ranges = try #require(value[key] as? [[String: Double]])
            for range in ranges {
                #expect(try #require(range["start_s"]) >= 0.25)
                #expect(try #require(range["end_s"]) <= 3.5)
                #expect(try #require(range["end_s"]) > #require(range["start_s"]))
            }
        }
        #expect(try project.toJSON() == before)
        #expect(project.revision == revision)
    }

    @MainActor @Test func waveformDoesNotInventSpeechAfterAnEarlyAudioEnd() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-vision-audio-tail-\(UUID()).yapcam")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: root)
        let wav = root.appendingPathComponent("recording/seg-000/short.wav")
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let file = try AVAudioFile(forWriting: wav, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            try #require(buffer.floatChannelData)[0].initialize(repeating: 0, count: 48_000)
            try file.write(from: buffer)
        }
        let manifestURL = root.appendingPathComponent("recording/session.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var segments = try #require(manifest["segments"] as? [[String: Any]])
        for i in segments.indices {
            var files = try #require(segments[i]["files"] as? [String: String])
            files["system_audio"] = i == 0 ? "seg-000/short.wav" : nil
            segments[i]["files"] = files
        }
        manifest["segments"] = segments
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let project = try Project.create(package: root)
        let result = try await AgentVision.handle(name: "waveform", arguments: [:], project: project)
        let value = try #require(result["structuredContent"] as? [String: Any])
        #expect(value["speech_ranges"] as? [[String: Double]] == [])
        #expect(value["silence_ranges"] as? [[String: Double]] == [["start_s": 0, "end_s": 1]])
        #expect(value["coverage_ranges"] as? [[String: Double]] == [["start_s": 0, "end_s": 1]])
        #expect(value["unknown_ranges"] as? [[String: Double]] == [["start_s": 1, "end_s": 5]])
    }

}
