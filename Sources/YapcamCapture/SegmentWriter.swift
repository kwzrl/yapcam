@preconcurrency import AVFoundation
import ScreenCaptureKit

enum AuxiliaryTrack: String, Sendable { case camera, microphone = "mic" }

protocol CaptureTrackSink: AnyObject, Sendable {
    var url: URL { get }
    var firstNs: Int64 { get }
    func append(_ sample: CMSampleBuffer) throws -> Bool
    func finish() async throws
}

/// All mutable writer state is confined to queue, including AV capture callbacks.
final class SegmentWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias TrackFactory = @Sendable (URL, String, CMSampleBuffer) throws -> any CaptureTrackSink
    let queue = DispatchQueue(label: "mov.yapcam.capture.samples", qos: .userInitiated)
    let directory: URL
    let hostStartNs: Int64
    let maxFPS: Int
    private let makeTrack: TrackFactory
    private var tracks: [String: any CaptureTrackSink] = [:]
    private var failure: CaptureError?
    private var accepting = true
    private var unavailableTracks: Set<String> = []
    private var lastScreenNs: Int64?
    private var endHostNs: Int64?
    var onWarning: (@Sendable (String) -> Void)?
    var onFailure: (@Sendable (CaptureError) -> Void)?
    var onGeometry: (@Sendable (CGRect, CGRect, CGFloat) -> Void)?
    var onTrackStarted: (@Sendable (String, Int64) -> Void)?
    var onMicLevel: (@Sendable (Float) -> Void)?

    init(directory: URL, hostStartNs: Int64, maxFPS: Int,
         makeTrack: @escaping TrackFactory = { try MediaTrackWriter(url: $0, key: $1, first: $2) }) {
        self.directory = directory; self.hostStartNs = hostStartNs; self.maxFPS = maxFPS
        self.makeTrack = makeTrack
    }

    func end(at hostNs: Int64) {
        queue.async { self.endHostNs = hostNs }
    }

    /// Called from device notifications, which may arrive on arbitrary queues.
    /// Keep the prior samples; ignore all future samples from the lost device.
    func deviceUnavailable(_ track: AuxiliaryTrack, reason: String) {
        queue.async { self.disable(track, reason: reason) }
    }

    private func disable(_ track: AuxiliaryTrack, reason: String) {
        guard accepting, unavailableTracks.insert(track.rawValue).inserted else { return }
        onWarning?(reason)
        if track == .microphone { onMicLevel?(0) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            if let info = attachments.first, let screen = Self.rect(info[.screenRect]),
               let content = Self.rect(info[.contentRect]), let scale = info[.scaleFactor] as? CGFloat {
                onGeometry?(screen, content, scale)
            }
            append(sampleBuffer, track: "screen")
        case .audio: append(sampleBuffer, track: "system_audio")
        default: break
        }
    }

    private static func rect(_ value: Any?) -> CGRect? {
        if let value = value as? NSValue { return value.rectValue }
        if let dictionary = value as? [String: Any] { return CGRect(dictionaryRepresentation: dictionary as CFDictionary) }
        return nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(.from(error))
    }

    /// Caller must deliver samples on queue. AVCapture sample clocks are converted before this call.
    func append(_ sample: CMSampleBuffer, track key: String) {
        guard accepting, failure == nil, !unavailableTracks.contains(key) else { return }
        let pts = sample.presentationTimeStamp
        let ns = CaptureClock.nanoseconds(pts)
        guard pts.isNumeric, ns >= hostStartNs, endHostNs == nil || ns < endHostNs! else { return }
        if key == "screen", let lastScreenNs, ns - lastScreenNs < 1_000_000_000 / Int64(maxFPS) { return }
        do {
            let track: any CaptureTrackSink
            if let existing = tracks[key] { track = existing }
            else {
                let filename = key == "system_audio" ? "system.m4a" : key == "mic" ? "mic.m4a" : "\(key).mov"
                track = try makeTrack(directory.appendingPathComponent(filename), key, sample)
                tracks[key] = track
                let starts = tracks.mapValues { $0.firstNs - hostStartNs }
                try PackageIO.write(starts, to: directory.appendingPathComponent("track-starts.json"))
                onTrackStarted?(key, track.firstNs - hostStartNs)
            }
            if try track.append(sample), key == "screen" { lastScreenNs = ns }
            if key == "mic" { onMicLevel?(Self.level(sample)) }
        } catch {
            let error = CaptureError.writerFailed(error.localizedDescription)
            if let auxiliary = AuxiliaryTrack(rawValue: key) {
                disable(auxiliary, reason: "\(key == "mic" ? "Microphone" : "Camera") track failed; screen recording continues. \(error.localizedDescription)")
            } else {
                failure = error
                onFailure?(error)
            }
        }
    }

    static func level(_ sample: CMSampleBuffer) -> Float {
        guard let format = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32,
              let block = sample.dataBuffer else { return 0 }
        var length = 0
        var bytes: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &bytes) == noErr,
              let bytes, length >= 4 else { return 0 }
        return bytes.withMemoryRebound(to: Float.self, capacity: length / 4) { values in
            var sum: Float = 0
            for i in 0..<(length / 4) { sum += values[i] * values[i] }
            return min(1, sqrt(sum / Float(length / 4)))
        }
    }

    struct Result: Sendable {
        var files: [String: String]
        var starts: [String: Int64]
        var error: CaptureError?
    }

    func finish() async -> Result {
        await withCheckedContinuation { continuation in
            queue.async {
                self.accepting = false
                let tracks = self.tracks
                let initialFailure = self.failure
                Task {
                    var files: [String: String] = [:]
                    var starts: [String: Int64] = [:]
                    var error = initialFailure
                    for (key, track) in tracks {
                        do {
                            try await track.finish()
                            files[key] = track.url.lastPathComponent
                            starts[key] = track.firstNs - self.hostStartNs
                        } catch let caught {
                            if key == "screen" || key == "system_audio" { error = .writerFailed(caught.localizedDescription) }
                            else { self.onWarning?("\(key) track could not be finalized: \(caught.localizedDescription)") }
                        }
                    }
                    if files["screen"] == nil, error == nil { error = .writerFailed("No screen frames were captured") }
                    continuation.resume(returning: Result(files: files, starts: starts, error: error))
                }
            }
        }
    }
}

private final class MediaTrackWriter: CaptureTrackSink, @unchecked Sendable {
    let url: URL
    let firstNs: Int64
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var lastPTS: CMTime?
    private var appended = false

    init(url: URL, key: String, first sample: CMSampleBuffer) throws {
        self.url = url
        firstNs = CaptureClock.nanoseconds(sample.presentationTimeStamp)
        let video = key == "screen" || key == "camera"
        writer = try AVAssetWriter(outputURL: url, fileType: video ? .mov : .m4a)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        guard let format = sample.formatDescription else { throw CaptureError.writerFailed("Missing sample format") }
        var settings: [String: Any]
        if video {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            settings = [AVVideoCodecKey: AVVideoCodecType.hevc,
                        AVVideoWidthKey: Int(dimensions.width), AVVideoHeightKey: Int(dimensions.height),
                        AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false,
                            AVVideoMaxKeyFrameIntervalDurationKey: 2]]
        } else {
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
                throw CaptureError.writerFailed("Missing audio format")
            }
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: asbd.mSampleRate,
                        AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame), AVEncoderBitRateKey: 192_000]
        }
        input = AVAssetWriterInput(mediaType: video ? .video : .audio, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.writerFailed("Unsupported \(key) format") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CaptureError.writerFailed("Cannot start \(key) writer") }
        writer.startSession(atSourceTime: sample.presentationTimeStamp)
    }

    @discardableResult func append(_ sample: CMSampleBuffer) throws -> Bool {
        if writer.status == .failed { throw writer.error ?? CaptureError.writerFailed("Media writer failed") }
        guard lastPTS == nil || sample.presentationTimeStamp > lastPTS! else { return false }
        guard input.isReadyForMoreMediaData else { return false }
        guard input.append(sample) else { throw writer.error ?? CaptureError.writerFailed("Cannot append media sample") }
        lastPTS = sample.presentationTimeStamp
        appended = true
        return true
    }

    func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        guard appended, writer.status == .completed else {
            throw writer.error ?? CaptureError.writerFailed("Media writer did not finish")
        }
    }
}
