@preconcurrency import AVFoundation
import Foundation

/// Speech can revise a cumulative hypothesis or publish only the next utterance.
/// Retain the prefix before the new hypothesis and replace its overlapping tail.
/// Each instance belongs to one audio window; window ownership is applied later.
final class SpeechRecognitionResults: @unchecked Sendable {
    private let lock = NSLock()
    private var words: [RecognizedSpeechWord] = []
    private var finished = false

    func receive(_ snapshot: [RecognizedSpeechWord], isFinal: Bool,
                 error: Error? = nil) -> Result<[RecognizedSpeechWord], Error>? {
        lock.withLock {
            guard !finished else { return nil }
            // A final result wins over an accompanying native error, as before.
            if let error, !isFinal { finished = true; return .failure(error) }
            let incoming = snapshot.filter { $0.startNs >= 0 && $0.endNs > $0.startNs }
                .sorted { $0.startNs < $1.startNs }
            if let first = incoming.first {
                words = Array(words.prefix { $0.endNs <= first.startNs }) + incoming
            }
            guard isFinal else { return nil }
            finished = true
            return .success(words)
        }
    }
}

/// Send normal PCM packets to Speech, rather than appending a 45-second buffer
/// as one packet. Preserve every frame/channel and give each packet its own storage.
enum SpeechAudioPackets {
    static let maximumFrames: AVAudioFrameCount = 4096

    static func forEach(in buffer: AVAudioPCMBuffer,
                        append: (AVAudioPCMBuffer) throws -> Void) throws {
        let frameBytes = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard frameBytes > 0, buffer.frameLength > 0, !source.isEmpty else {
            throw TranscriptionError.recognitionFailed("Speech requires nonempty PCM audio")
        }
        for offset in stride(from: 0, to: Int(buffer.frameLength), by: Int(maximumFrames)) {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(Int(maximumFrames), Int(buffer.frameLength)-offset))
            guard let packet = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else {
                throw TranscriptionError.recognitionFailed("Cannot allocate a speech audio packet")
            }
            packet.frameLength = count
            let destination = UnsafeMutableAudioBufferListPointer(packet.mutableAudioBufferList)
            guard source.count == destination.count else {
                throw TranscriptionError.recognitionFailed("Speech audio channel layout changed")
            }
            for index in source.indices {
                let bytes = Int(count)*frameBytes
                guard let input = source[index].mData, let output = destination[index].mData,
                      Int(source[index].mDataByteSize) >= (offset+Int(count))*frameBytes,
                      Int(destination[index].mDataByteSize) >= bytes else {
                    throw TranscriptionError.recognitionFailed("Truncated speech PCM packet")
                }
                memcpy(output, input.advanced(by: offset*frameBytes), bytes)
            }
            try append(packet)
        }
    }
}
