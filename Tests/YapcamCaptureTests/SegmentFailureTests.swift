@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import YapcamCapture

private final class TestCaptureSink: CaptureTrackSink, @unchecked Sendable {
    let url: URL
    private let initialNs: Int64
    private let lock = NSLock()
    private var times: [Int64] = []
    private var pixelValues: [UInt] = []
    private var stopNs: Int64?
    private let failAppend: Bool
    private let failFinish: Bool
    private var rejectNext: Bool
    init(url: URL, firstNs: Int64, failAppend: Bool = false, failFinish: Bool = false, rejectFirst: Bool = false) {
        self.url = url; self.initialNs = firstNs; self.failAppend = failAppend; self.failFinish = failFinish
        self.rejectNext = rejectFirst
    }
    var firstNs: Int64 { lock.withLock { times.first ?? initialNs } }
    func append(_ sample: CMSampleBuffer) throws -> Bool {
        if failAppend { throw CaptureError.writerFailed("Simulated device writer failure") }
        return lock.withLock {
            if rejectNext { rejectNext = false; return false }
            times.append(CaptureClock.nanoseconds(sample.presentationTimeStamp))
            if let pixel = sample.imageBuffer { pixelValues.append(UInt(bitPattern: Unmanaged.passUnretained(pixel).toOpaque())) }
            return true
        }
    }
    func finish(atHostNs: Int64?) async throws {
        lock.withLock { stopNs = atHostNs }
        if failFinish { throw CaptureError.writerFailed("Simulated writer finalization failure") }
    }
    var sampleTimes: [Int64] { lock.withLock { times } }
    var pixelIDs: [UInt] { lock.withLock { pixelValues } }
    var finishedAt: Int64? { lock.withLock { stopNs } }
}

@Test func staticScreenAndCameraWritersReceiveFullSegmentEnd() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let observer = TestWriterObserver()
    let host: Int64 = 1_000_000_000
    let writer = SegmentWriter(directory: dir, hostStartNs: host, maxFPS: 60) { url, key, first in
        let sink = TestCaptureSink(url: url, firstNs: CaptureClock.nanoseconds(first.presentationTimeStamp))
        observer.sink(key, sink); return sink
    }
    try await enqueue(writer, key: "screen", ns: host)
    try await enqueue(writer, key: "camera", ns: host + 100_000_000)
    // No frames arrive during the remaining five seconds.
    writer.end(at: host + 5_100_000_000)
    let result = await writer.finish()
    #expect(result.error == nil)
    #expect(observer.sinks["screen"]?.finishedAt == host + 5_100_000_000)
    #expect(observer.sinks["camera"]?.finishedAt == host + 5_100_000_000)
}

@Test func firstScreenFrameDefinesOriginAndDropsDevicePreroll() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let observer = TestWriterObserver()
    let host: Int64 = 2_000_000_000
    let origin = host + 750_000_000
    let writer = SegmentWriter(directory: dir, hostStartNs: host, maxFPS: 60) { url, key, first in
        let sink = TestCaptureSink(url: url, firstNs: CaptureClock.nanoseconds(first.presentationTimeStamp))
        observer.sink(key, sink); return sink
    }
    try await enqueue(writer, key: "system_audio", ns: host + 100_000_000)
    try await enqueue(writer, key: "camera", ns: host + 200_000_000)
    try await enqueue(writer, key: "screen", ns: origin)
    try await enqueue(writer, key: "system_audio", ns: origin - 1) // queued preroll
    try await enqueue(writer, key: "system_audio", ns: origin + 10_000_000)
    try await enqueue(writer, key: "camera", ns: origin + 20_000_000)
    #expect(try await writer.firstScreenStart() == origin)
    writer.end(at: origin + 1_000_000_000)
    let result = await writer.finish()
    #expect(result.error == nil)
    #expect(result.hostStartNs == origin)
    #expect(result.starts == ["screen": 0, "system_audio": 10_000_000, "camera": 20_000_000])
    #expect(observer.sinks["system_audio"]?.sampleTimes == [origin + 10_000_000])
    #expect(observer.sinks["camera"]?.sampleTimes == [origin + 20_000_000])
    #expect(try JSONDecoder().decode(Int64.self, from: Data(contentsOf: dir.appendingPathComponent("host-start.json"))) == origin)
}

@Test func missingFirstScreenFrameHasBoundedAndCancellableWait() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let writer = SegmentWriter(directory: dir, hostStartNs: 0, maxFPS: 60)
    await #expect(throws: CaptureError.self) { try await writer.firstScreenStart(timeout: .milliseconds(1)) }
    let waiting = Task { try await writer.firstScreenStart() }
    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }
    #expect(await writer.finish().error != nil)
}

@Test func backpressureDoesNotAnchorSegmentToADroppedFirstFrame() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let writer = SegmentWriter(directory: dir, hostStartNs: 0, maxFPS: 60) { url, _, first in
        TestCaptureSink(url: url, firstNs: CaptureClock.nanoseconds(first.presentationTimeStamp), rejectFirst: true)
    }
    try await enqueue(writer, key: "screen", ns: 100_000_000)
    await #expect(throws: CaptureError.self) { try await writer.firstScreenStart(timeout: .milliseconds(1)) }
    try await enqueue(writer, key: "screen", ns: 200_000_000)
    #expect(try await writer.firstScreenStart() == 200_000_000)
    let result = await writer.finish()
    #expect(result.hostStartNs == 200_000_000)
    #expect(result.starts["screen"] == 0)
}

@Test func staticScreenCheckpointsKeepLastPixelsAndDoNotCreatePrerollOrPastStopFrames() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let observer = TestWriterObserver()
    let host: Int64 = 3_000_000_000
    let writer = SegmentWriter(directory: dir, hostStartNs: host, maxFPS: 60) { url, key, first in
        let sink = TestCaptureSink(url: url, firstNs: CaptureClock.nanoseconds(first.presentationTimeStamp))
        observer.sink(key, sink); return sink
    }
    await withCheckedContinuation { continuation in
        writer.queue.async { writer.appendStaticScreen(atHostNs: host); continuation.resume() }
    }
    #expect(observer.sinks.isEmpty)
    let samples = try InjectedCaptureSamples()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        writer.queue.async {
            do { writer.append(try samples.video(at: host), track: "screen"); continuation.resume() }
            catch { continuation.resume(throwing: error) }
        }
    }
    await withCheckedContinuation { continuation in
        writer.queue.async {
            writer.appendStaticScreen(atHostNs: host + 500_000_000) // too early
            writer.appendStaticScreen(atHostNs: host + 1_000_000_000)
            writer.appendStaticScreen(atHostNs: host + 2_000_000_000)
            continuation.resume()
        }
    }
    // Queue a callback before end's queue block, then request stop while it is
    // suspended. The callback's timestamp is outside the take even though it runs first.
    let release = DispatchSemaphore(value: 0)
    await withCheckedContinuation { continuation in
        writer.queue.async {
            continuation.resume(); release.wait()
            writer.appendStaticScreen(atHostNs: host + 3_000_000_000)
        }
    }
    defer { release.signal() }
    writer.end(at: host + 3_000_000_000)
    release.signal()
    let result = await writer.finish()
    #expect(result.error == nil && result.hostStartNs == host)
    #expect(observer.sinks["screen"]?.sampleTimes == [host, host + 1_000_000_000, host + 2_000_000_000])
    let pixels = try #require(observer.sinks["screen"]?.pixelIDs)
    #expect(pixels.count == 3 && Set(pixels).count == 1)
}

@Test func heartbeatNeverSuppressesALaterDeliveredRealFrameWithEarlierPTS() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let observer = TestWriterObserver()
    let host: Int64 = 4_000_000_000
    let writer = SegmentWriter(directory: dir, hostStartNs: host, maxFPS: 60) { url, key, first in
        let sink = TestCaptureSink(url: url, firstNs: CaptureClock.nanoseconds(first.presentationTimeStamp))
        observer.sink(key, sink); return sink
    }
    let original = try InjectedCaptureSamples()
    let changed = try InjectedCaptureSamples()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        writer.queue.async {
            do {
                writer.append(try original.video(at: host), track: "screen")
                writer.appendStaticScreen(atHostNs: host + 1_000_000_000)
                // This is a newer real source frame, but its PTS trails the
                // already-written host-now heartbeat by 100 ms.
                writer.append(try changed.video(at: host + 900_000_000), track: "screen")
                continuation.resume()
            } catch { continuation.resume(throwing: error) }
        }
    }
    writer.end(at: host + 2_000_000_000)
    let result = await writer.finish()
    #expect(result.error == nil)
    #expect(observer.sinks["screen"]?.sampleTimes == [host, host + 1_000_000_000, host + 1_000_000_001])
    let pixels = try #require(observer.sinks["screen"]?.pixelIDs)
    #expect(pixels.count == 3)
    #expect(pixels[0] == pixels[1])
    #expect(pixels[2] != pixels[1])
}

@Test(arguments: [30, 60, 120, 144]) func nominalDisplayCadenceToleratesFasterClockAndJitter(fps: Int) async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let observer = TestWriterObserver()
    let host: Int64 = 3_000_000_000
    let writer = SegmentWriter(directory: dir, hostStartNs: host, maxFPS: fps) { url, key, first in
        let sink = TestCaptureSink(url: url, firstNs: CaptureClock.nanoseconds(first.presentationTimeStamp))
        observer.sink(key, sink); return sink
    }
    let step = Int64(1_000_000_000 / Double(fps)) - 1_000
    for index in 0..<600 {
        let jitter: Int64 = index % 2 == 0 ? 0 : 1_000
        try await enqueue(writer, key: "screen", ns: host + Int64(index) * step + jitter)
    }
    let result = await writer.finish()
    #expect(result.error == nil)
    #expect(observer.sinks["screen"]?.sampleTimes.count == 600)
}

@Test func frameLimiterStillRejectsDoubleRateInput() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let observer = TestWriterObserver()
    let writer = SegmentWriter(directory: dir, hostStartNs: 0, maxFPS: 60) { url, key, first in
        let sink = TestCaptureSink(url: url, firstNs: CaptureClock.nanoseconds(first.presentationTimeStamp))
        observer.sink(key, sink); return sink
    }
    for index in 0..<120 { try await enqueue(writer, key: "screen", ns: Int64(index) * 8_333_333) }
    #expect(await writer.finish().error == nil)
    #expect(observer.sinks["screen"]?.sampleTimes.count == 60)
}

private final class TestWriterObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var sinkValues: [String: TestCaptureSink] = [:]
    private var warningValues: [String] = []
    private var failureValues: [CaptureError] = []
    private var meterValues: [Float] = []
    func sink(_ key: String, _ sink: TestCaptureSink) { lock.withLock { sinkValues[key] = sink } }
    func warn(_ text: String) { lock.withLock { warningValues.append(text) } }
    func fail(_ error: CaptureError) { lock.withLock { failureValues.append(error) } }
    func meter(_ level: Float) { lock.withLock { meterValues.append(level) } }
    var sinks: [String: TestCaptureSink] { lock.withLock { sinkValues } }
    var warnings: [String] { lock.withLock { warningValues } }
    var failures: [CaptureError] { lock.withLock { failureValues } }
    var meters: [Float] { lock.withLock { meterValues } }
}

private func sample(at ns: Int64) throws -> CMSampleBuffer {
    // The routing tests need valid CoreMedia timing, not an encoder or hardware.
    var format: CMAudioFormatDescription?
    var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
        mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
        layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr else {
        throw CaptureError.writerFailed("Cannot create test audio format")
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: CMTime(value: ns, timescale: 1_000_000_000), decodeTimeStamp: .invalid)
    var buffer: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil, formatDescription: format,
        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer) == noErr, let buffer else {
        throw CaptureError.writerFailed("Cannot create timed test sample")
    }
    return buffer
}

private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-routing-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func enqueue(_ writer: SegmentWriter, key: String, ns: Int64) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        writer.queue.async {
            do { writer.append(try sample(at: ns), track: key); continuation.resume() }
            catch { continuation.resume(throwing: error) }
        }
    }
}

@Test func disconnectedDevicesTruncateTheirTracksAndScreenContinues() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let observer = TestWriterObserver()
    let host: Int64 = 1_000_000_000
    let writer = SegmentWriter(directory: dir, hostStartNs: host, maxFPS: 30) { url, key, first in
        let sink = TestCaptureSink(url: url, firstNs: CaptureClock.nanoseconds(first.presentationTimeStamp))
        observer.sink(key, sink)
        return sink
    }
    writer.onWarning = { observer.warn($0) }; writer.onFailure = { observer.fail($0) }
    writer.onMicLevel = { observer.meter($0) }
    try await enqueue(writer, key: "screen", ns: host)
    try await enqueue(writer, key: "camera", ns: host + 10_000_000)
    try await enqueue(writer, key: "mic", ns: host + 20_000_000)
    writer.deviceUnavailable(.camera, reason: "Camera disconnected")
    writer.deviceUnavailable(.microphone, reason: "Microphone disconnected")
    writer.deviceUnavailable(.microphone, reason: "Repeated disconnect")
    try await enqueue(writer, key: "camera", ns: host + 100_000_000)
    try await enqueue(writer, key: "mic", ns: host + 100_000_000)
    try await enqueue(writer, key: "screen", ns: host + 100_000_000)
    let result = await writer.finish()
    #expect(result.error == nil)
    #expect(result.files.keys.sorted() == ["camera", "mic", "screen"])
    #expect(result.starts["mic"] == 20_000_000)
    #expect(observer.sinks["screen"]?.sampleTimes.count == 2)
    #expect(observer.sinks["camera"]?.sampleTimes.count == 1)
    #expect(observer.sinks["mic"]?.sampleTimes.count == 1)
    #expect(observer.warnings.count == 2)
    #expect(observer.failures.isEmpty)
    #expect(observer.meters.last == 0)
    let starts = try JSONDecoder().decode([String: Int64].self, from: Data(contentsOf: dir.appendingPathComponent("track-starts.json")))
    #expect(starts == ["screen": 0, "camera": 10_000_000, "mic": 20_000_000])
}

@Test func optionalWriterFailureDoesNotFailScreenCapture() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let observer = TestWriterObserver()
    let host: Int64 = 2_000_000_000
    let writer = SegmentWriter(directory: dir, hostStartNs: host, maxFPS: 60) { url, key, first in
        let sink = TestCaptureSink(url: url, firstNs: CaptureClock.nanoseconds(first.presentationTimeStamp), failAppend: key == "camera", failFinish: key == "camera")
        observer.sink(key, sink); return sink
    }
    writer.onWarning = { observer.warn($0) }; writer.onFailure = { observer.fail($0) }
    try await enqueue(writer, key: "screen", ns: host)
    try await enqueue(writer, key: "camera", ns: host)
    try await enqueue(writer, key: "camera", ns: host + 50_000_000)
    try await enqueue(writer, key: "screen", ns: host + 50_000_000)
    let result = await writer.finish()
    #expect(result.error == nil)
    #expect(result.files["screen"] == "screen.mov")
    #expect(result.files["camera"] == nil)
    #expect(observer.sinks["screen"]?.sampleTimes.count == 2)
    #expect(observer.failures.isEmpty)
    #expect(!observer.warnings.isEmpty)
}

@Test func screenWriterFailureReportsFatalError() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let observer = TestWriterObserver()
    let writer = SegmentWriter(directory: dir, hostStartNs: 0, maxFPS: 60) { url, _, first in
        TestCaptureSink(url: url, firstNs: CaptureClock.nanoseconds(first.presentationTimeStamp), failAppend: true, failFinish: true)
    }
    writer.onFailure = { observer.fail($0) }
    try await enqueue(writer, key: "screen", ns: 0)
    let result = await writer.finish()
    #expect(result.error != nil)
    #expect(observer.failures.count == 1)
}

@Test func stopBoundaryDropsLaterSamplesAndVFRNeverExceedsCap() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let observer = TestWriterObserver()
    let host: Int64 = 3_000_000_000
    let writer = SegmentWriter(directory: dir, hostStartNs: host, maxFPS: 30) { url, key, first in
        let sink = TestCaptureSink(url: url, firstNs: CaptureClock.nanoseconds(first.presentationTimeStamp))
        observer.sink(key, sink); return sink
    }
    try await enqueue(writer, key: "screen", ns: host - 1)
    try await enqueue(writer, key: "screen", ns: host)
    try await enqueue(writer, key: "screen", ns: host + 16_666_667)
    try await enqueue(writer, key: "screen", ns: host + 33_333_333)
    writer.end(at: host + 50_000_000)
    try await enqueue(writer, key: "screen", ns: host + 66_666_667)
    try await enqueue(writer, key: "mic", ns: host + 60_000_000)
    let result = await writer.finish()
    #expect(result.error == nil)
    #expect(observer.sinks["screen"]?.sampleTimes == [host, host + 33_333_333])
    #expect(observer.sinks["mic"] == nil)
}

@Test @MainActor func stationaryPointerIsReprojectedAfterWindowMoveAndResize() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = InputEventRecorder(directory: dir, rect: CGRect(x: 0, y: 0, width: 100, height: 100), hostStartNs: 100, keys: false)
    try recorder.openEventLog()
    recorder.recordPosition(CGPoint(x: 20, y: 30), hostNs: 100)
    recorder.recordPosition(CGPoint(x: 20, y: 30), hostNs: 110)
    recorder.updateContentRect(CGRect(x: 10, y: 0, width: 100, height: 100))
    recorder.recordPosition(CGPoint(x: 20, y: 30), hostNs: 120)
    recorder.updateContentRect(CGRect(x: 10, y: 0, width: 50, height: 50))
    recorder.recordPosition(CGPoint(x: 20, y: 30), hostNs: 130)
    try recorder.stop()
    let data = try Data(contentsOf: dir.appendingPathComponent("events.jsonl"))
    let events = try data.split(separator: 0x0a).map { try JSONDecoder().decode(CaptureEvent.self, from: Data($0)) }
    #expect(events.map(\.t) == [0, 20, 30])
    #expect(events.map(\.x) == [20, 10, 20])
    #expect(events.map(\.y) == [30, 30, 60])
}

@Test func deviceTimingConversionPreservesHostPTSAndAudioDuration() throws {
    let original = try sample(at: 1_234_567_890)
    let converted = try CaptureClock.hostSample(original, from: CMClockGetHostTimeClock())
    #expect(CaptureClock.nanoseconds(converted.presentationTimeStamp) == 1_234_567_890)
    var timing = CMSampleTimingInfo()
    #expect(CMSampleBufferGetSampleTimingInfo(converted, at: 0, timingInfoOut: &timing) == noErr)
    #expect(timing.duration == CMTime(value: 1, timescale: 48_000))
    #expect(!timing.decodeTimeStamp.isNumeric)
    #expect(CMSampleBufferGetNumSamples(converted) == CMSampleBufferGetNumSamples(original))
}

@Test @MainActor func resumedWindowKeepsInitialOutputCoordinatesAfterResize() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = InputEventRecorder(directory: dir, rect: CGRect(x: -800, y: 100, width: 400, height: 400),
        hostStartNs: 100, keys: false, outputSize: CGSize(width: 800, height: 600))
    try recorder.openEventLog()
    recorder.recordPosition(CGPoint(x: -800, y: 100), hostNs: 100)
    recorder.recordPosition(CGPoint(x: -400, y: 500), hostNs: 110)
    try recorder.stop()
    let events = try Data(contentsOf: dir.appendingPathComponent("events.jsonl")).split(separator: 0x0a)
        .map { try JSONDecoder().decode(CaptureEvent.self, from: Data($0)) }
    #expect(events.map(\.x) == [100, 700])
    #expect(events.map(\.y) == [0, 600])
}

@Test @MainActor func cancelledCleanupStillWaitsForInFlightOperation() async {
    let gate = CaptureOperationGate()
    gate.setBusy(true)
    var cleanedUp = false
    let cleanup = Task { @MainActor in
        await gate.waitUntilAvailable()
        cleanedUp = true
    }
    cleanup.cancel()
    await Task.yield()
    #expect(!cleanedUp)
    gate.setBusy(false)
    await cleanup.value
    #expect(cleanedUp)
}

@Test(arguments: [32, 128])
func negotiatedCameraSizeChangeDisablesImmediatelyAndKeepsOtherTracks(width: Int) async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let observer = TestWriterObserver(), good = try InjectedCaptureSamples()
    let changed = try InjectedCaptureSamples(width: width, height: 64)
    let host: Int64 = 4_000_000_000
    let writer = SegmentWriter(directory: dir, hostStartNs: host, maxFPS: 60) { url, key, first in
        let sink = TestCaptureSink(url: url, firstNs: CaptureClock.nanoseconds(first.presentationTimeStamp))
        observer.sink(key, sink); return sink
    }
    writer.onWarning = { observer.warn($0) }; writer.onFailure = { observer.fail($0) }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        writer.queue.async {
            do {
                let clock = CMClockGetHostTimeClock()
                writer.append(try good.video(at: host), track: "screen")
                AuxiliarySamples.append(try good.video(at: host + 10_000_000), track: .camera,
                    clock: clock, cameraPixels: [64, 64], writer: writer)
                AuxiliarySamples.append(try changed.video(at: host + 20_000_000), track: .camera,
                    clock: clock, cameraPixels: [64, 64], writer: writer)
                // These callbacks are already queued when the format failure occurs.
                // Even an immediately restored size must not restart this track.
                AuxiliarySamples.append(try good.video(at: host + 30_000_000), track: .camera,
                    clock: clock, cameraPixels: [64, 64], writer: writer)
                AuxiliarySamples.append(try changed.video(at: host + 40_000_000), track: .camera,
                    clock: clock, cameraPixels: [64, 64], writer: writer)
                AuxiliarySamples.append(try good.audio(at: host + 40_000_000), track: .microphone,
                    clock: clock, cameraPixels: nil, writer: writer)
                writer.append(try good.video(at: host + 50_000_000), track: "screen")
                continuation.resume()
            } catch { continuation.resume(throwing: error) }
        }
    }
    let result = await writer.finish()
    #expect(result.error == nil && observer.failures.isEmpty)
    #expect(observer.sinks["camera"]?.sampleTimes == [host + 10_000_000])
    #expect(observer.sinks["mic"]?.sampleTimes == [host + 40_000_000])
    #expect(observer.sinks["screen"]?.sampleTimes == [host, host + 50_000_000])
    #expect(result.starts == ["screen": 0, "camera": 10_000_000, "mic": 40_000_000])
    #expect(result.files.keys.sorted() == ["camera", "mic", "screen"])
    #expect(observer.warnings.count == 1)
}

private enum AuxiliaryFailureCase: Sendable, CaseIterable { case wrongMedia, clockMissing, timestampInvalid }

@Test(arguments: AuxiliaryFailureCase.allCases)
private func cameraFormatAndClockFailuresDoNotCreateTrackOrStopScreen(failure: AuxiliaryFailureCase) async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let observer = TestWriterObserver(), samples = try InjectedCaptureSamples()
    let host: Int64 = 5_000_000_000
    let writer = SegmentWriter(directory: dir, hostStartNs: host, maxFPS: 60) { url, key, first in
        let sink = TestCaptureSink(url: url, firstNs: CaptureClock.nanoseconds(first.presentationTimeStamp))
        observer.sink(key, sink); return sink
    }
    writer.onWarning = { observer.warn($0) }; writer.onFailure = { observer.fail($0) }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        writer.queue.async {
            do {
                let clock = CMClockGetHostTimeClock()
                writer.append(try samples.video(at: host), track: "screen")
                var invalid = try failure == .wrongMedia ? samples.audio(at: host + 10_000_000) : samples.video(at: host + 10_000_000)
                if failure == .timestampInvalid {
                    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                        presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
                    var copy: CMSampleBuffer?
                    let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                        sampleBuffer: invalid, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
                    guard status == noErr, let copy else { throw CaptureError.writerFailed("Cannot inject invalid camera PTS") }
                    invalid = copy
                }
                AuxiliarySamples.append(invalid, track: .camera, clock: failure == .clockMissing ? nil : clock,
                    cameraPixels: [64, 64], writer: writer)
                AuxiliarySamples.append(try samples.video(at: host + 20_000_000), track: .camera,
                    clock: clock, cameraPixels: [64, 64], writer: writer)
                AuxiliarySamples.append(try samples.audio(at: host + 30_000_000), track: .microphone,
                    clock: clock, cameraPixels: nil, writer: writer)
                writer.append(try samples.video(at: host + 50_000_000), track: "screen")
                continuation.resume()
            } catch { continuation.resume(throwing: error) }
        }
    }
    let result = await writer.finish()
    #expect(result.error == nil && observer.failures.isEmpty)
    #expect(result.files.keys.sorted() == ["mic", "screen"])
    #expect(result.starts == ["screen": 0, "mic": 30_000_000])
    #expect(observer.sinks["screen"]?.sampleTimes == [host, host + 50_000_000])
    #expect(observer.sinks["mic"]?.sampleTimes == [host + 30_000_000])
    #expect(observer.sinks["camera"] == nil && observer.warnings.count == 1)
}
