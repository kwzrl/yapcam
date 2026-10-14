@preconcurrency import AVFoundation
import Foundation
import ScreenCaptureKit
import Testing
@testable import YapcamCapture

private final class FinishCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class TrackSampleCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func append(_ key: String) { lock.withLock { values[key, default: 0] += 1 } }
    var counts: [String: Int] { lock.withLock { values } }
}

private final class LifecycleSink: CaptureTrackSink, @unchecked Sendable {
    let url: URL
    let firstNs: Int64
    private let finishes: FinishCounter
    private let failFinish: Bool
    private let onAppend: @Sendable () -> Void
    init(url: URL, firstNs: Int64, finishes: FinishCounter, failFinish: Bool, onAppend: @escaping @Sendable () -> Void) {
        self.url = url; self.firstNs = firstNs; self.finishes = finishes; self.failFinish = failFinish
        self.onAppend = onAppend
    }
    func append(_ sample: CMSampleBuffer) throws -> Bool { onAppend(); return true }
    func finish(atHostNs: Int64?) async throws {
        finishes.increment()
        if failFinish { throw CaptureError.writerFailed("Controlled finalization failure") }
    }
}

@MainActor private final class StartupBarrier {
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
    var isWaiting: Bool { waiter != nil }
}

@MainActor private final class LifecycleStream: CaptureSessionStream {
    let writer: SegmentWriter
    let pixels: [Int]
    var stopCount = 0
    let barrier: StartupBarrier?
    let delayFirstFrame: Bool
    let includeAuxiliary: Bool
    private(set) var firstFrameNs: Int64?
    init(writer: SegmentWriter, pixels: [Int], barrier: StartupBarrier?, delayFirstFrame: Bool, includeAuxiliary: Bool) {
        self.writer = writer; self.pixels = pixels; self.barrier = barrier; self.delayFirstFrame = delayFirstFrame
        self.includeAuxiliary = includeAuxiliary
    }
    func startCapture() async throws {
        if let barrier { await barrier.wait() }
        if delayFirstFrame { try await Task.sleep(for: .milliseconds(40)) }
        let first = delayFirstFrame ? CaptureClock.now : writer.hostStartNs
        firstFrameNs = first
        try await emitSamples(at: first, includeAuxiliary: includeAuxiliary)
    }
    func emitSamples(at time: Int64, includeAuxiliary: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let writer = writer
            writer.queue.async {
                do {
                    let sample = try lifecycleSample(at: time)
                    writer.append(sample, track: "screen")
                    if includeAuxiliary {
                        writer.append(sample, track: "mic")
                        writer.append(sample, track: "camera")
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func stopCapture() async throws { stopCount += 1 }
    func updateContentFilter(_ filter: SCContentFilter) async throws {
        throw CaptureError.writerFailed("Unexpected framework filter in a controlled lifecycle test")
    }
    func disappear() { writer.onFailure?(.sourceUnavailable) }
}

private func lifecycleSample(at ns: Int64) throws -> CMSampleBuffer {
    var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
        mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
        layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr else {
        throw CaptureError.writerFailed("Cannot create test format")
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: CMTime(value: ns, timescale: 1_000_000_000), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil, formatDescription: format,
        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
        sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample else {
        throw CaptureError.writerFailed("Cannot create test sample")
    }
    return sample
}

@MainActor private final class LifecycleHarness {
    let directory: URL
    var permission: PermissionState = .granted
    var freeBytes: Int64 = 2_000_000_000
    var rect = CGRect(x: 0, y: 0, width: 64, height: 64)
    var scale: CGFloat = 1
    var prepareError: CaptureError?
    var failFinish = false
    var barrier: StartupBarrier?
    var delayFirstFrame = false
    var includeAuxiliary = false
    var eventHook: ((InputEventRecorder) throws -> Void)?
    var streams: [LifecycleStream] = []
    let finishes = FinishCounter()
    let samples = TrackSampleCounts()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-session-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func session(target: CaptureTarget = .display(2)) -> RecordingSession {
        let finishes = finishes
        let samples = samples
        let services = CaptureSessionServices(permissionState: { [unowned self] _ in self.permission },
            availableBytes: { [unowned self] _ in self.freeBytes },
            prepare: { [unowned self] options in
                if let error = self.prepareError { throw error }
                let geometry = try CaptureGeometry(rect: self.rect, scale: self.scale)
                let source = SourceMetadata(kind: "display", displayID: 2,
                    contentRectPoints: [self.rect.minX, self.rect.minY, self.rect.width, self.rect.height], scale: self.scale)
                return CaptureSessionPlan(source: source, geometry: geometry) { [unowned self] writer, pixels in
                    let stream = LifecycleStream(writer: writer, pixels: pixels, barrier: self.barrier,
                        delayFirstFrame: self.delayFirstFrame, includeAuxiliary: self.includeAuxiliary)
                    self.streams.append(stream)
                    return stream
                }
            }, makeWriter: { [unowned self] directory, host, fps in
                let failFinish = self.failFinish
                return SegmentWriter(directory: directory, hostStartNs: host, maxFPS: fps) { url, key, sample in
                    LifecycleSink(url: url, firstNs: CaptureClock.nanoseconds(sample.presentationTimeStamp),
                                  finishes: finishes, failFinish: failFinish, onAppend: { samples.append(key) })
                }
            }, startEvents: { [unowned self] in
                try $0.openEventLog()
                try self.eventHook?($0)
            }, automaticHealthChecks: false)
        return RecordingSession(options: RecordingOptions(target: target, systemAudio: false, outputDirectory: directory), services: services)
    }
}

@MainActor private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CaptureError.writerFailed("Controlled lifecycle transition timed out")
}

private func readSession(_ package: URL) throws -> SessionManifest {
    try PackageIO.readManifest(at: package.appendingPathComponent("recording/session.json"))
}

@Test @MainActor func lifecyclePauseResumeFinalizesSegmentsAndRemovesPause() async throws {
    let harness = try LifecycleHarness(); defer { harness.cleanup() }
    let session = harness.session()
    try await session.start()
    let package = try #require(session.packageURL)
    #expect(session.state == .recording)
    #expect(try readSession(package).status == "recording")
    try await session.pause()
    #expect(session.state == .paused)
    #expect(!RecordingPackageLease.isAvailable(package))
    try await Task.sleep(for: .milliseconds(20))
    try await session.resume()
    #expect(try await session.stop() == package)
    #expect(try await session.stop() == package)
    let value = try readSession(package)
    #expect(value.status == "complete")
    #expect(value.segments.count == 2)
    #expect(value.segments[1].srcStartNs == value.segments[0].durationNs)
    #expect(value.segments[1].hostStartNs - value.segments[0].hostStartNs - value.segments[0].durationNs >= 20_000_000)
    #expect(value.segments.map(\.trackStartNs) == [["screen": 0], ["screen": 0]])
    #expect(value.segments.map(\.dir) == ["seg-000", "seg-001"])
    #expect(harness.finishes.count == 2)
    #expect(harness.streams.map(\.stopCount) == [1, 1])
    #expect(RecordingPackageLease.isAvailable(package))
}

@Test @MainActor func lifecycleLowDiskFinalizesAndPreservesInterruptedPackage() async throws {
    let harness = try LifecycleHarness(); defer { harness.cleanup() }
    let session = harness.session()
    try await session.start()
    let package = try #require(session.packageURL)
    harness.freeBytes = 999_999_999
    await session.checkHealth()
    #expect(session.state == .failed(.diskFull(availableBytes: 999_999_999)))
    let value = try readSession(package)
    #expect(value.status == "interrupted")
    #expect(value.segments[0].durationNs > 0)
    #expect(value.segments[0].files["screen"] == "seg-000/screen.mov")
    #expect(harness.finishes.count == 1)
    #expect(harness.streams[0].stopCount == 1)
    #expect(RecordingPackageLease.isAvailable(package))
    #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("recording/seg-000/events.jsonl").path))
}

@Test @MainActor func lifecycleRevokedPermissionStopsAndFinalizes() async throws {
    let harness = try LifecycleHarness(); defer { harness.cleanup() }
    let session = harness.session()
    try await session.start()
    let package = try #require(session.packageURL)
    harness.permission = .denied
    await session.checkHealth()
    #expect(session.state == .failed(.permissionDenied(.screen)))
    #expect(try readSession(package).status == "interrupted")
    #expect(harness.finishes.count == 1)
    #expect(RecordingPackageLease.isAvailable(package))
}

@Test @MainActor func lifecycleDisappearingSourceStopsAndFinalizes() async throws {
    let harness = try LifecycleHarness(); defer { harness.cleanup() }
    let session = harness.session()
    try await session.start()
    let package = try #require(session.packageURL)
    harness.streams[0].disappear()
    try await eventually { session.state == .failed(.sourceUnavailable) }
    #expect(try readSession(package).status == "interrupted")
    #expect(harness.finishes.count == 1)
    #expect(harness.streams[0].stopCount == 1)
    #expect(RecordingPackageLease.isAvailable(package))
}

@Test @MainActor func lifecycleLateCallbacksCannotAffectResumedSegment() async throws {
    let harness = try LifecycleHarness(); defer { harness.cleanup() }
    let session = harness.session()
    try await session.start()
    let oldWriter = harness.streams[0].writer
    try await session.pause()
    try await session.resume()
    oldWriter.onFailure?(.sourceUnavailable)
    oldWriter.onWarning?("stale warning")
    oldWriter.onMicLevel?(1)
    for _ in 0..<10 { await Task.yield() }
    #expect(session.state == .recording)
    #expect(!session.warnings.contains("stale warning"))
    #expect(session.micLevel == 0)
    let package = try #require(session.packageURL)
    await session.cancel()
    #expect(session.state == .cancelled)
    #expect(!FileManager.default.fileExists(atPath: package.path))
}

@Test @MainActor func lifecycleCancelledCallerStillDeletesPackageAfterStartup() async throws {
    let harness = try LifecycleHarness(); defer { harness.cleanup() }
    let barrier = StartupBarrier(); harness.barrier = barrier
    let session = harness.session()
    let start = Task { @MainActor in try await session.start() }
    try await eventually { barrier.isWaiting }
    let package = try #require(session.packageURL)
    let cancel = Task { @MainActor in await session.cancel() }
    cancel.cancel()
    barrier.release()
    try await start.value
    await cancel.value
    #expect(session.state == .cancelled)
    #expect(session.packageURL == nil)
    #expect(!FileManager.default.fileExists(atPath: package.path))
    #expect(harness.finishes.count == 1)
}

@Test @MainActor func lifecycleWriterFinalizationFailureDoesNotPublishComplete() async throws {
    let harness = try LifecycleHarness(); defer { harness.cleanup() }
    harness.failFinish = true
    let session = harness.session()
    try await session.start()
    let package = try #require(session.packageURL)
    await #expect(throws: CaptureError.self) { try await session.stop() }
    if case .failed = session.state {} else { Issue.record("Expected failed recording state") }
    #expect(try readSession(package).status == "interrupted")
    #expect(harness.finishes.count == 1)
    #expect(harness.streams[0].stopCount == 1)
    #expect(RecordingPackageLease.isAvailable(package))
}

@Test @MainActor func lifecycleWindowResumeKeepsInitialPixelsAfterRetinaResize() async throws {
    let harness = try LifecycleHarness(); defer { harness.cleanup() }
    let session = harness.session(target: .window(99))
    try await session.start()
    try await session.pause()
    harness.rect = CGRect(x: -1000, y: 100, width: 128, height: 80); harness.scale = 2
    try await session.resume()
    let package = try await session.stop()
    #expect(harness.streams.map(\.pixels) == [[64, 64], [64, 64]])
    #expect(try readSession(package).tracks.screen.pixelSize == [64, 64])
    #expect(try readSession(package).source.scale == 1)
}

@Test @MainActor func lifecycleDisplayResizeWhilePausedPreservesEarlierSegment() async throws {
    let harness = try LifecycleHarness(); defer { harness.cleanup() }
    let session = harness.session()
    try await session.start()
    try await session.pause()
    let package = try #require(session.packageURL)
    harness.rect.size = CGSize(width: 128, height: 80)
    await #expect(throws: CaptureError.self) { try await session.resume() }
    #expect(try readSession(package).status == "interrupted")
    #expect(try readSession(package).segments.count == 1)
    #expect(harness.finishes.count == 1)
    #expect(RecordingPackageLease.isAvailable(package))
}

@Test @MainActor func lifecycleUnavailableSourceDoesNotCreateRecordingPackage() async throws {
    let harness = try LifecycleHarness(); defer { harness.cleanup() }
    harness.prepareError = .sourceUnavailable
    let session = harness.session()
    await #expect(throws: CaptureError.sourceUnavailable) { try await session.start() }
    #expect(session.state == .failed(.sourceUnavailable))
    #expect(session.packageURL == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: harness.directory.path).isEmpty)
}

@Test @MainActor func lifecycleDeviceLossWarnsOnceResetsMeterAndKeepsScreenRecording() async throws {
    let harness = try LifecycleHarness(); defer { harness.cleanup() }
    harness.includeAuxiliary = true
    let session = harness.session()
    try await session.start()
    let stream = harness.streams[0]
    stream.writer.onMicLevel?(0.75)
    try await eventually { session.micLevel == 0.75 }
    stream.writer.deviceUnavailable(.microphone, reason: "Injected microphone loss")
    stream.writer.deviceUnavailable(.microphone, reason: "Duplicate microphone loss")
    stream.writer.deviceUnavailable(.camera, reason: "Injected camera loss")
    try await eventually { session.warnings.count == 2 && session.micLevel == 0 }
    #expect(session.state == .recording)
    try await Task.sleep(for: .milliseconds(20))
    try await stream.emitSamples(at: CaptureClock.now, includeAuxiliary: true)
    #expect(harness.samples.counts == ["screen": 2, "mic": 1, "camera": 1])
    let package = try await session.stop()
    let value = try readSession(package)
    #expect(value.status == "complete")
    #expect(value.segments[0].files["screen"] == "seg-000/screen.mov")
    #expect(value.segments[0].files["mic"] == "seg-000/mic.m4a")
    #expect(value.segments[0].files["camera"] == "seg-000/camera.mov")
    #expect(harness.finishes.count == 3)
    #expect(stream.stopCount == 1)
    #expect(RecordingPackageLease.isAvailable(package))
}

@Test @MainActor func lifecycleLowDiskBeforeStartDoesNotCreatePackageOrStream() async throws {
    let harness = try LifecycleHarness(); defer { harness.cleanup() }
    harness.freeBytes = 999_999_999
    let session = harness.session()
    await #expect(throws: CaptureError.diskFull(availableBytes: 999_999_999)) { try await session.start() }
    #expect(session.state == .failed(.diskFull(availableBytes: 999_999_999)))
    #expect(session.packageURL == nil)
    #expect(harness.streams.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: harness.directory.path).isEmpty)
}

@Test @MainActor func lifecyclePermissionRevokedDuringPausePreservesFinalizedSegment() async throws {
    let harness = try LifecycleHarness(); defer { harness.cleanup() }
    let session = harness.session()
    try await session.start()
    try await session.pause()
    let package = try #require(session.packageURL)
    harness.permission = .denied
    await #expect(throws: CaptureError.permissionDenied(.screen)) { try await session.resume() }
    #expect(session.state == .failed(.permissionDenied(.screen)))
    let value = try readSession(package)
    #expect(value.status == "interrupted")
    #expect(value.segments.count == 1 && value.segments[0].durationNs > 0)
    #expect(harness.finishes.count == 1)
    #expect(harness.streams[0].stopCount == 1)
    #expect(RecordingPackageLease.isAvailable(package))
}

@Test @MainActor func lifecycleStartAndResumeUseFirstScreenOriginForManifestAndEvents() async throws {
    let harness = try LifecycleHarness(); defer { harness.cleanup() }
    harness.delayFirstFrame = true
    var eventTimes: [Int64] = []
    harness.eventHook = { recorder in
        let now = CaptureClock.inputEventTime()
        eventTimes.append(now)
        recorder.record(InputEventSnapshot(type: .leftMouseDown, hostNs: now, location: .zero))
    }
    let session = harness.session()
    try await session.start()
    try await session.pause()
    try await session.resume()
    let package = try await session.stop()
    let value = try readSession(package)
    #expect(value.segments.count == 2)
    for index in value.segments.indices {
        let segment = value.segments[index]
        let stream = harness.streams[index]
        let origin = try #require(stream.firstFrameNs)
        #expect(segment.hostStartNs == origin)
        #expect(origin - stream.writer.hostStartNs >= 30_000_000)
        #expect(segment.trackStartNs["screen"] == 0)
        let events = try Data(contentsOf: package.appendingPathComponent("recording/\(segment.dir)/events.jsonl"))
            .split(separator: 0x0a).map { try JSONDecoder().decode(CaptureEvent.self, from: Data($0)) }
        #expect(events.count == 1)
        #expect(events[0].t == eventTimes[index] - origin)
        #expect(events[0].t <= segment.durationNs)
    }
    #expect(value.segments[1].srcStartNs == value.segments[0].durationNs)
}
