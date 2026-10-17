@preconcurrency import AVFoundation
import ScreenCaptureKit
import VideoToolbox

enum AuxiliaryTrack: String, Sendable { case camera, microphone = "mic" }

protocol CaptureTrackSink: AnyObject, Sendable {
    var url: URL { get }
    var firstNs: Int64 { get }
    func append(_ sample: CMSampleBuffer) throws -> Bool
    func finish(atHostNs: Int64?) async throws
}

/// All mutable writer state is confined to queue, including AV capture callbacks.
final class SegmentWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias TrackFactory = @Sendable (URL, String, CMSampleBuffer) throws -> any CaptureTrackSink
    let queue = DispatchQueue(label: "mov.yapcam.capture.samples", qos: .userInitiated)
    let directory: URL
    /// Startup lower bound only; Result.hostStartNs is the actual screen origin.
    let hostStartNs: Int64
    let maxFPS: Int
    private let makeTrack: TrackFactory
    private var tracks: [String: any CaptureTrackSink] = [:]
    private var failure: CaptureError?
    private var accepting = true
    private var unavailableTracks: Set<String> = []
    /// Timestamp of the last screen sample accepted by the sink, real or heartbeat.
    private var lastScreenNs: Int64?
    /// Original source timestamp of the last accepted real ScreenCaptureKit frame.
    private var lastRealScreenNs: Int64?
    private var lastScreenSample: CMSampleBuffer?
    private var heartbeat: DispatchSourceTimer?
    private var nextRealScreenNs: Int64?
    private var screenStartNs: Int64?
    private var startedTracks: Set<String> = []
    private var endHostNs: Int64?
    private let stopLock = NSLock()
    private var requestedEndNs: Int64?
    private var audioFormats: [String: AudioMetadata] = [:]
    var onWarning: (@Sendable (String) -> Void)?
    var onFailure: (@Sendable (CaptureError) -> Void)?
    var onGeometry: (@Sendable (CGRect, CGRect, CGFloat) -> Void)?
    var onTrackStarted: (@Sendable (String, Int64) -> Void)?
    var onMicLevel: (@Sendable (Float) -> Void)?
    var onAudioFormat: (@Sendable (String, AudioMetadata) -> Void)?

    init(directory: URL, hostStartNs: Int64, maxFPS: Int,
         keepsStaticScreenAlive: Bool = false,
         makeTrack: TrackFactory? = nil) {
        self.directory = directory; self.hostStartNs = hostStartNs; self.maxFPS = maxFPS
        self.makeTrack = makeTrack ?? { try MediaTrackWriter(url: $0, key: $1, first: $2, maxFPS: maxFPS) }
        super.init()
        if keepsStaticScreenAlive {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.appendStaticScreen(atHostNs: CaptureClock.now) }
            heartbeat = timer
            timer.resume()
        }
    }

    deinit { heartbeat?.cancel() }

    /// A static ScreenCaptureKit source can stop delivering complete images.
    /// Retiming the last image once a second lets the encoder close its 2s
    /// fragments even then. No extra screen grab, cursor, or new device access.
    func appendStaticScreen(atHostNs host: Int64) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard accepting, failure == nil, let lastScreenNs, host - lastScreenNs >= 1_000_000_000,
              let sample = lastScreenSample else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(maxFPS)),
            presentationTimeStamp: CMTime(value: host, timescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
        guard status == noErr, let copy else {
            failure = .writerFailed("Cannot checkpoint the static screen (\(status))")
            if let failure { onFailure?(failure) }
            return
        }
        append(copy, track: "screen", isHeartbeat: true)
    }

    func end(at hostNs: Int64) {
        // Publish before queued callbacks can run. A heartbeat already ahead of
        // the end block must not append a frame stamped after the user's stop.
        stopLock.withLock { requestedEndNs = hostNs }
        queue.async { self.endHostNs = hostNs }
    }

    /// SCStream start can finish before its first frame arrives. Bound this wait,
    /// propagate writer errors, and let cancellation clean up a stalled startup.
    func firstScreenStart(timeout: Duration = .seconds(10)) async throws -> Int64 {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let result: Swift.Result<Int64, CaptureError>? = await withCheckedContinuation { continuation in
                queue.async {
                    if let failure = self.failure { continuation.resume(returning: .failure(failure)) }
                    else if let start = self.screenStartNs { continuation.resume(returning: .success(start)) }
                    else { continuation.resume(returning: nil) }
                }
            }
            if let result { return try result.get() }
            guard ContinuousClock.now < deadline else { throw CaptureError.writerFailed("Timed out waiting for the first screen frame") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Called from device notifications, which may arrive on arbitrary queues.
    /// Keep the prior samples; ignore all future samples from the lost device.
    func deviceUnavailable(_ track: AuxiliaryTrack, reason: String) {
        queue.async { self.disable(track, reason: reason) }
    }

    /// Sample validation must disable synchronously before the next queued frame.
    /// Notifications from other queues enter through deviceUnavailable instead.
    func disable(_ track: AuxiliaryTrack, reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
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
        fail(CaptureError.from(error))
    }

    func fail(_ error: CaptureError) {
        queue.async {
            guard self.accepting, self.failure == nil else { return }
            self.failure = self.failure ?? error
            self.onFailure?(error)
        }
    }

    /// Caller must deliver samples on queue. AVCapture sample clocks are converted before this call.
    func append(_ sample: CMSampleBuffer, track key: String) {
        append(sample, track: key, isHeartbeat: false)
    }

    private func append(_ sample: CMSampleBuffer, track key: String, isHeartbeat: Bool) {
        guard accepting, failure == nil, !unavailableTracks.contains(key) else { return }
        let pts = sample.presentationTimeStamp
        let sourceNs = CaptureClock.nanoseconds(pts)
        let end = stopLock.withLock { requestedEndNs }
        guard pts.isNumeric, sourceNs >= hostStartNs else { return }
        if let end, sourceNs >= end { return }
        // Drop audio/device preroll instead of giving the source timeline a blank
        // screen lead-in. Every retained track starts at/after the first screen PTS.
        if key != "screen" {
            guard let screenStartNs, sourceNs >= screenStartNs else { return }
        }
        let interval = 1_000_000_000 / Int64(maxFPS)
        if key == "screen" {
            if isHeartbeat {
                if let lastScreenNs, sourceNs <= lastScreenNs { return }
            } else {
                // A synthetic heartbeat may be stamped slightly ahead of a real
                // frame delivered later. Real ordering/cadence must use only real
                // source timestamps so that heartbeat can never hide new pixels.
                if let lastRealScreenNs, sourceNs <= lastRealScreenNs { return }
                // Compare against a cadence deadline with half-frame tolerance. Using
                // the prior PTS alone drops alternate frames on slightly fast 60 Hz panels.
                if let nextRealScreenNs, sourceNs <= nextRealScreenNs - interval / 2 { return }
            }
        }
        do {
            var writtenSample = sample
            var writtenNs = sourceNs
            if key == "screen", !isHeartbeat, let lastScreenNs, sourceNs <= lastScreenNs {
                // AVAssetWriter still requires strictly increasing output PTS. Keep
                // the real image and move only its output timestamp past the heartbeat.
                writtenNs = lastScreenNs + 1
                writtenSample = try Self.retimed(sample, atHostNs: writtenNs)
            }
            let track: any CaptureTrackSink
            if let existing = tracks[key] { track = existing }
            else {
                let filename = key == "system_audio" ? "system.m4a" : key == "mic" ? "mic.m4a" : "\(key).mov"
                track = try makeTrack(directory.appendingPathComponent(filename), key, writtenSample)
                tracks[key] = track
            }
            guard try track.append(writtenSample) else { return }
            if key == "screen" {
                if screenStartNs == nil {
                    // Durable origin closes the crash window before session.json
                    // catches up on the main actor. No new required manifest keys.
                    try PackageIO.write(track.firstNs, to: directory.appendingPathComponent("host-start.json"))
                    screenStartNs = track.firstNs
                }
                lastScreenNs = writtenNs
                if !isHeartbeat {
                    lastRealScreenNs = sourceNs
                    lastScreenSample = writtenSample
                    nextRealScreenNs = max((nextRealScreenNs ?? sourceNs) + interval, sourceNs + interval)
                }
            }
            if startedTracks.insert(key).inserted, let origin = screenStartNs {
                if key == "system_audio" || key == "mic", let format = sample.formatDescription,
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                   asbd.mSampleRate.isFinite, asbd.mSampleRate > 0, asbd.mSampleRate <= 768_000,
                   asbd.mChannelsPerFrame > 0 {
                    let audio = AudioMetadata(sampleRate: Int(asbd.mSampleRate.rounded()), channels: Int(asbd.mChannelsPerFrame))
                    audioFormats[key] = audio
                    onAudioFormat?(key, audio)
                }
                let starts = tracks.filter { startedTracks.contains($0.key) }.mapValues { $0.firstNs - origin }
                try PackageIO.write(starts, to: directory.appendingPathComponent("track-starts.json"))
                onTrackStarted?(key, track.firstNs - origin)
            }
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

    private static func retimed(_ sample: CMSampleBuffer, atHostNs hostNs: Int64) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: sample.duration,
            presentationTimeStamp: CMTime(value: hostNs, timescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
        guard status == noErr, let copy else {
            throw CaptureError.writerFailed("Cannot preserve a real screen frame after a static-screen checkpoint (\(status))")
        }
        return copy
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
        var hostStartNs: Int64?
        var error: CaptureError?
        var audioFormats: [String: AudioMetadata] = [:]
    }

    func finish() async -> Result {
        await withCheckedContinuation { continuation in
            queue.async {
                self.accepting = false
                self.heartbeat?.cancel(); self.heartbeat = nil
                self.lastScreenSample = nil
                let tracks = self.tracks
                let initialFailure = self.failure
                let origin = self.screenStartNs
                let end = self.endHostNs ?? CaptureClock.now
                let unavailable = self.unavailableTracks
                let audioFormats = self.audioFormats
                Task {
                    var files: [String: String] = [:]
                    var starts: [String: Int64] = [:]
                    var error = initialFailure
                    for (key, track) in tracks {
                        do {
                            try await track.finish(atHostNs: unavailable.contains(key) ? nil : end)
                            files[key] = track.url.lastPathComponent
                            if let origin { starts[key] = track.firstNs - origin }
                        } catch let caught {
                            if key == "screen" || key == "system_audio" { error = .writerFailed(caught.localizedDescription) }
                            else { self.onWarning?("\(key) track could not be finalized: \(caught.localizedDescription)") }
                        }
                    }
                    if files["screen"] == nil, error == nil { error = .writerFailed("No screen frames were captured") }
                    continuation.resume(returning: Result(files: files, starts: starts, hostStartNs: origin, error: error, audioFormats: audioFormats))
                }
            }
        }
    }
}

/// Shared production fragmentation policy; tests can drive its clock without an encoder.
enum CaptureMediaPolicy {
    static let fragmentDurationNs: Int64 = 2_000_000_000
    static var fragmentInterval: CMTime { CMTime(value: fragmentDurationNs, timescale: 1_000_000_000) }
    static var keyFrameIntervalSeconds: Double { Double(fragmentDurationNs) / 1_000_000_000 }

    static func videoSettings(width: Int, height: Int, key: String, maxFPS: Int) -> [String: Any] {
        let fps = key == "camera" ? (maxFPS >= 60 ? 60 : 30) : maxFPS
        // The AVFoundation and VideoToolbox quality constants alias the same key.
        // Request the reference values explicitly; the native encoder must accept
        // these settings (unit dictionaries alone cannot establish codec support).
        return [AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    kVTCompressionPropertyKey_Quality as String: key == "camera" ? 0.6 : 0.85,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoMaxKeyFrameIntervalKey: fps * 2,
                    AVVideoMaxKeyFrameIntervalDurationKey: keyFrameIntervalSeconds]]
    }
}

final class MediaTrackWriter: CaptureTrackSink, @unchecked Sendable {
    let url: URL
    private(set) var firstNs: Int64
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var lastPTS: CMTime?
    private var appended = false
    private let diskCheckpoint: CaptureDiskCheckpoint

    init(url: URL, key: String, first sample: CMSampleBuffer, maxFPS: Int = 60) throws {
        self.url = url
        firstNs = CaptureClock.nanoseconds(sample.presentationTimeStamp)
        diskCheckpoint = CaptureDiskCheckpoint(url: url, originNs: firstNs)
        let video = key == "screen" || key == "camera"
        writer = try AVAssetWriter(outputURL: url, fileType: video ? .mov : .m4a)
        writer.movieFragmentInterval = CaptureMediaPolicy.fragmentInterval
        guard let format = sample.formatDescription else { throw CaptureError.writerFailed("Missing sample format") }
        var settings: [String: Any]
        if video {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            settings = CaptureMediaPolicy.videoSettings(width: Int(dimensions.width), height: Int(dimensions.height), key: key, maxFPS: maxFPS)
        } else {
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
                throw CaptureError.writerFailed("Missing audio format")
            }
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: asbd.mSampleRate,
                        AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame), AVEncoderBitRateKey: 192_000]
        }
        guard writer.canApply(outputSettings: settings, forMediaType: video ? .video : .audio) else {
            throw CaptureError.writerFailed("The native encoder does not support the requested \(key) settings")
        }
        input = AVAssetWriterInput(mediaType: video ? .video : .audio, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.writerFailed("Unsupported \(key) format") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CaptureError.writerFailed("Cannot start \(key) writer") }
    }

    @discardableResult func append(_ sample: CMSampleBuffer) throws -> Bool {
        if writer.status == .failed { throw writer.error ?? CaptureError.writerFailed("Media writer failed") }
        if let lastPTS, sample.presentationTimeStamp <= lastPTS { return false }
        guard input.isReadyForMoreMediaData else { return false }
        if !appended {
            firstNs = CaptureClock.nanoseconds(sample.presentationTimeStamp)
            writer.startSession(atSourceTime: sample.presentationTimeStamp)
        }
        guard input.append(sample) else { throw writer.error ?? CaptureError.writerFailed("Cannot append media sample") }
        lastPTS = sample.presentationTimeStamp
        appended = true
        let ns = CaptureClock.nanoseconds(sample.presentationTimeStamp)
        // AVAssetWriter closes fragments; commit already-written bytes off the
        // sample queue. The in-flight fragment is still an acknowledged loss limit.
        try diskCheckpoint.request(atHostNs: ns)
        return true
    }

    func finish(atHostNs end: Int64?) async throws {
        guard appended else {
            if writer.status == .writing { writer.cancelWriting() }
            throw writer.error ?? CaptureError.writerFailed("No media samples were written")
        }
        if writer.status == .writing, let end {
            writer.endSession(atSourceTime: CMTime(value: max(firstNs + 1, end), timescale: 1_000_000_000))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CaptureError.writerFailed("Media writer did not finish")
        }
        try diskCheckpoint.finish()
    }
}
