import Foundation
@preconcurrency import AVFoundation

public struct SilenceRange: Codable, Sendable, Equatable {
    public var startNs: Int64
    public var endNs: Int64
    public init(startNs: Int64, endNs: Int64) { self.startNs = startNs; self.endNs = endNs }
    enum CodingKeys: String, CodingKey { case startNs = "tl_start_ns", endNs = "tl_end_ns" }
}
public enum AudioAnalysis {
    /// Decode local audio to Float32 PCM and identify low RMS packets. Returned
    /// times are file-local, not edited timeline time. Cancellation stops decoding.
    public static func silence(in url: URL, thresholdDB: Double = -45, minimumNs: Int64 = 500_000_000) async throws -> [SilenceRange] {
        guard url.isFileURL, (-96...0).contains(thresholdDB), minimumNs > 0 else { throw CoreError.status(1, "Invalid silence analysis options") }
        let task = Task.detached(priority: .utility) { () throws -> [SilenceRange] in
            if ["wav", "caf", "aif", "aiff"].contains(url.pathExtension.lowercased()), let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) {
                return try analyzePCM(file, thresholdDB: thresholdDB, minimumNs: minimumNs)
            }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CoreError.status(1, "Media has no audio track") }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else { throw CoreError.status(6, "PCM decoding unavailable") }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CoreError.status(4, "Cannot decode audio") }
            defer { reader.cancelReading() }
            let threshold = pow(10, thresholdDB/20)
            var rows: [SilenceRange] = []
            var quietStart: Int64?
            var end: Int64 = 0
            func finish(_ t: Int64) { if let a = quietStart, t-a >= minimumNs { rows.append(SilenceRange(startNs: a, endNs: t)) }; quietStart = nil }
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample) else { throw CoreError.status(4, "Audio packet has no PCM data") }
                let length = CMBlockBufferGetDataLength(block)
                guard length > 0 && length % MemoryLayout<Float>.size == 0 else { throw CoreError.status(4, "Invalid Float32 audio packet") }
                var floats = [Float](repeating: 0, count: length/MemoryLayout<Float>.size)
                let status = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                guard status == kCMBlockBufferNoErr else { throw CoreError.status(4, "Cannot read PCM data") }
                let rms = sqrt(floats.reduce(0.0) { $0 + Double($1)*Double($1) } / Double(floats.count))
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                let packetDuration = CMSampleBufferGetDuration(sample)
                let start = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
                if quietStart != nil, start-end > 10_000_000 { finish(end) }
                end = CMTimeConvertScale(CMTimeAdd(time, packetDuration), timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
                if rms <= threshold { if quietStart == nil { quietStart = start } } else { finish(start) }
            }
            if reader.status == .failed { throw reader.error ?? CoreError.status(4, "Audio decoding failed") }
            finish(end)
            return rows
        }
        do { return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch let error as NSError where error.domain == AVFoundationErrorDomain && error.code == -11800 {
            throw CoreError.status(6, "Local audio decoder unavailable: \(error.localizedDescription)")
        }
    }
    private static func analyzePCM(_ file: AVAudioFile, thresholdDB: Double, minimumNs: Int64) throws -> [SilenceRange] {
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else { throw CoreError.status(4, "Invalid PCM format") }
        let threshold = pow(10, thresholdDB/20)
        var rows: [SilenceRange] = []
        var quietStart: Int64?
        func nanoseconds(_ frames: AVAudioFramePosition) -> Int64 { Int64((Double(frames)*1_000_000_000/format.sampleRate).rounded()) }
        func finish(_ t: Int64) { if let a = quietStart, t-a >= minimumNs { rows.append(SilenceRange(startNs: a, endNs: t)) }; quietStart = nil }
        var decodedFrames: AVAudioFramePosition = 0
        while decodedFrames < file.length {
            try Task.checkCancellation()
            let start = nanoseconds(decodedFrames)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(1024, file.length-decodedFrames)))
            if buffer.frameLength == 0 { break }
            guard let channels = buffer.floatChannelData else { throw CoreError.status(4, "PCM decoder returned no samples") }
            var energy = 0.0
            for channel in 0..<Int(format.channelCount) { for frame in 0..<Int(buffer.frameLength) { let x = Double(channels[channel][frame]); energy += x*x } }
            decodedFrames += AVAudioFramePosition(buffer.frameLength)
            let rms = sqrt(energy/Double(buffer.frameLength)/Double(format.channelCount))
            if rms <= threshold { if quietStart == nil { quietStart = start } } else { finish(start) }
        }
        finish(nanoseconds(decodedFrames))
        return rows
    }

}
