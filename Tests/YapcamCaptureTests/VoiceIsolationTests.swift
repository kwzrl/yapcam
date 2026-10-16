@preconcurrency import AVFoundation
import Foundation
import AudioToolbox
import Testing
@testable import YapcamCapture

private final class IsolationTestKernel: VoiceIsolationKernel {
    enum Mode: Sendable { case delay, fail, nonfinite, cancel, noConnection }
    let latencyFrames: Int64
    private let mode: Mode
    private var history: [[Float]]
    private var cursor = 0
    private let onProcess: @Sendable () -> Void
    init(channels: UInt32, latency: Int64 = 137, mode: Mode = .delay, onProcess: @escaping @Sendable () -> Void = {}) {
        latencyFrames = latency; self.mode = mode; self.onProcess = onProcess
        history = Array(repeating: Array(repeating: 0, count: Int(max(1, latency))), count: Int(channels))
    }
    func process(_ input: AVAudioPCMBuffer, into output: AVAudioPCMBuffer) throws {
        onProcess()
        if mode == .noConnection { throw VoiceIsolationRenderError.failure(kAudioUnitErr_NoConnection) }
        if mode == .fail { throw VoiceIsolationError.processingFailed("injected") }
        if mode == .cancel { withUnsafeCurrentTask { $0?.cancel() } }
        output.frameLength = input.frameLength
        for frame in 0..<Int(input.frameLength) {
            for channel in 0..<history.count {
                let sample = input.floatChannelData![channel][frame]
                output.floatChannelData![channel][frame] = mode == .nonfinite ? .nan : (latencyFrames == 0 ? sample : history[channel][cursor])
                history[channel][cursor] = sample
            }
            cursor = (cursor + 1) % history[0].count
        }
    }
}

private struct IsolationFixture {
    let root: URL
    var source: URL { root.appendingPathComponent("mic.caf") }
    var output: URL { root.appendingPathComponent("mic.voice-isolated.caf") }
    init(rate: Double = 48_000, channels: UInt32 = 1, frames: UInt32 = 10_003) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-isolation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, frames))!
            buffer.frameLength = frames
            for channel in 0..<Int(channels) { for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.035 + Double(channel))) * 0.2
            } }
            if frames > 0 { try file.write(from: buffer) }
        }
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func service(_ mode: IsolationTestKernel.Mode = .delay) -> VoiceIsolationService {
        VoiceIsolationService { IsolationTestKernel(channels: $0.channelCount, mode: mode) }
    }
    func hasTemporaryFiles() throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".voice-isolation-") }
    }
}

// Serialize native file/converter initialization; fixtures remain independent.
@Suite(.serialized) struct VoiceIsolationTests {
    @Test(arguments: [UInt32(1), UInt32(2)], [Int64(0), 137, 5000]) func isolationCompensatesDelayPreservesFramesAndOriginal(channels: UInt32, latency: Int64) async throws {
        let fixture = try IsolationFixture(channels: channels); defer { fixture.cleanup() }
        let original = try Data(contentsOf: fixture.source)
        let service = VoiceIsolationService { IsolationTestKernel(channels: $0.channelCount, latency: latency) }
        let report = try await service.processFile(fixture.source)
        #expect(report.frames == 10_003 && report.sampleRate == 48_000 && report.channels == channels)
        #expect(report.compensatedLatencyFrames == latency && report.output == fixture.output)
        #expect(try Data(contentsOf: fixture.source) == original)
        let input = try AVAudioFile(forReading: fixture.source), output = try AVAudioFile(forReading: fixture.output)
        let a = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 10_003)!
        let b = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 10_003)!
        try input.read(into: a); try output.read(into: b)
        #expect(a.frameLength == b.frameLength)
        for channel in 0..<Int(channels) { for frame in 0..<10_003 {
            #expect(abs(a.floatChannelData![channel][frame] - b.floatChannelData![channel][frame]) < 0.00001)
        } }
        #expect(try !fixture.hasTemporaryFiles())
    }

    @Test(arguments: [44_100.0, 16_000.0, 96_000.0]) func isolationResamplesWithSingleDurationRounding(rate: Double) async throws {
        let fixture = try IsolationFixture(rate: rate, frames: 12_345); defer { fixture.cleanup() }
        let report = try await fixture.service().processFile(fixture.source)
        #expect(report.frames == Int64((12_345 * 48_000 / rate).rounded()))
        let result = try AVAudioFile(forReading: report.output)
        #expect(result.length == report.frames && result.processingFormat.sampleRate == 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: result.processingFormat, frameCapacity: UInt32(report.frames))!
        try result.read(into: buffer)
        // Check the file clock as well as duration: a constant resampler shift
        // would otherwise pass the frame-count assertion and desync mic audio.
        for index in stride(from: 100, to: Int(report.frames) - 100, by: 997) {
            let expected = Float(sin(Double(index) * rate / 48_000 * 0.035)) * 0.2
            #expect(abs(buffer.floatChannelData![0][index] - expected) < 0.002)
        }
    }

    @Test(arguments: [IsolationTestKernel.Mode.fail, .nonfinite, .cancel]) private func isolationFailureLeavesNoPublishedOrTemporaryOutput(mode: IsolationTestKernel.Mode) async throws {
        let fixture = try IsolationFixture(); defer { fixture.cleanup() }
        let original = try Data(contentsOf: fixture.source)
        let job = Task { try await fixture.service(mode).processFile(fixture.source) }
        do { _ = try await job.value; Issue.record("Expected processing failure") }
        catch { if mode == .cancel { #expect(error is CancellationError) } }
        #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
        #expect(try !fixture.hasTemporaryFiles())
        #expect(try Data(contentsOf: fixture.source) == original)
    }

    @Test func isolationRefusesExistingInputAliasesAndNonAdjacentDestinations() async throws {
        let fixture = try IsolationFixture(); defer { fixture.cleanup() }
        let existing = Data("keep this file".utf8)
        try existing.write(to: fixture.output)
        for destination in [fixture.source, fixture.output, fixture.root.appendingPathComponent("other/mic.caf"), fixture.root.appendingPathComponent("mic.wav")] {
            await #expect(throws: VoiceIsolationError.self) { try await fixture.service().processFile(fixture.source, to: destination) }
        }
        let alias = fixture.root.appendingPathComponent("alias.caf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.source)
        await #expect(throws: VoiceIsolationError.self) { try await fixture.service().processFile(fixture.source, to: alias) }
        #expect(try Data(contentsOf: fixture.output) == existing)
    }

    @Test func isolationRefusesEmptyAudioBeforeConstructingEffect() async throws {
        let fixture = try IsolationFixture(frames: 0); defer { fixture.cleanup() }
        await #expect(throws: VoiceIsolationError.self) { try await fixture.service().processFile(fixture.source) }
        #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
    }

    @Test func isolationWindowOwnsExactlyTheOriginalDurationAcrossBlocks() {
        var count: Int64 = 0
        for position in stride(from: Int64(0), to: 10_003 + 5000, by: 4096) {
            let slice = VoiceIsolationWindow.slice(position: position, count: min(4096, 15_003 - position), latency: 5000, frames: 10_003)
            #expect(slice.offset >= 0 && slice.offset <= 4096)
            count += slice.count
        }
        #expect(count == 10_003)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAPCAM_VOICE_ISOLATION_MEDIA_TESTS"] == "1"))
    func actualAppleVoiceIsolationReducesNoiseAndRetainsSpeech() async throws {
        let fixture = try IsolationFixture(); defer { fixture.cleanup() }
        let speech = fixture.root.appendingPathComponent("say.caf")
        let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-r", "140", "-o", speech.path, "--data-format=LEF32@48000", "Hello. This is an on device voice isolation test. The original microphone recording is preserved."]
        try say.run(); say.waitUntilExit()
        #expect(say.terminationStatus == 0)
        let spoken = try AVAudioFile(forReading: speech, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard spoken.length > 0, spoken.processingFormat.sampleRate == 48_000 else {
            throw VoiceIsolationError.unavailable("say produced no 48 kHz speech; run on the host")
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let speechBuffer = AVAudioPCMBuffer(pcmFormat: spoken.processingFormat, frameCapacity: UInt32(spoken.length))!
        try spoken.read(into: speechBuffer)
        let count = Int(spoken.length) + 192_000
        let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count))!
        mixed.frameLength = UInt32(count)
        var seed: UInt64 = 17
        for index in 0..<count {
            seed = seed &* 6364136223846793005 &+ 1
            let noise = Float(Double(seed >> 32) / Double(UInt32.max) * 2 - 1) * 0.04
            let voice = index >= 96_000 && index < count - 96_000 ? speechBuffer.floatChannelData![0][index - 96_000] : 0
            mixed.floatChannelData![0][index] = noise + voice
        }
        try autoreleasepool { let file = try AVAudioFile(forWriting: fixture.source, settings: format.settings); try file.write(from: mixed) }
        let original = try Data(contentsOf: fixture.source)
        let report = try await VoiceIsolationService().processFile(fixture.source)
        let result = try AVAudioFile(forReading: report.output)
        #expect(result.length == Int64(count))
        let buffer = AVAudioPCMBuffer(pcmFormat: result.processingFormat, frameCapacity: UInt32(count))!
        try result.read(into: buffer)
        func rms(_ data: UnsafeMutablePointer<Float>, _ range: Range<Int>) -> Double {
            sqrt(range.reduce(0.0) { $0 + Double(data[$1]) * Double(data[$1]) } / Double(range.count))
        }
        let quiet = 48_000..<72_000, voiced = 96_000..<(count - 96_000)
        let ratio = rms(buffer.floatChannelData![0], quiet) / rms(mixed.floatChannelData![0], quiet)
        print("AUSoundIsolation noise RMS ratio \(ratio), latency frames \(report.compensatedLatencyFrames)")
        #expect(ratio < 0.5)
        #expect(rms(buffer.floatChannelData![0], voiced) > 0.001)
        #expect(try Data(contentsOf: fixture.source) == original)
    }

    @Test(arguments: [Int64(-1), 480_001]) func isolationRefusesInvalidNativeLatency(latency: Int64) async throws {
        let fixture = try IsolationFixture(); defer { fixture.cleanup() }
        let service = VoiceIsolationService { IsolationTestKernel(channels: $0.channelCount, latency: latency) }
        await #expect(throws: VoiceIsolationError.processingFailed("Invalid effect latency")) { try await service.processFile(fixture.source) }
        #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
        #expect(try !fixture.hasTemporaryFiles())
    }

    @Test func isolationPublicationDoesNotReplaceCompetingWriter() async throws {
        let fixture = try IsolationFixture(); defer { fixture.cleanup() }
        let marker = Data("competing writer".utf8), output = fixture.output
        let service = VoiceIsolationService { format in
            IsolationTestKernel(channels: format.channelCount, onProcess: {
                try? marker.write(to: output, options: .withoutOverwriting)
            })
        }
        await #expect(throws: VoiceIsolationError.processingFailed("Cannot publish enhanced audio (destination may already exist)")) { try await service.processFile(fixture.source) }
        #expect(try Data(contentsOf: output) == marker)
        #expect(try !fixture.hasTemporaryFiles())
    }

    @Test func isolationAbsentNativeComponentReportsUnavailableWithoutPublishing() async throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        // Hosts with the unit registered exercise it in the separate opt-in quality test.
        guard AudioComponentFindNext(nil, &description) == nil else { return }
        let fixture = try IsolationFixture(); defer { fixture.cleanup() }
        do { _ = try await VoiceIsolationService().processFile(fixture.source); Issue.record("Expected unavailable") }
        catch let error as VoiceIsolationError {
            guard case .unavailable = error else { Issue.record("Wrong error: \(error)"); return }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
        #expect(try !fixture.hasTemporaryFiles())
    }

    @Test func offlineNoConnectionHasAnExplicitDSPAlternativeAndPreservesOriginal() async throws {
        let fixture = try IsolationFixture(); defer { fixture.cleanup() }
        let original = try Data(contentsOf: fixture.source)
        let expected = VoiceIsolationRenderError.failure(kAudioUnitErr_NoConnection)
        guard case .unavailable(let message) = expected else { Issue.record("Expected unavailable"); return }
        #expect(message.contains("Offline processing") && message.contains("Noise reduction") && message.contains("Podcast"))
        await #expect(throws: expected) { try await fixture.service(.noConnection).processFile(fixture.source) }
        #expect(try Data(contentsOf: fixture.source) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
        #expect(try !fixture.hasTemporaryFiles())
        #expect(VoiceIsolationRenderError.failure(kAudioUnitErr_TooManyFramesToProcess) == .processingFailed("AUSoundIsolation render status -10874"))
    }

}
