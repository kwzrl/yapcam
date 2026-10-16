@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation

extension TranscriptionService {
    public nonisolated static var authorizationState: PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Call only from an explicit user action in the signed application.
    /// transcribe() itself never requests permission.
    @discardableResult public nonisolated static func requestAuthorization() async throws -> PermissionState {
        guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String,
              !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.missingUsageDescription
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume(returning: authorizationState) }
        }
    }
}

struct SpeechAudioWindow: Sendable {
    var startFrame: Int64
    var frameCount: AVAudioFrameCount
    var ownedStartFrame: Int64
    var ownedEndFrame: Int64
}

enum SpeechChunking {
    // Stay below the legacy recognizer's one-minute request limit. One second of
    // overlap supplies boundary context; ownership uses word midpoints to dedupe.
    static func windows(frameCount: Int64, sampleRate: Double) throws -> [SpeechAudioWindow] {
        guard frameCount >= 0, sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 192_000 else {
            throw TranscriptionError.recognitionFailed("Unsupported audio sample rate")
        }
        let maximum = Int64(sampleRate * 45)
        let stride = Int64(sampleRate * 44)
        var result: [SpeechAudioWindow] = []
        var start: Int64 = 0
        while start < frameCount {
            let count = min(maximum, frameCount - start)
            let last = count == frameCount - start
            let halfOverlap = (maximum - stride) / 2
            result.append(SpeechAudioWindow(startFrame: start, frameCount: AVAudioFrameCount(count),
                ownedStartFrame: start == 0 ? 0 : halfOverlap, ownedEndFrame: last ? count : stride + halfOverlap))
            if last { break }
            start += stride
        }
        return result
    }

    static func nanoseconds(_ seconds: Double) -> Int64? {
        let value = (seconds * 1_000_000_000).rounded()
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return nil }
        return Int64(value)
    }

    /// Preserve usable windows when Speech explicitly reports no speech. Other
    /// failures are still fatal; never turn a timeout/denial/cancellation into silence.
    static func collect(windows: [SpeechAudioWindow], sampleRate: Double,
                        recognize: (SpeechAudioWindow) async throws -> [RecognizedSpeechWord]) async throws -> RecognizedSpeech {
        var result = RecognizedSpeech()
        for window in windows {
            try Task.checkCancellation()
            guard let start = nanoseconds(Double(window.startFrame) / sampleRate),
                  let ownedStart = nanoseconds(Double(window.ownedStartFrame) / sampleRate),
                  let ownedEnd = nanoseconds(Double(window.ownedEndFrame) / sampleRate),
                  ownedEnd <= Int64.max - start else {
                throw TranscriptionError.recognitionFailed("Audio duration overflow")
            }
            do {
                let words = try await recognize(window)
                try Task.checkCancellation()
                result.words += shifted(words, startNs: start, ownedStartNs: ownedStart, ownedEndNs: ownedEnd)
            } catch {
                try Task.checkCancellation()
                let native = error as NSError
                if native.domain == "kAFAssistantErrorDomain", native.code == 1110 {
                    result.noSpeechWindows.append((start + ownedStart)..<(start + ownedEnd))
                } else if error is CancellationError || error is TranscriptionError {
                    throw error
                } else { throw TranscriptionError.recognitionFailed(error.localizedDescription) }
            }
        }
        return result
    }

    static func shifted(_ words: [RecognizedSpeechWord], startNs: Int64, ownedStartNs: Int64,
                        ownedEndNs: Int64) -> [RecognizedSpeechWord] {
        words.compactMap { word in
            guard word.startNs >= 0, word.endNs > word.startNs else { return nil }
            let midpoint = word.startNs + (word.endNs - word.startNs) / 2
            guard midpoint >= ownedStartNs, midpoint < ownedEndNs, word.endNs <= Int64.max - startNs else { return nil }
            return RecognizedSpeechWord(text: word.text, startNs: startNs + word.startNs,
                                        endNs: startNs + word.endNs, confidence: word.confidence)
        }
    }
}

/// Shared admission policy: tests exercise the same offline-only request that
/// production uses, without asking for permission or downloading a language pack.
enum OnDeviceSpeechPolicy {
    static func authorize(_ state: PermissionState) throws {
        switch state {
        case .notDetermined: throw TranscriptionError.authorizationRequired
        case .denied: throw TranscriptionError.authorizationDenied
        case .granted: break
        }
    }

    static func locale(_ identifier: String, supported: Set<Locale>) throws -> Locale {
        func key(_ value: String) -> String { value.replacingOccurrences(of: "_", with: "-").lowercased() }
        guard let locale = supported.first(where: { key($0.identifier) == key(identifier) }) else {
            throw TranscriptionError.unsupportedLocale(identifier)
        }
        return locale
    }

    static func request(locale: String, supportsOnDevice: Bool, available: Bool, keyterms: [String] = []) throws -> SFSpeechAudioBufferRecognitionRequest {
        guard supportsOnDevice, available else { throw TranscriptionError.onDeviceUnavailable(locale) }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.contextualStrings = keyterms
        return request
    }

    /// Apple's documented legacy missing-assets code. Do not label generic
    /// service outages or supportsOnDeviceRecognition=false as a missing model.
    /// https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/error
    static func recognitionError(_ error: Error, locale: String) -> Error {
        let native = error as NSError
        if native.domain == "kLSRErrorDomain", native.code == 102 {
            return TranscriptionError.onDeviceModelNotInstalled(locale)
        }
        return error
    }
}

/// Only file decoding and on-device Speech requests happen here. Requests are
/// bounded in memory/time, sequential, and always refuse a network recognizer.
enum AppleOnDeviceSpeech {
    static func recognize(_ url: URL, locale identifier: String, keyterms: [String] = []) async throws -> RecognizedSpeech {
        try Task.checkCancellation()
        try OnDeviceSpeechPolicy.authorize(TranscriptionService.authorizationState)
        let locale = try OnDeviceSpeechPolicy.locale(identifier, supported: SFSpeechRecognizer.supportedLocales())
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriptionError.onDeviceUnavailable(identifier)
        }
        // Admit before decoding, and construct every window with the same policy.
        _ = try OnDeviceSpeechPolicy.request(locale: identifier,
            supportsOnDevice: recognizer.supportsOnDeviceRecognition, available: recognizer.isAvailable, keyterms: keyterms)
        return try await recognizeFile(url) { buffer in
            let request = try OnDeviceSpeechPolicy.request(locale: identifier,
                supportsOnDevice: recognizer.supportsOnDeviceRecognition, available: recognizer.isAvailable, keyterms: keyterms)
            let context = SpeechRequestContext(recognizer: recognizer, request: request, buffer: buffer, locale: identifier)
            return try await SpeechRecognitionJob().run { context.start($0) }
        }
    }

    /// Shared decode/window path; tests can inject native callback outcomes without
    /// requiring Speech permission. Production always installs the on-device request.
    static func recognizeFile(_ url: URL,
                              recognizeWindow: (AVAudioPCMBuffer) async throws -> [RecognizedSpeechWord]) async throws -> RecognizedSpeech {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw TranscriptionError.recognitionFailed("Audio file is empty") }
        let rate = file.processingFormat.sampleRate
        let windows = try SpeechChunking.windows(frameCount: file.length, sampleRate: rate)
        return try await SpeechChunking.collect(windows: windows, sampleRate: rate) { window in
            try Task.checkCancellation()
            file.framePosition = window.startFrame
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: window.frameCount) else {
                throw TranscriptionError.recognitionFailed("Cannot allocate a speech audio window")
            }
            try file.read(into: buffer, frameCount: window.frameCount)
            guard buffer.frameLength == window.frameCount else { throw TranscriptionError.recognitionFailed("Truncated audio file") }
            return try await recognizeWindow(buffer)
        }
    }
}

private final class SpeechRequestContext: @unchecked Sendable {
    let recognizer: SFSpeechRecognizer
    let request: SFSpeechAudioBufferRecognitionRequest
    let buffer: AVAudioPCMBuffer
    let locale: String
    init(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest, buffer: AVAudioPCMBuffer, locale: String) {
        self.recognizer = recognizer; self.request = request; self.buffer = buffer; self.locale = locale
    }
    func start(_ complete: @escaping SpeechRecognitionJob.Completion) -> SpeechRecognitionJob.Cancel {
        let locale = locale
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
                let words = result.bestTranscription.segments.compactMap { segment -> RecognizedSpeechWord? in
                    guard let start = SpeechChunking.nanoseconds(segment.timestamp),
                          let end = SpeechChunking.nanoseconds(segment.timestamp + segment.duration) else { return nil }
                    return RecognizedSpeechWord(text: segment.substring, startNs: start, endNs: end, confidence: segment.confidence)
                }
                complete(.success(words))
            } else if let error { complete(.failure(OnDeviceSpeechPolicy.recognitionError(error, locale: locale))) }
        }
        request.append(buffer)
        request.endAudio()
        let cancellation = SpeechTaskCancellation(task: task)
        return { cancellation.task.cancel() }
    }
}

private final class SpeechTaskCancellation: @unchecked Sendable {
    let task: SFSpeechRecognitionTask
    init(task: SFSpeechRecognitionTask) { self.task = task }
}

/// Callback/timeout/cancellation can race. Resolve once and always cancel the
/// underlying recognizer, including cancellation before its task is installed.
final class SpeechRecognitionJob: @unchecked Sendable {
    typealias Completion = @Sendable (Result<[RecognizedSpeechWord], Error>) -> Void
    typealias Cancel = @Sendable () -> Void
    private let lock = NSLock()
    private var result: Result<[RecognizedSpeechWord], Error>?
    private var continuation: CheckedContinuation<[RecognizedSpeechWord], Error>?
    private var cancel: Cancel?
    private var timeoutTask: Task<Void, Never>?

    func run(timeout: Duration = .seconds(60),
             start: @Sendable (@escaping Completion) -> Cancel) async throws -> [RecognizedSpeechWord] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let existing: Result<[RecognizedSpeechWord], Error>? = lock.withLock {
                    if let result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let existing { continuation.resume(with: existing); return }
                let cancel = start { [weak self] in self?.complete($0) }
                let alreadyDone = lock.withLock {
                    if result != nil { return true }
                    self.cancel = cancel
                    return false
                }
                if alreadyDone { cancel(); return }
                let timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.complete(.failure(TranscriptionError.timedOut))
                }
                let done = lock.withLock {
                    if result != nil { return true }
                    self.timeoutTask = timeoutTask
                    return false
                }
                if done { timeoutTask.cancel() }
            }
        } onCancel: { self.complete(.failure(CancellationError())) }
    }

    private func complete(_ outcome: Result<[RecognizedSpeechWord], Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<[RecognizedSpeechWord], Error>?, Cancel?, Task<Void, Never>?)? in
            guard result == nil else { return nil }
            result = outcome
            defer { continuation = nil; cancel = nil; timeoutTask = nil }
            return (continuation, cancel, timeoutTask)
        }
        guard let pending else { return }
        pending.2?.cancel(); pending.1?()
        pending.0?.resume(with: outcome)
    }
}
