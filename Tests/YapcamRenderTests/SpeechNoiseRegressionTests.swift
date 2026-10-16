import XCTest
import AVFoundation
@testable import YapcamRender

final class SpeechNoiseRegressionTests: XCTestCase {
    static let recipes: [(String, SpeechEnhancementSettings)] = [
        ("voice", .init()),
        ("noise_reduction", .init(highPassHz: 80, noiseThresholdDB: -42, noiseReductionDB: 18, compressorRatio: 1, normalizeLoudness: false)),
        ("podcast", .init(noiseReductionDB: 12, compressorThresholdDB: -20, compressorRatio: 4))
    ]

    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 48_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw RenderError.invalidSettings("Regression input must be mono 48k PCM")
        }
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    // Gain-fitted SI-SDR: identical definition to Capture's independent speech_metrics.py.
    // Never align, trim, or normalize the reference to conceal timing changes.
    static func sdr(_ reference: [Float], _ output: [Float]) -> Double {
        precondition(reference.count == output.count)
        var energy = 0.0, dot = 0.0
        for i in reference.indices { energy += Double(reference[i]) * Double(reference[i]); dot += Double(reference[i]) * Double(output[i]) }
        let gain = dot / max(energy, 1e-30)
        var residual = 0.0
        for i in reference.indices { residual += pow(Double(output[i]) - gain * Double(reference[i]), 2) }
        return 10 * log10(max(1e-30, gain * gain * energy) / max(residual, 1e-30))
    }

    static func level(_ samples: ArraySlice<Float>) -> Double {
        10 * log10(max(1e-30, samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count)))
    }

    func testSuppliedBilingualSpeechFixturesWhenOptedIn() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["YAPCAM_F14_FIXTURES"] else { throw XCTSkip("Opt in to the local bilingual F14 fixtures") }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let media = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Yapcam").path + "/"
        guard root.path.hasPrefix(media) else { throw RenderError.invalidSettings("Local fixtures must remain under Movies/Yapcam") }
        let scratch = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Yapcam/QA/render/f14-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            print("Cleanup render-owned F14 scratch: \(scratch.lastPathComponent)")
            try? FileManager.default.removeItem(at: scratch)
        }
        let baseline = env["YAPCAM_F14_BASELINE"] == "1"
        for language in ["en-US", "de-DE"] {
            let directory = root.appendingPathComponent(language)
            let clean = try Self.read(directory.appendingPathComponent("clean.wav"))
            let noisy = try Self.read(directory.appendingPathComponent("noisy.wav"))
            XCTAssertEqual(noisy.count, clean.count)
            XCTAssertTrue(clean.suffix(48_000).allSatisfy { abs($0) < 1e-6 }, "Tail must be proven speech-free")
            let inputSDR = Self.sdr(clean, noisy)
            for (name, settings) in Self.recipes {
                let output = scratch.appendingPathComponent("\(language)-\(name).caf")
                let report = try await SpeechEnhancer.processFile(directory.appendingPathComponent("noisy.wav"), to: output, settings: settings)
                let enhanced = try Self.read(output)
                XCTAssertEqual(enhanced.count, clean.count)
                guard enhanced.count == clean.count else { continue }
                let outputSDR = Self.sdr(clean, enhanced)
                let reduction = Self.level(noisy.suffix(48_000)) - Self.level(enhanced.suffix(48_000))
                let row: [String: Any] = ["language": language, "preset": name, "baseline": baseline,
                    "input_si_sdr_db": inputSDR, "output_si_sdr_db": outputSDR, "pause_reduction_db": reduction,
                    "output_lufs": report.outputLUFS as Any? ?? NSNull(), "normalization_gain_db": report.normalizationGainDB,
                    "peak_dbfs": report.samplePeakDBFS as Any? ?? NSNull(), "frames": report.frames]
                print("RENDER_F14 " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
                if !baseline {
                    XCTAssertGreaterThanOrEqual(outputSDR, inputSDR, "\(language)/\(name) must not worsen speech SI-SDR")
                    XCTAssertGreaterThanOrEqual(reduction, 10, "\(language)/\(name) must reduce pause noise AFTER normalization")
                    XCTAssertLessThanOrEqual(try XCTUnwrap(report.samplePeakDBFS), settings.peakCeilingDBFS + 0.00001)
                    if settings.normalizeLoudness { XCTAssertEqual(try XCTUnwrap(report.outputLUFS), -16, accuracy: 0.2) }
                }
            }
        }
    }
}
