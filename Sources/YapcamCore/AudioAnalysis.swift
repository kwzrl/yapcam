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
                if let a = quietStart, start-end > 10_000_000 { finish(end); _ = a }
                end = CMTimeConvertScale(CMTimeAdd(time, packetDuration), timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
                if rms <= threshold { if quietStart == nil { quietStart = start } } else { finish(start) }
            }
            if reader.status == .failed { throw reader.error ?? CoreError.status(4, "Audio decoding failed") }
            finish(end)
            return rows
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
