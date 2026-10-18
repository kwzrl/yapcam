import Foundation

/// Built privately before publication, then retained by AudioTimeline until native readers finish.
final class SpeechAudioPreparation: @unchecked Sendable {
    let directory: URL
    private(set) var files: [URL: URL] = [:]
    private(set) var reports: [SpeechEnhancementReport] = []
    init(root: URL) throws {
        directory=root.appendingPathComponent("yapcam-speech-mix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func process(_ sources: [URL],settings: SpeechEnhancementSettings?,mono: Bool,progress: @escaping @Sendable (Double) -> Void) async throws {
        for (index,source) in sources.enumerated() {
            try Task.checkCancellation()
            let destination=directory.appendingPathComponent("mic-\(index).caf")
            var input=source
            if settings?.voiceIsolation == true,let processor=VoiceIsolationBridge.processor() {
                let staged=directory.appendingPathComponent("isolation-input-\(index).\(source.pathExtension)")
                let isolated=directory.appendingPathComponent("isolation-output-\(index).caf")
                do {
                    try FileManager.default.copyItem(at: source,to: staged)
                    let processed=try await processor(staged,isolated)
                    guard processed.standardizedFileURL==isolated.standardizedFileURL,
                          FileManager.default.fileExists(atPath: processed.path) else {
                        throw RenderError.decode("Voice isolation did not publish its requested output")
                    }
                    input=processed
                } catch {
                    // Voice isolation is an optional on-device stage. Unsupported
                    // OS/CPU/audio-unit states retain the DSP result.
                    try? FileManager.default.removeItem(at: isolated)
                    input=source
                }
            }
            let report=try await SpeechEnhancer.prepareMicrophoneFile(input,to: destination,settings: settings,mono: mono) { value in
                progress((Double(index)+value)/Double(sources.count))
            }
            if FileManager.default.fileExists(atPath: destination.path) { files[source]=destination }
            if let report { reports.append(report) }
        }
    }
}

extension AudioTimeline {
    /// Preview/export share the same microphone preparation and mapping. Caller supplies a snapshot.
    static func prepare(project: any RenderProjectSource,range: Range<Int64>,speechEnhancement: SpeechEnhancementSettings? = nil,cacheRoot: URL? = nil,progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> AudioTimeline {
        try Task.checkCancellation()
        try speechEnhancement?.validate()
        let preparation: SpeechAudioPreparation?
        let mono=try await worker { try !project.renderStereoMicrophone() }
        if speechEnhancement != nil || mono {
            let sources=try await worker { try microphoneSources(project: project,range: range) }
            if sources.isEmpty { preparation=nil }
            else {
                let value=try SpeechAudioPreparation(root: cacheRoot ?? FileManager.default.temporaryDirectory)
                try await value.process(sources,settings: speechEnhancement,mono: mono,progress: progress)
                preparation=value.files.isEmpty ? nil : value
            }
        } else { preparation=nil }
        try Task.checkCancellation()
        let result=try await worker { try AudioTimeline(project: project,range: range,speechPreparation: preparation) }
        try Task.checkCancellation()
        progress(1)
        return result
    }
    private static func microphoneSources(project: any RenderProjectSource,range: Range<Int64>) throws -> [URL] {
        var sources=Set<URL>()
        if let rows=try project.renderAudioRanges() {
            for row in rows {
                try Task.checkCancellation(); try row.validate()
                if row.track == .mic && row.tlStartNs<range.upperBound && row.tlEndNs>range.lowerBound && row.fileEndNs>row.fileStartNs {
                    sources.insert(try packageMediaURL(row.path,root: project.packageURL))
                }
            }
        } else {
            let manifest=try RecordingManifest.load(package: project.packageURL),clips=try project.renderClips()
            for segment in manifest.segments {
                try Task.checkCancellation()
                guard let path=segment.files["mic"] else { continue }
                let start=segment.srcStartNs+(segment.trackStartNs["mic"] ?? 0),end=segment.srcStartNs+segment.durationNs
                if clips.contains(where: { max(start,$0.srcStartNs)<min(end,$0.srcEndNs) }) {
                    sources.insert(try packageMediaURL(path,root: project.packageURL.appendingPathComponent("recording")))
                }
            }
        }
        return sources.sorted { $0.path<$1.path }
    }
    /// Forward cancellation to detached metadata/composition work and join before releasing caches.
    private static func worker<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let task=Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try body() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
