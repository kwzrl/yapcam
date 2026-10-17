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
        #expect(request.perSheet == 6)
        #expect(request.crop.rawValue == "content")
        let defaults = try AgentVisionRequest(name: "filmstrip", arguments: [:], durationNs: duration)
        #expect(defaults.times.count == 6)
        #expect(defaults.perSheet == 6)
        #expect(defaults.crop.rawValue == "frame")
        let twoSheets = try AgentVisionRequest(name: "filmstrip", arguments: ["count": 12, "crop": "content"], durationNs: duration)
        #expect(twoSheets.times.count / twoSheets.perSheet == 2)
        #expect(twoSheets.crop.rawValue == "content")
        let strip = try AgentVisionRequest(name: "filmstrip", arguments: ["count": 4, "from_s": 1, "to_s": 7], durationNs: duration)
        #expect(strip.times == [1_000_000_000, 3_000_000_000, 5_000_000_000, 7_000_000_000])
        for args: [String: Any] in [["times": []], ["times": [true]], ["times": [-1]], ["times": [11]], ["times": [Double.nan]],
                                   ["times": [0], "separate": 1], ["times": [0], "per_sheet": 1.5],
                                   ["times": [0, 1, 2, 3, 4], "separate": true], ["times": [0], "typo": 1],
                                   ["times": [0], "crop": "screen"], ["times": [0], "crop": true],
                                   ["times": Array(repeating: 0, count: 25)]] {
            #expect(throws: (any Error).self) { try AgentVisionRequest(name: "capture", arguments: args, durationNs: duration) }
        }
        #expect(throws: (any Error).self) { try AgentVisionRequest(name: "filmstrip", arguments: ["count": 13], durationNs: duration) }
        #expect(throws: (any Error).self) { try AgentVisionRequest(name: "waveform", arguments: ["from_s": 5, "to_s": 2], durationNs: duration) }
        #expect(throws: (any Error).self) { try AgentVisionRequest(name: "capture", arguments: ["times": [0]], durationNs: 0) }
    }
    @Test func viewChangeContractRejectsInvalidIndicesAndThresholds() throws {
        let defaults = try AgentVisionRequest(name: "view_changes", arguments: [:], durationNs: 10)
        #expect(defaults.clickIndices == nil)
        #expect(defaults.threshold == 0.005)
        let chosen = try AgentVisionRequest(name: "view_changes", arguments: ["click_indices": [0, 2], "threshold": 0.1], durationNs: 10)
        #expect(chosen.clickIndices == [0, 2])
        #expect(chosen.threshold == 0.1)
        for args: [String: Any] in [["threshold": 0], ["threshold": true], ["threshold": 1.1], ["threshold": Double.nan],
                                   ["click_indices": [-1]], ["click_indices": [0.5]], ["click_indices": [true]],
                                   ["click_indices": [Double(Int.max)]], ["click_indices": Array(repeating: 0, count: 101)],
                                   ["click_indices": "all"], ["times": [0]]] {
            #expect(throws: (any Error).self) { try AgentVisionRequest(name: "view_changes", arguments: args, durationNs: 10) }
        }
        let tools = AgentVision.tools
        #expect(Set(tools.compactMap { $0["name"] as? String }) == Set(AgentVision.names))
        for tool in tools { #expect((tool["annotations"] as? [String: Bool])?["readOnlyHint"] == true) }
    }

    @MainActor @Test func viewChangesReadFrozenTimelineWithoutMutatingHistory() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-vision-diff-\(UUID()).yapcam")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: root)
        let project = try Project.create(package: root)
        try project.apply(.deleteRange(startNs: 0, endNs: 500_000_000))
        let before = try project.toJSON(), revision = project.revision
        let result = try await AgentVision.handle(name: "view_changes", arguments: ["click_indices": [0]], project: project)
        let value = try #require(result["structuredContent"] as? [String: Any])
        let rows = try #require(value["clicks"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows.first?["click_index"] as? Int == 0)
        #expect(rows.first?["view_change_s"] != nil)
        #expect(try project.toJSON() == before)
        #expect(project.revision == revision)
        await #expect(throws: (any Error).self) {
            _ = try await AgentVision.handle(name: "view_changes", arguments: ["click_indices": [999]], project: project)
        }
    }
    @Test func pixelHintSelectionValidatesAndMatchesCoreNearestClickRule() throws {
        let times: [Int64] = [1_000_000_000, 2_000_000_000, 3_000_000_000]
        #expect(try AgentPixelSelection(name: "moments", arguments: [:]).indices(in: times) == [0, 1, 2])
        #expect(try AgentPixelSelection(name: "zoom_on_click", arguments: ["click_index": 1]).indices(in: times) == [1])
        #expect(try AgentPixelSelection(name: "zoom_on_click", arguments: ["at_s": 2.24]).indices(in: times) == [1])
        #expect(throws: (any Error).self) { try AgentPixelSelection(name: "zoom_on_click", arguments: ["at_s": 2.26]).indices(in: times) }
        #expect(throws: (any Error).self) { try AgentPixelSelection(name: "zoom_on_click", arguments: ["click_index": 3]).indices(in: times) }
        for args: [String: Any] in [[:], ["click_index": true], ["click_index": -1], ["click_index": 1.5],
                                    ["click_index": 0, "at_s": 1], ["at_s": Double.infinity], ["at_s": 1e30]] {
            #expect(throws: (any Error).self) { try AgentPixelSelection(name: "zoom_on_click", arguments: args) }
        }
        #expect(AgentVision.hintKeys(name: "moments", catalog: []) == [])
        let catalog: [[String: Any]] = [["name": "moments", "inputSchema": ["properties": ["static_cuts_s": [:], "other": [:]]]]]
        #expect(AgentVision.hintKeys(name: "moments", catalog: catalog) == ["static_cuts_s"])
    }

    @MainActor @Test func pixelHintsAreLazyCachedPerDocumentRevisionAndReadOnly() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-pixel-hints-\(UUID()).yapcam")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: root)
        let project = try Project.create(package: root)
        let before = try project.toJSON(), revision = project.revision
        let first = try await AgentVision.pixelHints(name: "zoom_on_click", arguments: ["click_index": 0], project: project)
        #expect(first["analyzed_click_count"] as? Int == 1)
        #expect(first["cache_hit"] as? Bool == false)
        let warm = try await AgentVision.pixelHints(name: "zoom_on_click", arguments: ["click_index": 0], project: project)
        #expect(warm["cache_hit"] as? Bool == true)
        #expect(warm["analyzed_click_count"] as? Int == 0)
        #expect(try project.toJSON() == before)
        #expect(project.revision == revision)
        let all = try await AgentVision.pixelHints(name: "moments", arguments: [:], project: project)
        #expect(all["visual_view_changes_s"] is [Double])
        #expect(all["static_cuts_s"] is [Double])
        let allWarm = try await AgentVision.pixelHints(name: "moments", arguments: [:], project: project)
        #expect(allWarm["cache_hit"] as? Bool == true)
        let explicit = try await AgentVision.enrich(name: "moments", arguments: ["static_cuts_s": "invalid"], project: project)
        #expect(explicit["static_cuts_s"] as? String == "invalid") // core must reject, never silently replace
        try project.apply(.deleteRange(startNs: 0, endNs: 100_000_000))
        let edited = try await AgentVision.pixelHints(name: "moments", arguments: [:], project: project)
        #expect(edited["cache_hit"] as? Bool == false)
        let reopened = try Project.open(package: root)
        let separate = try await AgentVision.pixelHints(name: "moments", arguments: [:], project: reopened)
        #expect(separate["cache_hit"] as? Bool == false)
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
