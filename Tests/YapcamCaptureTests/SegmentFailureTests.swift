@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import YapcamCapture

private final class TestCaptureSink: CaptureTrackSink, @unchecked Sendable {
    let url: URL
    let firstNs: Int64
    private let lock = NSLock()
    private var times: [Int64] = []
    private let failAppend: Bool
    private let failFinish: Bool
    init(url: URL, firstNs: Int64, failAppend: Bool = false, failFinish: Bool = false) {
        self.url = url; self.firstNs = firstNs; self.failAppend = failAppend; self.failFinish = failFinish
    }
    func append(_ sample: CMSampleBuffer) throws -> Bool {
        if failAppend { throw CaptureError.writerFailed("Simulated device writer failure") }
        lock.withLock { times.append(CaptureClock.nanoseconds(sample.presentationTimeStamp)) }
        return true
    }
    func finish() async throws {
        if failFinish { throw CaptureError.writerFailed("Simulated writer finalization failure") }
    }
    var sampleTimes: [Int64] { lock.withLock { times } }
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
