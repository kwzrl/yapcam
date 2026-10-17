import XCTest
import AVFoundation
import YapcamCore
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
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            throw RenderError.invalidSettings("Regression input must be mono 48k PCM")
        }
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw RenderError.decode("Regression reader ended early") }
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return samples
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

    func testRegressionRecipesMatchTheDocumentedCorePresets() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-f14-presets-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture,to: root)
        defer { print("Cleanup render-owned F14 preset copy: \(root.lastPathComponent)"); try? FileManager.default.removeItem(at: root) }
        let project = try Project.create(package: root)
        try project.apply(.set(path: "autosave",value: .bool(false)))
        for (name,expected) in Self.recipes {
            try project.apply(.set(path: "audio.mic_preset",value: .string(name)))
            let plan = try project.speechEnhancementPlan(), s = plan.settings
            XCTAssertEqual(SpeechEnhancementSettings(highPassHz: s.highPassHz,noiseThresholdDB: s.noiseThresholdDb,
                noiseReductionDB: s.noiseReductionDb,compressorThresholdDB: s.compressorThresholdDb,
                compressorRatio: s.compressorRatio,targetLUFS: s.targetLufs,peakCeilingDBFS: s.peakCeilingDbfs,
                normalizeLoudness: s.normalizeLoudness),expected)
            // Voice remains opt-in processing; don't silently change Core's default.
            XCTAssertEqual(plan.enabled,name != "voice")
        }
    }

    /// Maps an LCG state to a uniform sample in [-1, 1).
    private static func unit(_ seed: UInt64) -> Float {
        let fraction: Double = Double(seed >> 11) / 9_007_199_254_740_992   // 2^53
        return Float(fraction * 2 - 1)
    }

    private func mixture() -> (clean: [Float], noisy: [Float]) {
        let frames = 8*48_000
        var clean = [Float](repeating: 0, count: frames), noise = clean
        var seed: UInt64 = 594150
        for i in 0..<frames {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            noise[i] = Self.unit(seed)
            let t = Double(i)/48_000
            let local = t < 3.5 ? t-0.8 : t-4
            if local > 0 && local < 2.5 {
                let envelope = min(1,local/0.03,(2.5-local)/0.03) * (0.7+0.3*cos(2 * .pi * 3*t))
                let phase = 2 * Double.pi * (170*t+4*sin(2 * .pi * 0.6*t))
                var voiced = 0.0
                for harmonic in 1...8 { voiced += sin(Double(harmonic)*phase)/pow(Double(harmonic),1.3) }
                // A quiet high-frequency component exercises consonant-band retention.
                clean[i] = Float(envelope*(0.16*voiced+0.012*sin(2 * .pi * 4800*t)))
            }
        }
        let cleanEnergy = clean.reduce(0) { $0+Double($1)*Double($1) }
        let noiseEnergy = noise.reduce(0) { $0+Double($1)*Double($1) }
        let scale = sqrt(cleanEnergy/(10*noiseEnergy))
        return (clean,zip(clean,noise).map { $0+Float(scale)*$1 })
    }

    func testSeededSpeechMixtureImprovesEveryRecipeAfterNormalization() throws {
        let (clean,noisy) = mixture()
        let before = Self.sdr(clean,noisy)
        XCTAssertEqual(before,10,accuracy: 0.1)
        for (name,settings) in Self.recipes {
            let result = try SpeechEnhancer.process(interleaved: noisy,channels: 1,settings: settings)
            XCTAssertEqual(result.samples.count,clean.count)
            let after = Self.sdr(clean,result.samples)
            let reduction = Self.level(noisy.suffix(48_000))-Self.level(result.samples.suffix(48_000))
            XCTAssertGreaterThanOrEqual(after,before+3,name)
            XCTAssertGreaterThanOrEqual(reduction,10,name)
            XCTAssertLessThanOrEqual(try XCTUnwrap(result.report.samplePeakDBFS),settings.peakCeilingDBFS+0.00001)
        }
    }

    func testNoiseOnlyIsNeverRaisedToSpeechLoudness() throws {
        var seed: UInt64 = 42
        let noise: [Float] = (0..<96_000).map { _ in
            seed = seed &* 6364136223846793005 &+ 1
            return Self.unit(seed)*0.05
        }
        for (name,settings) in Self.recipes {
            let result = try SpeechEnhancer.process(interleaved: noise,channels: 1,settings: settings)
            XCTAssertEqual(result.report.normalizationGainDB,0,name)
            XCTAssertLessThan(Self.level(result.samples.suffix(48_000)),Self.level(noise.suffix(48_000))-10,name)
        }
    }

    func testNoiseProfileIgnoresDigitalGapsAndDoesNotLearnSteadyVoicedTones() throws {
        var seed: UInt64 = 42
        let noise: [Float] = (0..<96_000).map { _ in
            seed = seed &* 6364136223846793005 &+ 1
            return Self.unit(seed)*0.05
        }
        var learner = SpeechNoiseLearner48k(channels: 1)
        learner.process(Array(repeating: 0,count: 96_000))
        learner.process(noise)
        learner.process(Array(repeating: 0,count: 96_000))
        XCTAssertFalse(try XCTUnwrap(learner.profile).containsSpeech)
        var voiced = SpeechNoiseLearner48k(channels: 1)
        let angularStep = 2.0 * Double.pi * 250.0 / 48_000.0
        let tone: [Float] = (0..<96_000).map { Float(0.2*sin(angularStep*Double($0))) }
        voiced.process(tone)
        XCTAssertNil(voiced.profile,"A steady vowel/tone is not a reliable broadband noise profile")
    }

    func testCenteredOverlapAddHasExactTimingStereoPolarityAndChunkIndependentEdges() {
        // Unity transfer isolates FFT/WOLA timing: impulses at either edge and
        // fractional final windows must survive without a shifted or padded file.
        let profile = SpeechNoiseProfile48k(power: Array(repeating: 0,count: 1025),containsSpeech: true)
        let settings = SpeechEnhancementSettings(highPassHz: 0,noiseReductionDB: 0,normalizeLoudness: false)
        for length in [1,7,511,1024,2049,4807] {
            var input = [Float](repeating: 0,count: length*2)
            for index in Set([0,length/2,length-1]) { input[index*2] = 0.3; input[index*2+1] = -0.3 }
            for chunk in [1,137,4096] {
                var reducer = SpeechNoiseReducer48k(channels: 2,profile: profile,settings: settings)
                var output: [Float] = []
                for start in stride(from: 0,to: length,by: chunk) {
                    output += reducer.process(Array(input[start*2..<min(length,start+chunk)*2]))
                }
                output += reducer.finish()
                XCTAssertEqual(output.count,input.count,"length=\(length),chunk=\(chunk)")
                for (a,b) in zip(input,output) { XCTAssertEqual(a,b,accuracy: 0.000001) }
            }
        }
    }

    func testStreamingNoisyStereoMatchesBufferIncludingFinalFractionalWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-f14-stereo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { print("Cleanup render-owned F14 stereo copy: \(root.lastPathComponent)"); try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.wav"), output = root.appendingPathComponent("output.caf")
        let samples = mixture().noisy.prefix(190_019).flatMap { [$0,-$0] }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,sampleRate: 48_000,channels: 2,interleaved: false))
        var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: input,settings: settings,commonFormat: .pcmFormatFloat32,interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 190_019))
            buffer.frameLength = 190_019
            for i in 0..<190_019 { buffer.floatChannelData![0][i] = samples[i*2]; buffer.floatChannelData![1][i] = samples[i*2+1] }
            try file.write(from: buffer)
        }
        let original = try Data(contentsOf: input)
        let expected = try SpeechEnhancer.process(interleaved: samples,channels: 2)
        let report = try await SpeechEnhancer.processFile(input,to: output)
        let file = try AVAudioFile(forReading: output,commonFormat: .pcmFormatFloat32,interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 4096))
        var actual: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw RenderError.decode("Stereo regression reader ended early") }
            for i in 0..<Int(buffer.frameLength) { actual += [buffer.floatChannelData![0][i],buffer.floatChannelData![1][i]] }
        }
        XCTAssertEqual(actual.count,samples.count)
        XCTAssertEqual(report.frames,190_019)
        for (a,b) in zip(actual,expected.samples) { XCTAssertEqual(a,b,accuracy: 0.000001) }
        XCTAssertEqual(try Data(contentsOf: input),original)
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
            let original = try Data(contentsOf: directory.appendingPathComponent("noisy.wav"))
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
                var row: [String: Any] = ["language": language, "preset": name, "baseline": baseline,
                    "input_si_sdr_db": inputSDR, "output_si_sdr_db": outputSDR, "pause_reduction_db": reduction,
                    "output_lufs": report.outputLUFS as Any? ?? NSNull(), "normalization_gain_db": report.normalizationGainDB,
                    "peak_dbfs": report.samplePeakDBFS as Any? ?? NSNull(), "frames": report.frames]
                if let oracle = env["YAPCAM_F14_METRICS"] {
                    // Optional independent Capture oracle: ffmpeg decodes the CAF,
                    // Python fits SI-SDR, ffmpeg loudnorm measures output loudness.
                    let code = """
                    import importlib.util,json,sys
                    from pathlib import Path
                    spec=importlib.util.spec_from_file_location('oracle',sys.argv[1])
                    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
                    print(json.dumps(module.dsp_metrics(Path(sys.argv[2]),Path(sys.argv[3])),allow_nan=False))
                    """
                    let bytes = try Round3Child().run("/usr/bin/env",["python3","-B","-c",code,oracle,directory.path,output.path],in: scratch,timeout: 60)
                    let independent = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String:Any])
                    let independentSDR = try XCTUnwrap(independent["si_sdr_db"] as? Double)
                    let independentTail = try XCTUnwrap(independent["noise_only_final_second"] as? [String:Any])
                    let independentReduction = try XCTUnwrap(independentTail["reduction_db"] as? Double)
                    let independentLUFS = try XCTUnwrap(independent["output_lufs"] as? Double)
                    XCTAssertEqual(independentSDR,outputSDR,accuracy: 0.00001)
                    XCTAssertEqual(independentReduction,reduction,accuracy: 0.00001)
                    XCTAssertEqual(independentLUFS,try XCTUnwrap(report.outputLUFS),accuracy: 0.2)
                    row["oracle_si_sdr_db"] = independentSDR
                    row["oracle_pause_reduction_db"] = independentReduction
                    row["oracle_lufs"] = independentLUFS
                }
                print("RENDER_F14 " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
                if !baseline {
                    XCTAssertGreaterThanOrEqual(outputSDR, inputSDR, "\(language)/\(name) must not worsen speech SI-SDR")
                    XCTAssertGreaterThanOrEqual(reduction, 10, "\(language)/\(name) must reduce pause noise AFTER normalization")
                    XCTAssertLessThanOrEqual(try XCTUnwrap(report.samplePeakDBFS), settings.peakCeilingDBFS + 0.00001)
                    if settings.normalizeLoudness { XCTAssertEqual(try XCTUnwrap(report.outputLUFS), -16, accuracy: 0.2) }
                }
            }
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("noisy.wav")),original,"Never modify Capture's fixture")
        }
    }
}
