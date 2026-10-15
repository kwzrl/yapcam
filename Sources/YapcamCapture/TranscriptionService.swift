import Foundation
import OSLog

public enum TranscriptionTrack: String, Codable, Sendable { case microphone = "mic", systemAudio = "system_audio" }

public enum TranscriptionError: LocalizedError, Sendable, Equatable {
    case authorizationRequired, authorizationDenied, missingUsageDescription
    case onDeviceUnavailable(String), invalidPackage(String), noAudioTrack
    case recognitionFailed(String), timedOut

    public var errorDescription: String? {
        switch self {
        case .authorizationRequired: "Allow Speech Recognition before transcribing."
        case .authorizationDenied: "Speech Recognition access is denied or restricted."
        case .missingUsageDescription: "The app needs NSSpeechRecognitionUsageDescription before requesting Speech Recognition access."
        case .onDeviceUnavailable(let locale): "On-device speech recognition is unavailable for \(locale)."
        case .invalidPackage(let message): "Cannot transcribe this recording: \(message)"
        case .noAudioTrack: "The recording has no audio track for transcription."
        case .recognitionFailed(let message): "On-device transcription failed: \(message)"
        case .timedOut: "On-device transcription timed out."
        }
    }
}

public struct TranscriptWord: Codable, Sendable, Equatable {
    public let text: String
    public let srcStartNs: Int64
    public let srcEndNs: Int64
    public let confidence: Float
    public let segmentIndex: Int
    public let track: TranscriptionTrack

    enum CodingKeys: String, CodingKey {
        case text, confidence, track
        case srcStartNs = "src_start_ns", srcEndNs = "src_end_ns", segmentIndex = "segment_index"
    }
}

/// A recoverable recognition window omitted from an otherwise usable transcript.
public struct TranscriptionWarning: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let srcStartNs: Int64
    public let srcEndNs: Int64
    public let segmentIndex: Int
    public let track: TranscriptionTrack

    enum CodingKeys: String, CodingKey {
        case code, message, track
        case srcStartNs = "src_start_ns", srcEndNs = "src_end_ns", segmentIndex = "segment_index"
    }
}

public struct RecordingTranscript: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let engine: String
    public let locale: String
    public let words: [TranscriptWord]
    public let warnings: [TranscriptionWarning]
    public var isPartial: Bool { !warnings.isEmpty }

    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", engine, locale, words, warnings }

    init(schemaVersion: Int, engine: String, locale: String, words: [TranscriptWord], warnings: [TranscriptionWarning] = []) {
        self.schemaVersion = schemaVersion; self.engine = engine; self.locale = locale
        self.words = words; self.warnings = warnings
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        engine = try values.decode(String.self, forKey: .engine)
        locale = try values.decode(String.self, forKey: .locale)
        words = try values.decode([TranscriptWord].self, forKey: .words)
        warnings = try values.decodeIfPresent([TranscriptionWarning].self, forKey: .warnings) ?? []
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(engine, forKey: .engine)
        try values.encode(locale, forKey: .locale)
        try values.encode(words, forKey: .words)
        if !warnings.isEmpty { try values.encode(warnings, forKey: .warnings) }
    }
}

struct RecognizedSpeech: Sendable {
    var words: [RecognizedSpeechWord] = []
    var noSpeechWindows: [Range<Int64>] = [] // File-local ns; disjoint window ownership.
}

struct RecognizedSpeechWord: Sendable {
    var text: String
    var startNs: Int64
    var endNs: Int64
    var confidence: Float
}

/// Transcribes a finalized recording using Apple's on-device Speech recognizer.
/// Atomic JSON publication; no recording edits, network fallback or permission prompt.
public actor TranscriptionService {
    typealias Recognize = @Sendable (URL, String) async throws -> [RecognizedSpeechWord]
    typealias RecognizeWithWarnings = @Sendable (URL, String) async throws -> RecognizedSpeech
    private let recognize: RecognizeWithWarnings
    private static let logger = Logger(subsystem: "mov.yapcam.Yapcam", category: "Transcription")

    public init() { recognize = { try await AppleOnDeviceSpeech.recognize($0, locale: $1) } }
    init(recognize: @escaping Recognize) {
        self.recognize = { RecognizedSpeech(words: try await recognize($0, $1)) }
    }
    init(recognizeWithWarnings: @escaping RecognizeWithWarnings) { recognize = recognizeWithWarnings }

    /// nil selects mic when present in each segment, otherwise system audio.
    /// Explicit selection skips segments without that track; it never switches it.
    @discardableResult public func transcribe(package: URL, localeIdentifier: String = Locale.current.identifier,
                                             track requestedTrack: TranscriptionTrack? = nil) async throws -> RecordingTranscript {
        try Task.checkCancellation()
        guard package.isFileURL else { throw TranscriptionError.invalidPackage("Expected a local package") }
        let root = package.resolvingSymlinksInPath().standardizedFileURL
        let recording = root.appendingPathComponent("recording", isDirectory: true)
        let manifestURL = try Self.inside("session.json", recording: recording, package: root)
        let output = try Self.inside("transcript.json", recording: recording, package: root)
        _ = try Self.inside("transcript.json.prev", recording: recording, package: root)
        let lease = try RecordingPackageLease(package: root)
        defer { withExtendedLifetime(lease) {} }
        let manifest = try PackageIO.readManifest(at: manifestURL)
        guard manifest.schemaVersion == 1, manifest.status == "complete" else {
            throw TranscriptionError.invalidPackage("Stop or recover the recording first (schema 1 required)")
        }
        var expectedStart: Int64 = 0
        var words: [TranscriptWord] = []
        var warnings: [TranscriptionWarning] = []
        var audioFound = false
        for (position, segment) in manifest.segments.enumerated() {
            try Task.checkCancellation()
            guard segment.index == position, segment.srcStartNs == expectedStart, segment.durationNs > 0,
                  segment.srcStartNs <= Int64.max - segment.durationNs else {
                throw TranscriptionError.invalidPackage("Noncontiguous segment timeline")
            }
            let sourceEnd = segment.srcStartNs + segment.durationNs
            expectedStart = sourceEnd
            let selected = requestedTrack ?? (segment.files["mic"] != nil ? .microphone : .systemAudio)
            guard let path = segment.files[selected.rawValue] else { continue }
            guard let offset = segment.trackStartNs[selected.rawValue], offset >= 0, offset < segment.durationNs else {
                throw TranscriptionError.invalidPackage("Missing or invalid \(selected.rawValue) start offset")
            }
            let audio = try Self.inside(path, recording: recording, package: root)
            guard (try? audio.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw TranscriptionError.invalidPackage("Missing \(selected.rawValue) audio in segment \(position)")
            }
            audioFound = true
            let base = segment.srcStartNs + offset
            let recognition = try await recognize(audio, localeIdentifier)
            for window in recognition.noSpeechWindows {
                guard window.lowerBound >= 0, window.upperBound > window.lowerBound,
                      window.lowerBound < sourceEnd - base else { continue }
                warnings.append(TranscriptionWarning(code: "no_speech_detected",
                    message: "Partial transcript: speech recognition reported no speech in this audio window.",
                    srcStartNs: base + window.lowerBound, srcEndNs: base + min(window.upperBound, sourceEnd - base),
                    segmentIndex: position, track: selected))
            }
            for word in recognition.words {
                // Audio packets may straddle the finalized stop. Retain only the
                // portion in source time, never the pause or an overshooting tail.
                guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      word.startNs >= 0, word.endNs > word.startNs,
                      word.startNs < sourceEnd - base else { continue }
                let start = base + word.startNs
                let end = base + min(word.endNs, sourceEnd - base)
                let confidence = word.confidence.isFinite ? min(1, max(0, word.confidence)) : 0
                words.append(TranscriptWord(text: word.text, srcStartNs: start, srcEndNs: end,
                                            confidence: confidence, segmentIndex: position, track: selected))
            }
        }
        guard audioFound else { throw TranscriptionError.noAudioTrack }
        try Task.checkCancellation()
        words.sort { $0.srcStartNs < $1.srcStartNs }
        let transcript = RecordingTranscript(schemaVersion: 1, engine: "apple_speech_on_device",
                                            locale: localeIdentifier, words: words, warnings: warnings)
        try PackageIO.write(transcript, to: output)
        if transcript.isPartial {
            Self.logger.warning("Partial transcript: \(warnings.count) audio windows reported no speech; other recognized words were retained.")
        }
        return transcript
    }

    private static func inside(_ path: String, recording: URL, package: URL) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw TranscriptionError.invalidPackage("Unsafe recording path")
        }
        let url = recording.appendingPathComponent(path)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = package.path + "/recording/"
        guard resolved.hasPrefix(prefix) else { throw TranscriptionError.invalidPackage("Recording path leaves the package") }
        return url
    }
}
