@preconcurrency import AVFoundation
import AudioToolbox
import Darwin
import Foundation

public enum VoiceIsolationError: LocalizedError, Sendable, Equatable {
    case unavailable(String), invalidInput(String), processingFailed(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "Apple voice isolation is unavailable: \(reason)"
        case .invalidInput(let reason): "Cannot isolate this audio: \(reason)"
        case .processingFailed(let reason): "Voice isolation failed: \(reason)"
        }
    }
}

public struct VoiceIsolationReport: Sendable, Equatable {
    public let output: URL
    public let engine: String
    public let sampleRate: Double
    public let channels: UInt32
    public let frames: Int64
    public let compensatedLatencyFrames: Int64
}

/// Local file-to-file groundwork for AUD-06. Call after recording has stopped.
/// Creates an adjacent lossless 48 kHz Float32 CAF, preserving the original and
/// file-local duration. No microphone access, playback, permission prompt or network.
public actor VoiceIsolationService {
    typealias Factory = @Sendable (AVAudioFormat) throws -> any VoiceIsolationKernel
    private let factory: Factory
    public init() { factory = { try AppleVoiceIsolationKernel(format: $0) } }
    init(factory: @escaping Factory) { self.factory = factory }

    @discardableResult public func processFile(_ source: URL, to requestedOutput: URL? = nil) async throws -> VoiceIsolationReport {
        try Task.checkCancellation()
        let output = requestedOutput ?? source.deletingPathExtension().appendingPathExtension("voice-isolated.caf")
        guard source.isFileURL, output.isFileURL, output.pathExtension.lowercased() == "caf",
              source.resolvingSymlinksInPath().standardizedFileURL != output.resolvingSymlinksInPath().standardizedFileURL,
              source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == output.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else {
            throw VoiceIsolationError.invalidInput("Use a new adjacent CAF path; existing files are never replaced")
        }
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = input.processingFormat.sampleRate
        let channels = input.processingFormat.channelCount
        guard input.length > 0, rate.isFinite, (8_000...192_000).contains(rate), (1...2).contains(channels),
              let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels),
              let converter = AVAudioConverter(from: input.processingFormat, to: format) else {
            throw VoiceIsolationError.invalidInput("A nonempty mono/stereo audio file at 8–192 kHz is required")
        }
        // One rounding at the file boundary. No per-block duration accumulation.
        let frameDouble = (Double(input.length) * 48_000 / rate).rounded()
        guard frameDouble > 0, frameDouble < Double(Int64.max) else { throw VoiceIsolationError.invalidInput("Audio duration overflows") }
        let frames = Int64(frameDouble)
        let kernel = try factory(format)
        let latency = kernel.latencyFrames
        guard latency >= 0, latency <= 480_000, frames <= Int64.max - latency else {
            throw VoiceIsolationError.processingFailed("Invalid effect latency")
        }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".voice-isolation-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try autoreleasepool {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let destination = try AVAudioFile(forWriting: temporary, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let decoder = VoiceIsolationDecoder(file: input)
            let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            let processed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            var position: Int64 = 0
            var decoded: Int64 = 0
            while position < frames + latency {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(4096, frames + latency - position))
                converted.frameLength = count
                for channel in 0..<Int(channels) { converted.floatChannelData![channel].initialize(repeating: 0, count: Int(count)) }
                if decoded < frames {
                    let wanted = AVAudioFrameCount(min(Int64(count), frames - decoded))
                    var conversionError: NSError?
                    let status = converter.convert(to: converted, error: &conversionError) { requested, state in
                        decoder.supply(requested, state: state)
                    }
                    if let error = decoder.error { throw error }
                    if status == .error { throw VoiceIsolationError.processingFailed(conversionError?.localizedDescription ?? "Audio conversion failed") }
                    let available = min(wanted, converted.frameLength)
                    // Converter EOS may be one rounding frame short; only that
                    // final frame can be padded, never an unread/corrupt track.
                    guard wanted - available <= 1 else { throw VoiceIsolationError.processingFailed("Audio decoder ended early") }
                    if available < count {
                        for channel in 0..<Int(channels) {
                            converted.floatChannelData![channel].advanced(by: Int(available)).initialize(repeating: 0, count: Int(count - available))
                        }
                    }
                    decoded += Int64(available)
                    if available < wanted { decoded = frames }
                    converted.frameLength = count
                }
                try kernel.process(converted, into: processed)
                guard processed.frameLength == count else { throw VoiceIsolationError.processingFailed("Effect returned a short block") }
                let keep = VoiceIsolationWindow.slice(position: position, count: Int64(count), latency: latency, frames: frames)
                if keep.count > 0 {
                    for channel in 0..<Int(channels) {
                        let data = processed.floatChannelData![channel]
                        for index in 0..<Int(keep.count) {
                            let value = data[Int(keep.offset) + index]
                            guard value.isFinite else { throw VoiceIsolationError.processingFailed("Effect returned nonfinite audio") }
                            data[index] = value
                        }
                    }
                    processed.frameLength = AVAudioFrameCount(keep.count)
                    try destination.write(from: processed)
                }
                position += Int64(count)
            }
        }
        let verified: AVAudioFile
        do { verified = try AVAudioFile(forReading: temporary) }
        catch { throw VoiceIsolationError.processingFailed("Cannot verify completed CAF: \(error)") }
        guard verified.length == frames else { throw VoiceIsolationError.processingFailed("Output duration mismatch") }
        try Task.checkCancellation()
        // Atomic exclusive publication; even a competing writer cannot be replaced.
        let fd = open(temporary.path, O_RDONLY)
        guard fd >= 0 else { throw VoiceIsolationError.processingFailed("Cannot open completed file") }
        let syncResult = fsync(fd); close(fd)
        guard syncResult == 0, link(temporary.path, output.path) == 0 else {
            throw VoiceIsolationError.processingFailed("Cannot publish enhanced audio (destination may already exist)")
        }
        let directory = open(output.deletingLastPathComponent().path, O_RDONLY)
        if directory >= 0 { _ = fsync(directory); close(directory) }
        return VoiceIsolationReport(output: output, engine: "apple_au_sound_isolation_voice", sampleRate: 48_000,
                                    channels: channels, frames: frames, compensatedLatencyFrames: latency)
    }
}

protocol VoiceIsolationKernel: AnyObject {
    var latencyFrames: Int64 { get }
    func process(_ input: AVAudioPCMBuffer, into output: AVAudioPCMBuffer) throws
}

enum VoiceIsolationWindow {
    static func slice(position: Int64, count: Int64, latency: Int64, frames: Int64) -> (offset: Int64, count: Int64) {
        let start = max(position, latency), end = min(position + count, latency + frames)
        return (min(count, max(0, start - position)), max(0, end - start))
    }
}

private final class AppleVoiceIsolationKernel: VoiceIsolationKernel {
    private let unit: AUAudioUnit
    private var position: Int64 = 0
    let latencyFrames: Int64
    init(format: AVAudioFormat) throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard AudioComponentFindNext(nil, &description) != nil else {
            throw VoiceIsolationError.unavailable("AUSoundIsolation is not registered in this process")
        }
        do {
            unit = try AUAudioUnit(componentDescription: description)
            guard unit.inputBusses.count == 1, unit.outputBusses.count == 1 else {
                throw VoiceIsolationError.unavailable("Unsupported effect bus layout")
            }
            try unit.inputBusses[0].setFormat(format)
            try unit.outputBusses[0].setFormat(format)
            unit.maximumFramesToRender = 4096
            unit.isRenderingOffline = true
            guard let tree = unit.parameterTree,
                  let mix = tree.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent)),
                  let voice = tree.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_SoundToIsolate)) else {
                throw VoiceIsolationError.unavailable("Voice isolation parameters are unavailable")
            }
            mix.value = 100
            voice.value = AUValue(kAUSoundIsolationSoundType_Voice)
            unit.shouldBypassEffect = false
            guard abs(mix.value - 100) < 0.01, voice.value == AUValue(kAUSoundIsolationSoundType_Voice) else {
                throw VoiceIsolationError.unavailable("Voice isolation parameters were rejected")
            }
            try unit.allocateRenderResources()
            let delay = (unit.latency * format.sampleRate).rounded()
            guard delay.isFinite, delay >= 0, delay <= 480_000 else { throw VoiceIsolationError.unavailable("Invalid native effect latency") }
            latencyFrames = Int64(delay)
        } catch { throw VoiceIsolationError.unavailable(error.localizedDescription) }
    }
    deinit { unit.deallocateRenderResources() }
    func process(_ input: AVAudioPCMBuffer, into output: AVAudioPCMBuffer) throws {
        output.frameLength = input.frameLength
        var flags: AudioUnitRenderActionFlags = []
        var time = AudioTimeStamp()
        time.mSampleTime = Double(position); time.mFlags = .sampleTimeValid
        let inputList = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let status = unit.renderBlock(&flags, &time, input.frameLength, 0, output.mutableAudioBufferList) { _, _, count, bus, data in
            guard bus == 0, count == input.frameLength else { return kAudioUnitErr_InvalidPropertyValue }
            let destination = UnsafeMutableAudioBufferListPointer(data)
            guard destination.count == inputList.count else { return kAudioUnitErr_FormatNotSupported }
            for index in 0..<destination.count {
                let bytes = Int(count) * MemoryLayout<Float>.size
                if let pointer = destination[index].mData {
                    guard Int(destination[index].mDataByteSize) >= bytes else { return kAudioUnitErr_TooManyFramesToProcess }
                    memcpy(pointer, inputList[index].mData!, bytes)
                } else { destination[index].mData = inputList[index].mData }
                destination[index].mDataByteSize = UInt32(bytes)
            }
            return noErr
        }
        guard status == noErr else { throw VoiceIsolationError.processingFailed("AUSoundIsolation render status \(status)") }
        position += Int64(input.frameLength)
    }
}

/// Converter callbacks are synchronous; a lock also protects state if native code
/// changes its callback scheduling. This object owns its decoder and scratch PCM.
private final class VoiceIsolationDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private var exhausted = false
    private var readError: Error?
    var error: Error? { lock.withLock { readError } }
    init(file: AVAudioFile) {
        self.file = file
        buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
    }
    func supply(_ requested: AVAudioPacketCount, state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            if exhausted || file.framePosition >= file.length { state.pointee = .endOfStream; return nil }
            do {
                try file.read(into: buffer, frameCount: min(requested, buffer.frameCapacity, AVAudioFrameCount(min(Int64(UInt32.max), file.length - file.framePosition))))
                if buffer.frameLength == 0 { exhausted = true; state.pointee = .endOfStream; return nil }
                state.pointee = .haveData
                return buffer
            } catch { readError = VoiceIsolationError.processingFailed("Cannot decode input PCM: \(error)"); exhausted = true; state.pointee = .endOfStream; return nil }
        }
    }
}
