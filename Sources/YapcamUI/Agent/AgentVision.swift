@preconcurrency import AVFoundation
import CoreFoundation
import Foundation
import YapcamCore
import YapcamRender

/// UI glue only. A frozen edit crosses to a serial worker; no decode, Metal work,
/// sheet drawing, audio analysis, PNG encoding or file IO runs on the main actor.
enum AgentVision {
    static let names = ["capture", "grab", "filmstrip", "waveform", "view_changes"]
    private static let worker = AgentVisionWorker()

    @MainActor static func handle(name: String, arguments: [String: Any], project: Project) async throws -> [String: Any] {
        let request = try AgentVisionRequest(name: name, arguments: arguments, durationNs: project.durationNs)
        let snapshot = try project.snapshot()
        let data = try await worker.run(request, snapshot: snapshot)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static var tools: [[String: Any]] {
        let time: [String: Any] = ["type": "number", "minimum": 0, "description": "Seconds on the current edited timeline."]
        let times: [String: Any] = ["type": "array", "items": time, "minItems": 1, "maxItems": 48]
        let range: [String: Any] = ["from_s": time, "to_s": time]
        let crop: [String: Any] = ["type": "string", "enum": ["content", "frame"], "description": "content crops the composited recording area, preserving zoom and overlays inside it; frame shows the entire export canvas."]
        func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
            ["name": name, "description": description, "annotations": ["readOnlyHint": true],
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
        }
        return [
            tool("capture", "SEE the CURRENT edit using the export compositor. Default crop:content removes canvas background/padding so UI text is readable, retaining zoom, cursor and overlays inside the recording area. Use crop:frame to verify the entire export including camera, captions and background outside that area. Capture after every stage of editing; contact sheets show what the viewer gets. A clean save does not guarantee a correct-looking composition. Returns labelled PNG images and temporary file paths. Times are seconds; default 6 frames per sheet (maximum 12), up to 4 sheets, each <= 1 MB. With defaults request at most 24 times; use per_sheet:12 for 48. separate=true returns one labelled image per time (maximum 4). The exact end resolves to the final timeline nanosecond.",
                 ["times": times, "separate": ["type": "boolean", "default": false], "per_sheet": ["type": "integer", "minimum": 1, "maximum": 12, "default": 6], "crop": crop.merging(["default": "content"]) { _, b in b }], required: ["times"]),
            tool("grab", "Inspect raw screen or camera source pixels at edited timeline times (seconds), mapped through cuts and speed changes. Use to inspect source detail; use capture to verify what the viewer gets. Camera works even when hidden in the edit; unavailable media returns an error. Returns labelled contact sheets, up to 48 frames in 4 PNGs with paths.",
                 ["times": times, "source": ["type": "string", "enum": ["screen", "camera"], "default": "screen"]], required: ["times"]),
            tool("filmstrip", "Survey the CURRENT composition in labelled contact sheets (default 6 frames, 6 per sheet; count:12 returns 2 sheets), evenly spaced across from_s…to_s (seconds, defaults to the full edit). Uses the export compositor; default crop:frame shows the full canvas, crop:content enlarges the recording area for UI reading. Use before planning and after every stage, then capture key beats more closely. The exact end resolves to the last timeline nanosecond.",
                 range.merging(["count": ["type": "integer", "minimum": 1, "maximum": 12, "default": 6], "per_sheet": ["type": "integer", "minimum": 1, "maximum": 12, "default": 6], "crop": crop.merging(["default": "frame"]) { _, b in b }]) { _, b in b }),
            tool("view_changes", "Find visible source-screen changes after clicks from moments. Optional click_indices are zero-based/global on the CURRENT edited timeline; omit for all clicks (maximum 100 per request). Compares a frame 0.05 s before each click with samples every 0.2 s up to 3 s afterward, stopping at the next edit cut. Returns the first sample whose normalized mean RGB difference reaches threshold (default 0.005, range >0 to 1), or null. Times are timeline SECONDS; timing precision is 0.2 s. Pixel evidence, not proof of navigation or causality: typing/scrolling can also change pixels, and small toasts may stay below threshold. Read-only; ignores editor zooms and overlays.",
                 ["click_indices": ["type": "array", "items": ["type": "integer", "minimum": 0], "maxItems": 100], "threshold": ["type": "number", "exclusiveMinimum": 0, "maximum": 1, "default": 0.005]]),
            tool("waveform", "Inspect silence and speech/activity ranges in edited timeline seconds before tightening pauses. Uses the existing microphone-first silence analysis and Core's exact cut/speed mapping; system audio is the fallback. Reports analysis source, coverage and unknown ranges. Activity estimated from audio energy can include non-speech sounds. Read-only: no cuts or stored analysis changes.", range)
        ]
    }
}

struct AgentVisionRequest: Sendable {
    let name: String
    let times: [Int64]
    let perSheet: Int
    let source: String
    let crop: AgentCaptureCrop
    let clickIndices: [Int]?
    let threshold: Double
    let range: Range<Int64>

    init(name: String, arguments: [String: Any], durationNs: Int64) throws {
        func invalid(_ message: String) -> RenderError { .invalidSettings(message) }
        guard AgentVision.names.contains(name), durationNs > 0 else { throw invalid("Vision requires a nonempty timeline") }
        let allowed: Set<String>
        switch name {
        case "capture": allowed = ["times", "separate", "per_sheet", "crop"]
        case "grab": allowed = ["times", "source"]
        case "filmstrip": allowed = ["count", "from_s", "to_s", "per_sheet", "crop"]
        case "view_changes": allowed = ["click_indices", "threshold"]
        default: allowed = ["from_s", "to_s"]
        }
        guard Set(arguments.keys).isSubset(of: allowed) else { throw invalid("Unknown argument for \(name)") }
        func number(_ value: Any, _ key: String) throws -> Double {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { throw invalid("\(key) must be a finite number") }
            return value.doubleValue
        }
        func integer(_ key: String, fallback: Int, bounds: ClosedRange<Int>) throws -> Int {
            guard let value = arguments[key] else { return fallback }
            let n = try number(value, key)
            guard n >= Double(bounds.lowerBound), n <= Double(bounds.upperBound), n.rounded() == n else { throw invalid("\(key) must be an integer in \(bounds)") }
            return Int(n)
        }
        func ns(_ value: Any, _ key: String) throws -> Int64 {
            let seconds = try number(value, key)
            guard seconds >= 0, seconds <= Double(durationNs) / 1e9 else { throw invalid("\(key) must be within the timeline, in seconds") }
            // Avoid Double(Int64.max)'s rounded-up overflow before conversion.
            if seconds == Double(durationNs) / 1e9 { return durationNs }
            return min(durationNs, Int64((seconds * 1e9).rounded()))
        }
        let start = try arguments["from_s"].map { try ns($0, "from_s") } ?? 0
        let end = try arguments["to_s"].map { try ns($0, "to_s") } ?? durationNs
        guard start < end else { throw invalid("from_s must be before to_s") }
        range = start..<end
        self.name = name
        if name == "capture" || name == "grab" {
            guard let list = arguments["times"] as? [Any], (1...48).contains(list.count) else { throw invalid("times must contain 1…48 timeline seconds") }
            times = try list.map { min(durationNs - 1, try ns($0, "times")) }
        } else if name == "filmstrip" {
            let count = try integer("count", fallback: 6, bounds: 1...12)
            let last = min(durationNs - 1, end)
            times = (0..<count).map { i in start + Int64((Double(last - start) * Double(i) / Double(max(1, count - 1))).rounded()) }
        } else { times = [] }
        var separate = false
        if let value = arguments["separate"] {
            guard let bool = value as? NSNumber, CFGetTypeID(bool) == CFBooleanGetTypeID() else { throw invalid("separate must be a boolean") }
            separate = bool.boolValue
        }
        let requested = try integer("per_sheet", fallback: name == "grab" ? 12 : 6, bounds: 1...12)
        perSheet = separate ? 1 : requested
        guard times.count <= perSheet * 4 else { throw invalid("At most 4 images may be returned; request fewer times or increase per_sheet") }
        if let value = arguments["crop"] {
            guard let value = value as? String, let parsed = AgentCaptureCrop(rawValue: value) else { throw invalid("crop must be content or frame") }
            crop = parsed
        } else { crop = name == "capture" ? .content : .frame }
        if let value = arguments["click_indices"] {
            guard let list = value as? [Any], list.count <= 100 else { throw invalid("click_indices must contain at most 100 integers") }
            clickIndices = try list.map {
                let n = try number($0, "click_indices")
                guard n >= 0, n < Double(Int.max), n.rounded() == n else { throw invalid("click_indices must be nonnegative integers") }
                return Int(n)
            }
        } else { clickIndices = nil }
        threshold = try arguments["threshold"].map { try number($0, "threshold") } ?? 0.005
        guard threshold > 0, threshold <= 1 else { throw invalid("threshold must be greater than 0 and at most 1") }
        if let value = arguments["source"] {
            guard let value = value as? String, ["screen", "camera"].contains(value) else { throw invalid("source must be screen or camera") }
            source = value
        } else { source = "screen" }
    }
}

private actor AgentVisionWorker {
    func run(_ request: AgentVisionRequest, snapshot: Project) async throws -> Data {
        if request.name == "waveform" { return try await waveform(request, snapshot: snapshot) }
        if request.name == "view_changes" { return try viewChanges(request, snapshot: snapshot) }
        let renderer = try AgentFrameRenderer(snapshot: snapshot)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-vision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        var content: [[String: Any]] = [], sheets: [[String: Any]] = []
        for start in stride(from: 0, to: request.times.count, by: request.perSheet) {
            try Task.checkCancellation()
            let times = Array(request.times[start..<min(start + request.perSheet, request.times.count)])
            let png = try autoreleasepool {
                let sheet = try AgentContactSheet.make(times: times) { time, size in
                    if request.name == "grab" { return try renderer.grab(atNs: time, source: request.source) }
                    return try renderer.capture(atNs: time, fitting: size, crop: request.crop)
                }
                return try AgentContactSheet.png(sheet)
            }
            let path = directory.appendingPathComponent("\(request.name)-\(sheets.count + 1).png")
            try png.write(to: path, options: .atomic)
            content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"])
            sheets.append(["path": path.path, "times_s": times.map { Double($0) / 1e9 }, "timecodes": times.map(AgentSheetLayout.timecode), "bytes": png.count])
        }
        let metadata: [String: Any] = ["tool": request.name, "crop": request.name == "grab" ? "source" : request.crop.rawValue, "sheets": sheets, "timeline_duration_s": Double(snapshot.durationNs) / 1e9,
                                       "note": "Frozen current edit. Labels are outside the picture. PNGs may be downscaled to fit the image budget."]
        content.append(["type": "text", "text": String(decoding: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), as: UTF8.self)])
        let result = try JSONSerialization.data(withJSONObject: ["content": content, "structuredContent": metadata, "isError": false])
        complete = true
        return result
    }

    private func viewChanges(_ request: AgentVisionRequest, snapshot: Project) throws -> Data {
        struct Event: Decodable { let type: String; let tlNs: Int64 }
        let clicks = try snapshot.query("{\"q\":\"events\"}", as: [Event].self).filter { $0.type == "down" }
        let indices = request.clickIndices ?? Array(clicks.indices)
        guard indices.count <= 100, indices.allSatisfy({ clicks.indices.contains($0) }) else {
            throw RenderError.invalidSettings("Select at most 100 valid click_indices from moments")
        }
        let clips = try snapshot.query("{\"q\":\"clips\"}", as: [ClipInfo].self)
        let renderer = indices.isEmpty ? nil : try AgentFrameRenderer(snapshot: snapshot)
        var rows: [[String: Any]] = []
        struct Sample { let time: Int64; let index: Int; let baseline: Bool }
        struct Comparison {
            let click: Int64, before: Int64, end: Int64
            var baseline: AgentFrameSignature?
            var changed: Int64?
            var difference: Double?
            var samples = 0
            var sampledTo: Int64?
        }
        var comparisons: [Int: Comparison] = [:], schedule: [Sample] = []
        for index in Set(indices).sorted() {
            let click = clicks[index].tlNs
            guard let clip = clips.first(where: { $0.tlStartNs <= click && click < $0.tlEndNs }) else { continue }
            let before = max(clip.tlStartNs, click - 50_000_000)
            let end = click + min(clip.tlEndNs - 1 - click, 3_000_000_000)
            comparisons[index] = Comparison(click: click, before: before, end: end)
            schedule.append(Sample(time: before, index: index, baseline: true))
            for offset in stride(from: Int64(200_000_000), through: end - click, by: 200_000_000) {
                schedule.append(Sample(time: click + offset, index: index, baseline: false))
            }
        }
        // Interleave overlapping windows in timeline order. This avoids repeated
        // backward seeks and decoding the same GOP for each nearby click.
        var cachedTime: Int64?, cachedSignature: AgentFrameSignature?
        for sample in schedule.sorted(by: { $0.time < $1.time }) {
            try Task.checkCancellation()
            guard var comparison = comparisons[sample.index], comparison.changed == nil else { continue }
            let signature: AgentFrameSignature
            if cachedTime == sample.time, let cachedSignature { signature = cachedSignature }
            else {
                signature = try autoreleasepool { try renderer!.signature(atNs: sample.time) }
                cachedTime = sample.time; cachedSignature = signature
            }
            if sample.baseline { comparison.baseline = signature }
            else if let baseline = comparison.baseline {
                let delta = signature.difference(from: baseline)
                comparison.samples += 1
                comparison.sampledTo = sample.time
                if delta >= request.threshold { comparison.changed = sample.time; comparison.difference = delta }
            }
            comparisons[sample.index] = comparison
        }
        for index in comparisons.keys.sorted() {
            let c = comparisons[index]!
            rows.append(["click_index": index, "at_s": Double(c.click) / 1e9, "baseline_s": Double(c.before) / 1e9,
                         "view_change_s": c.changed.map { Double($0) / 1e9 } as Any? ?? NSNull(),
                         "difference": c.difference as Any? ?? NSNull(), "samples": c.samples,
                         "sampled_to_s": c.sampledTo.map { Double($0) / 1e9 } as Any? ?? NSNull(),
                         "window_end_s": Double(c.end) / 1e9])
        }
        let value: [String: Any] = ["clicks": rows, "threshold": request.threshold, "sample_step_s": 0.2,
                                   "analysis": "source_rgb_mean_absolute_difference",
                                   "note": "First changed sample, not exact transition time or proof the click caused it. Null means no sampled change met the threshold within this clip and 3 seconds. Re-read indices after edits."]
        return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)]], "structuredContent": value, "isError": false])
    }

    private func waveform(_ request: AgentVisionRequest, snapshot: Project) async throws -> Data {
        let rows = try snapshot.renderAudioRanges() ?? []
        let track: RenderAudioRange.Track = rows.contains { $0.track == .mic } ? .mic : .systemAudio
        let used = rows.filter { $0.track == track && $0.fileEndNs > $0.fileStartNs }
        var silence: [SilenceRange] = [], available: [SilenceRange] = []
        for path in Set(used.map(\.path)).sorted() {
            try Task.checkCancellation()
            let base = snapshot.packageURL.resolvingSymlinksInPath().standardizedFileURL
            let url = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard !path.hasPrefix("/"), url.path.hasPrefix(base.path + "/") else { throw RenderError.missingMedia("Audio path escapes its package") }
            let asset = AVURLAsset(url: url)
            guard let audio = try await asset.loadTracks(withMediaType: .audio).first else { throw RenderError.decode("Media has no audio track") }
            let mediaRange = try await audio.load(.timeRange)
            guard mediaRange.start.isNumeric, mediaRange.end.isNumeric else { throw RenderError.decode("Invalid audio coverage") }
            let start = max(0, CMTimeConvertScale(mediaRange.start, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value)
            let end = CMTimeConvertScale(mediaRange.end, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
            guard end > start else { continue }
            available += try snapshot.mapAudioRanges([SilenceRange(startNs: start, endNs: end)], track: track.rawValue, mediaPath: path)
            let local = try await AudioAnalysis.silence(in: url)
            silence += try snapshot.mapAudioRanges(AgentVisionRanges.merge(local, within: start..<end), track: track.rawValue, mediaPath: path)
        }
        let coverage = AgentVisionRanges.merge(available, within: request.range)
        let silent = AgentVisionRanges.merge(silence, within: request.range)
        let speech = coverage.flatMap { AgentVisionRanges.complement(silent, within: $0.startNs..<$0.endNs) }
        let unknown = AgentVisionRanges.complement(coverage, within: request.range)
        func seconds(_ ranges: [SilenceRange]) -> [[String: Double]] { ranges.map { ["start_s": Double($0.startNs) / 1e9, "end_s": Double($0.endNs) / 1e9] } }
        let value: [String: Any] = ["from_s": Double(request.range.lowerBound) / 1e9, "to_s": Double(request.range.upperBound) / 1e9,
                                  "track": track.rawValue, "analysis": used.isEmpty ? "unavailable" : "audio_energy", "threshold_db": -45, "minimum_silence_s": 0.5,
                                  "silence_ranges": seconds(silent), "speech_ranges": seconds(speech), "coverage_ranges": seconds(coverage), "unknown_ranges": seconds(unknown),
                                  "note": "Existing AudioAnalysis silence detector; speech_ranges are non-silent activity estimates, not recognized words. Unrecorded intervals are unknown. Music, mute and mix gain are not speech detection inputs."]
        return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)]], "structuredContent": value, "isError": false])
    }
}

enum AgentVisionRanges {
    static func merge(_ ranges: [SilenceRange], within bounds: Range<Int64>) -> [SilenceRange] {
        var result: [SilenceRange] = []
        for range in ranges.sorted(by: { $0.startNs < $1.startNs }) {
            let a = max(bounds.lowerBound, range.startNs), b = min(bounds.upperBound, range.endNs)
            guard b > a else { continue }
            if let last = result.last, a <= last.endNs { result[result.count - 1].endNs = max(last.endNs, b) }
            else { result.append(SilenceRange(startNs: a, endNs: b)) }
        }
        return result
    }
    static func complement(_ ranges: [SilenceRange], within bounds: Range<Int64>) -> [SilenceRange] {
        var cursor = bounds.lowerBound, result: [SilenceRange] = []
        for range in merge(ranges, within: bounds) {
            if cursor < range.startNs { result.append(SilenceRange(startNs: cursor, endNs: range.startNs)) }
            cursor = range.endNs
        }
        if cursor < bounds.upperBound { result.append(SilenceRange(startNs: cursor, endNs: bounds.upperBound)) }
        return result
    }
}
