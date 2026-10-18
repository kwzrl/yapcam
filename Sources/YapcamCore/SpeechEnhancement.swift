import Foundation
@preconcurrency import AVFoundation

public enum MicrophonePreset: String, Codable, Sendable, CaseIterable {
    case voice, noiseReduction = "noise_reduction", podcast
}

public struct CoreSpeechEnhancementSettings: Codable, Sendable, Equatable {
    public var highPassHz: Double
    public var noiseThresholdDb: Double
    public var noiseReductionDb: Double
    public var compressorThresholdDb: Double
    public var compressorRatio: Double
    public var targetLufs: Double
    public var peakCeilingDbfs: Double
    public var normalizeLoudness: Bool
    public init(highPassHz: Double = 90, noiseThresholdDb: Double = -45, noiseReductionDb: Double = 30, compressorThresholdDb: Double = -24, compressorRatio: Double = 3, targetLufs: Double = -16, peakCeilingDbfs: Double = -1, normalizeLoudness: Bool = true) {
        self.highPassHz = highPassHz; self.noiseThresholdDb = noiseThresholdDb; self.noiseReductionDb = noiseReductionDb; self.compressorThresholdDb = compressorThresholdDb; self.compressorRatio = compressorRatio; self.targetLufs = targetLufs; self.peakCeilingDbfs = peakCeilingDbfs; self.normalizeLoudness = normalizeLoudness
    }
}
public struct SpeechEnhancementPlan: Decodable, Sendable, Equatable {
    public struct Media: Decodable, Sendable, Equatable {
        public var path: String
        public var mediaIndex: UInt32
    }
    public var enabled: Bool
    public var micPreset: MicrophonePreset?
    public var stereoMic: Bool?
    public var settings: CoreSpeechEnhancementSettings
    public var media: [Media]
}
public struct RecordingAudioDefaults: Decodable, Sendable, Equatable {
    public var hasMicrophone: Bool
    public var speechEnhancement: Bool
    public var stereoMicrophone: Bool
    public var shouldMuteForNoSpeech: Bool
}
public struct PreparedMicrophoneMedia: Sendable, Equatable {
    public var originalPath: String
    public var processedURL: URL
    public var durationNs: Int64
    public var channels: UInt32
    public var sampleRate: Double
}

public struct MicrophoneMediaIdentity: Codable, Sendable, Equatable {
    public var path: String
    public var size: UInt64
    public var headHash: String
    static func read(_ url: URL, path: String) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw CoreError.status(4, "Cannot inspect microphone source size") }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: 1_048_576) ?? Data()
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Self(path: path, size: size.uint64Value, headHash: "fnv1a64:" + String(format: "%016llx", hash))
    }
}
struct SpeechFileInfo {
    let durationNs: Int64
    let channels: UInt32
    let sampleRate: Double
    static func pcm(_ file: AVAudioFile) throws -> Self {
        let format = file.fileFormat
        let value = (Double(file.length) / format.sampleRate * 1e9).rounded()
        guard format.sampleRate.isFinite && format.sampleRate > 0 && (1...2).contains(format.channelCount) && file.length > 0 && value.isFinite && value > 0 && value < Double(Int64.max) else { throw CoreError.status(1, "Invalid microphone audio duration/channels") }
        return Self(durationNs: Int64(value), channels: format.channelCount, sampleRate: format.sampleRate)
    }
    static func source(_ url: URL) async throws -> Self {
        if ["wav", "caf", "aif", "aiff"].contains(url.pathExtension.lowercased()) { return try pcm(AVAudioFile(forReading: url)) }
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CoreError.status(1, "Microphone file has no audio track") }
            let range = try await track.load(.timeRange)
            let ns = CMTimeConvertScale(range.end, timescale: 1_000_000_000, method: .roundHalfAwayFromZero)
            let formats = try await track.load(.formatDescriptions)
            guard let asbd = formats.first.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }), ns.isNumeric && ns.value > 0 && (1...2).contains(asbd.mChannelsPerFrame), asbd.mSampleRate.isFinite && asbd.mSampleRate > 0 else { throw CoreError.status(1, "Invalid microphone audio metadata") }
            return Self(durationNs: ns.value, channels: asbd.mChannelsPerFrame, sampleRate: asbd.mSampleRate)
        } catch let error as CoreError { throw error }
        catch { throw CoreError.status(6, "Microphone audio metadata unavailable: \(error.localizedDescription)") }
    }
}

extension Project {
    @discardableResult public func setMicrophonePreset(_ preset: MicrophonePreset) throws -> ChangeSet {
        try apply(.set(path: "audio.mic_preset", value: .string(preset.rawValue)))
    }
    public func speechEnhancementPlan() throws -> SpeechEnhancementPlan {
        try query("{\"q\":\"speech_enhancement\"}", as: SpeechEnhancementPlan.self)
    }
    /// Capture-time choices from recording/session.json. Apply these after a
    /// default preset/last look so the recorded microphone choice wins.
    public func recordingAudioDefaults() throws -> RecordingAudioDefaults {
        try query("{\"q\":\"recording_audio_defaults\"}", as: RecordingAudioDefaults.self)
    }
    /// Supply Render's offline SpeechEnhancer via an Editor closure, avoiding a
    /// Core->Render dependency cycle. Originals/clocks/settings are never edited.
    /// Results belong to the captured plan; use an export snapshot or a preview
    /// generation token to prevent applying them after settings have changed.
    public func prepareSpeechEnhancement(using processor: @Sendable (URL, URL, CoreSpeechEnhancementSettings) async throws -> Void) async throws -> [PreparedMicrophoneMedia] {
        try Task.checkCancellation()
        let snapshot = try snapshot()
        let plan = try snapshot.speechEnhancementPlan()
        guard plan.enabled && !plan.media.isEmpty else { return [] }
        let fingerprints = try snapshot.query("{\"q\":\"media\"}", as: [MicrophoneMediaIdentity].self)
        let cache = packageURL.appendingPathComponent("cache/speech", isDirectory: true)
        let root = packageURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard cache.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw CoreError.status(1, "Speech cache directory escapes package") }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let run = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: run) } }
        let runRoot = run.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard runRoot.hasPrefix(root) else { throw CoreError.status(1, "Speech cache run escapes package") }
        var result: [PreparedMicrophoneMedia] = []
        for (i, media) in plan.media.enumerated() {
            try Task.checkCancellation()
            let index = Int(media.mediaIndex)
            guard fingerprints.indices.contains(index) && fingerprints[index].path == media.path else { throw CoreError.status(1, "Microphone media index changed") }
            let source = try snapshot.mediaURL(atIndex: media.mediaIndex)
            guard try MicrophoneMediaIdentity.read(source, path: media.path) == fingerprints[index] else { throw CoreError.missingMedia([media.path]) }
            let original = try await SpeechFileInfo.source(source)
            let output = run.appendingPathComponent("mic-\(i).caf")
            try await processor(source, output, plan.settings)
            try Task.checkCancellation()
            guard try MicrophoneMediaIdentity.read(source, path: media.path) == fingerprints[index] else { throw CoreError.missingMedia([media.path]) }
            guard output.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(runRoot) else { throw CoreError.status(1, "Processed microphone escapes cache run") }
            let processed = try AVAudioFile(forReading: output)
            let info = try SpeechFileInfo.pcm(processed)
            guard processed.fileFormat.commonFormat == .pcmFormatFloat32 && info.sampleRate == 48_000 && info.channels == original.channels && abs(info.durationNs - original.durationNs) <= 20_834 else { throw CoreError.status(1, "Processed microphone format/duration must preserve original timing") }
            result.append(PreparedMicrophoneMedia(originalPath: media.path, processedURL: output, durationNs: info.durationNs, channels: info.channels, sampleRate: info.sampleRate))
        }
        try Task.checkCancellation()
        complete = true
        return result
    }
}
