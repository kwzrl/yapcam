@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import YapcamCapture

private func speechWord(_ text: String, _ start: Int64, _ end: Int64) -> RecognizedSpeechWord {
    RecognizedSpeechWord(text: text, startNs: start, endNs: end, confidence: 1)
}

@Suite struct SpeechRecognitionResultsTests {
    @Test func partialUtterancesAcrossWindowsSurviveTailOnlyFinalResults() async throws {
        // The recognizer sends multiple utterances, with isFinal only on the last.
        // Include a revised cumulative hypothesis and the one-second window overlap.
        let windows = try SpeechChunking.windows(frameCount: 66_280*48, sampleRate: 48_000)
        let result = try await SpeechChunking.collect(windows: windows, sampleRate: 48_000) { window in
            let updates: [([RecognizedSpeechWord], Bool)]
            if window.startFrame == 0 {
                updates = [([speechWord("Hello", 1_000_000_000, 1_400_000_000)], false),
                           ([speechWord("Hallo", 1_000_000_000, 1_400_000_000)], false),
                           ([speechWord("middle", 20_000_000_000, 20_400_000_000)], false),
                           ([speechWord("overlap", 44_600_000_000, 44_900_000_000)], true)]
            } else {
                updates = [([speechWord("overlap", 600_000_000, 900_000_000)], false),
                           ([speechWord("later", 10_000_000_000, 10_400_000_000)], false),
                           ([speechWord("ending", 20_000_000_000, 20_400_000_000)], true)]
            }
            return try await SpeechRecognitionJob().run { complete in
                let results = SpeechRecognitionResults()
                for (words, final) in updates {
                    if let outcome = results.receive(words, isFinal: final) { complete(outcome) }
                }
                return {}
            }
        }
        #expect(result.words.map(\.text) == ["Hallo", "middle", "overlap", "later", "ending"])
        #expect(result.words.map(\.startNs) == [1_000_000_000, 20_000_000_000, 44_600_000_000, 54_000_000_000, 64_000_000_000])
        #expect(result.noSpeechWindows.isEmpty)
    }

    @Test func cumulativeRevisionsReplacePreviousWordsAndFinalSnapshotIsNotDuplicated() throws {
        let results = SpeechRecognitionResults()
        _ = results.receive([speechWord("we", 0, 10), speechWord("wrong", 10, 20)], isFinal: false)
        _ = results.receive([speechWord("we", 0, 10), speechWord("record", 10, 22)], isFinal: false)
        let final = try #require(results.receive([speechWord("we", 0, 10), speechWord("record", 10, 22), speechWord("today", 22, 30)], isFinal: true)).get()
        #expect(final.map(\.text) == ["we", "record", "today"])
        #expect(final.map(\.endNs) == [10, 22, 30])
        #expect(results.receive([speechWord("duplicate", 40, 50)], isFinal: true) == nil)
    }

    @Test func overlappingTailRevisionsKeepOnlyTheEarlierPrefix() throws {
        let results = SpeechRecognitionResults()
        _ = results.receive([speechWord("first", 0, 10), speechWord("old", 10, 20)], isFinal: false)
        let final = try #require(results.receive([speechWord("new", 10, 25)], isFinal: true)).get()
        #expect(final.map(\.text) == ["first", "new"])
    }

    @Test func errorsStillFailTheWindowAndInvalidPartialTimingsAreNotInvented() throws {
        let results = SpeechRecognitionResults()
        _ = results.receive([speechWord("good", 10, 20), speechWord("invalid", 0, 0)], isFinal: false)
        let outcome = try #require(results.receive([], isFinal: false, error: TranscriptionError.onDeviceModelNotInstalled("de-DE")))
        #expect(throws: TranscriptionError.onDeviceModelNotInstalled("de-DE")) { try outcome.get() }
        #expect(results.receive([], isFinal: true) == nil)
        let emptyFinal = SpeechRecognitionResults()
        _ = emptyFinal.receive([speechWord("valid", 10, 20), speechWord("invalid", -1, 0)], isFinal: false)
        #expect(try #require(emptyFinal.receive([], isFinal: true)).get().map(\.text) == ["valid"])
    }

    @Test(arguments: [false, true]) func packetizedAudioPreservesEveryFrameAndChannel(interleaved: Bool) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10_003)!
        input.frameLength = 10_003
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        for channel in source.indices {
            let values = source[channel].mData!.assumingMemoryBound(to: Float.self)
            for index in 0..<(Int(source[channel].mDataByteSize)/4) { values[index] = Float(index + channel*100_000) }
        }
        var reconstructed = Array(repeating: Data(), count: source.count)
        var lengths: [AVAudioFrameCount] = []
        try SpeechAudioPackets.forEach(in: input) { packet in
            lengths.append(packet.frameLength)
            let data = UnsafeMutableAudioBufferListPointer(packet.mutableAudioBufferList)
            for index in data.indices { reconstructed[index].append(Data(bytes: data[index].mData!, count: Int(data[index].mDataByteSize))) }
        }
        #expect(lengths == [4096, 4096, 1811])
        for index in source.indices { #expect(reconstructed[index] == Data(bytes: source[index].mData!, count: Int(source[index].mDataByteSize))) }
    }
}
