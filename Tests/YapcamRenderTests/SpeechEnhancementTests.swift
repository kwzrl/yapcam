import XCTest
import AVFoundation
@testable import YapcamRender

final class SpeechEnhancementTests: XCTestCase {
    func tone(seconds: Double,frequency: Double,amplitude: Double) -> [Float] {
        (0..<Int(seconds*48_000)).map { Float(amplitude*sin(2*Double.pi*frequency*Double($0)/48_000)) }
    }
    func rms(_ samples: ArraySlice<Float>) -> Double { sqrt(samples.reduce(0) { $0+Double($1)*Double($1) }/Double(samples.count)) }
    func testHighPassAndQuietNoiseReductionPreserveSampleCountAndRejectNaN() throws {
        let low=tone(seconds: 2,frequency: 30,amplitude: 0.1), high=tone(seconds: 2,frequency: 1000,amplitude: 0.1)
        let settings=SpeechEnhancementSettings(noiseReductionDB: 0,compressorRatio: 1,normalizeLoudness: false)
        let filteredLow=try SpeechEnhancer.process(interleaved: low,channels: 1,settings: settings)
        let filteredHigh=try SpeechEnhancer.process(interleaved: high,channels: 1,settings: settings)
        XCTAssertEqual(filteredLow.samples.count,low.count)
        XCTAssertLessThan(rms(filteredLow.samples.suffix(48_000))/rms(low.suffix(48_000)),0.15)
        XCTAssertGreaterThan(rms(filteredHigh.samples.suffix(48_000))/rms(high.suffix(48_000)),0.9)
        let noise=tone(seconds: 2,frequency: 3500,amplitude: 0.001)
        let reduced=try SpeechEnhancer.process(interleaved: noise,channels: 1,settings: .init(compressorRatio: 1,normalizeLoudness: false))
        XCTAssertLessThan(rms(reduced.samples.suffix(48_000)),rms(noise.suffix(48_000))*0.1)
        XCTAssertThrowsError(try SpeechEnhancer.process(interleaved: [.nan],channels: 1))
    }
    func testSpeechNormalizationReachesMinus16LUFSAndRespectsPeakCeiling() throws {
        let input=tone(seconds: 3,frequency: 1000,amplitude: 0.07)
        let result=try SpeechEnhancer.process(interleaved: input,channels: 1)
        XCTAssertEqual(try XCTUnwrap(result.report.outputLUFS),-16,accuracy: 0.2)
        XCTAssertTrue(result.report.reachedTarget)
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.report.samplePeakDBFS),-1+0.000_001)
        XCTAssertEqual(result.report.frames,Int64(input.count))
        let silence=try SpeechEnhancer.process(interleaved: Array(repeating: 0,count: 48_000),channels: 1)
        XCTAssertNil(silence.report.outputLUFS); XCTAssertFalse(silence.report.reachedTarget)
        XCTAssertTrue(silence.samples.allSatisfy { $0==0 })
    }
    func testLoudnessUsesChannelEnergyAndGatesLongSilence() throws {
        let input=tone(seconds: 2,frequency: 1000,amplitude: 0.1)
        var mono=try LoudnessMeter48k(channels: 1); try mono.process(interleaved: input)
        var stereo=try LoudnessMeter48k(channels: 2)
        try stereo.process(interleaved: input.flatMap { [$0,-$0] })
        XCTAssertEqual(try XCTUnwrap(stereo.integratedLUFS)-XCTUnwrap(mono.integratedLUFS),10*log10(2),accuracy: 0.001)
        let before=try XCTUnwrap(mono.integratedLUFS)
        try mono.process(interleaved: Array(repeating: 0,count: 8*48_000))
        XCTAssertEqual(try XCTUnwrap(mono.integratedLUFS),before,accuracy: 0.35)
    }
    func testCompressorReducesSpeechDynamicRange() throws {
        let input=tone(seconds: 1,frequency: 1000,amplitude: 0.02)+tone(seconds: 1,frequency: 1000,amplitude: 0.4)
        let output=try SpeechEnhancer.process(interleaved: input,channels: 1,settings: .init(noiseReductionDB: 0,compressorRatio: 4,normalizeLoudness: false)).samples
        let inputContrast=20*log10(rms(input.suffix(24_000))/rms(input[24_000..<48_000]))
        let outputContrast=20*log10(rms(output.suffix(24_000))/rms(output[24_000..<48_000]))
        XCTAssertLessThan(outputContrast,inputContrast-6)
    }
    func testLoudnessAgreesWithIndependentFFmpegEBUR128() throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else { throw XCTSkip("ffmpeg provides an independent loudness oracle") }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-lufs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pcm=tone(seconds: 3,frequency: 997,amplitude: 0.1).map { Int16(($0*32767).rounded()) }
        let url=root.appendingPathComponent("tone.wav"); try ProceduralAudio.wav(pcm).write(to: url)
        var meter=try LoudnessMeter48k(channels: 1); try meter.process(interleaved: pcm.map { Float($0)/32768 })
        let task=Process(), error=Pipe(); task.executableURL=URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        task.arguments=["-hide_banner","-nostats","-i",url.path,"-af","ebur128=peak=none","-f","null","-"]
        task.standardOutput=FileHandle.nullDevice; task.standardError=error
        try task.run(); let data=error.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus,0)
        let text=String(decoding: data,as: UTF8.self), regex=try NSRegularExpression(pattern: #"I:\s*(-?\d+\.\d+)\s+LUFS"#)
        let match=try XCTUnwrap(regex.matches(in: text,range: NSRange(text.startIndex...,in: text)).last)
        let range=try XCTUnwrap(Range(match.range(at: 1),in: text)), oracle=try XCTUnwrap(Double(text[range]))
        XCTAssertEqual(try XCTUnwrap(meter.integratedLUFS),oracle,accuracy: 0.1)
    }
    func testStreamingFileNormalizationPreservesDurationAndExistingDestination() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-speech-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input=root.appendingPathComponent("input.wav"), output=root.appendingPathComponent("output.caf")
        let pcm=tone(seconds: 2,frequency: 1000,amplitude: 0.07).map { Int16(($0*32767).rounded()) }
        try ProceduralAudio.wav(pcm).write(to: input)
        let result=try await SpeechEnhancer.processFile(input,to: output)
        XCTAssertEqual(result.frames,96_000); XCTAssertEqual(try XCTUnwrap(result.outputLUFS),-16,accuracy: 0.2)
        let file=try AVAudioFile(forReading: output); XCTAssertEqual(file.length,96_000)
        let original=try Data(contentsOf: output)
        do { _ = try await SpeechEnhancer.processFile(input,to: output); XCTFail("Must refuse overwrite") } catch {}
        XCTAssertEqual(try Data(contentsOf: output),original)
    }
    func testStreamingResamples44100StereoWithoutChangingDuration() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-speech-resample-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input=root.appendingPathComponent("input.wav"), output=root.appendingPathComponent("output.wav")
        let format=try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,sampleRate: 44_100,channels: 2,interleaved: false))
        var settings=format.settings; settings[AVLinearPCMIsNonInterleaved]=false
        try autoreleasepool {
            let file=try AVAudioFile(forWriting: input,settings: settings,commonFormat: .pcmFormatFloat32,interleaved: false)
            let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 88_200))
            buffer.frameLength=88_200
            for i in 0..<88_200 {
                let sample=Float(0.07*sin(2*Double.pi*1000*Double(i)/44_100))
                buffer.floatChannelData![0][i]=sample; buffer.floatChannelData![1][i] = -sample
            }
            try file.write(from: buffer)
        }
        let result=try await SpeechEnhancer.processFile(input,to: output)
        XCTAssertEqual(result.frames,96_000); XCTAssertEqual(result.channels,2)
        XCTAssertEqual(try XCTUnwrap(result.outputLUFS),-16,accuracy: 0.2)
        let file=try AVAudioFile(forReading: output)
        XCTAssertEqual(file.length,96_000); XCTAssertEqual(file.fileFormat.sampleRate,48_000)
    }
    func testCancelledSpeechProcessingLeavesNoOutputOrPartial() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-speech-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input=root.appendingPathComponent("input.wav"), output=root.appendingPathComponent("output.caf")
        try ProceduralAudio.wav(Array(repeating: 0,count: 48_000)).write(to: input)
        let task=Task { try await SpeechEnhancer.processFile(input,to: output) }; task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".yapcam-speech-") })
    }
}
