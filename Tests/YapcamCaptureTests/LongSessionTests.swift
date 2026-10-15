@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import YapcamCapture

/// This ledger deliberately is NOT MOV/AAC. It models completed encoder fragments
/// behind the real SegmentWriter injection point. Native encoding has its own test.
private final class FragmentLedgerSink: CaptureTrackSink, @unchecked Sendable {
    static let header = Data("SIMCAP01".utf8)
    static let recordBytes = 24
    static let marker: UInt64 = 0x59415043414D3331
    let url: URL
    let firstNs: Int64
    private let lock = NSLock()
    private let file: FileHandle
    private var nextEnd = CaptureMediaPolicy.fragmentDurationNs
    private var pending: UInt64 = 0
    private var last: Int64 = -1
    private var accepted: UInt64 = 0
    private var ends: [Int64] = []

    init(url: URL, firstNs: Int64) throws {
        self.url = url; self.firstNs = firstNs
        try Self.header.write(to: url)
        file = try FileHandle(forWritingTo: url); try file.seekToEnd()
    }
    private func commit(_ end: Int64) throws {
        var data = Data()
        for value in [UInt64(end), pending, UInt64(end) ^ pending ^ Self.marker] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        try file.write(contentsOf: data)
        ends.append(end); pending = 0
    }
    func append(_ sample: CMSampleBuffer) throws -> Bool {
        try lock.withLock {
            let ns = CaptureClock.nanoseconds(sample.presentationTimeStamp) - firstNs
            guard ns > last else { return false }
            while ns >= nextEnd {
                try commit(nextEnd); nextEnd += CaptureMediaPolicy.fragmentDurationNs
            }
            last = ns; pending += 1; accepted += 1
            return true
        }
    }
    func finish(atHostNs end: Int64?) async throws {
        try lock.withLock {
            guard let end, end > firstNs else { throw CaptureError.writerFailed("Missing simulated stop") }
            if pending > 0 { try commit(end - firstNs) }
            try file.synchronize(); try file.close()
        }
    }
    var summary: (samples: UInt64, ends: [Int64]) { lock.withLock { (accepted, ends) } }
    static func duration(_ url: URL) throws -> Int64 {
        let data = try Data(contentsOf: url)
        guard data.starts(with: header) else { throw CaptureError.writerFailed("Not a simulated fragment ledger") }
        var last: UInt64 = 0
        for offset in stride(from: header.count, through: data.count - recordBytes, by: recordBytes) {
            let end = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
            let count = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self)) }
            let checksum = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset + 16, as: UInt64.self)) }
            guard end > last, end <= UInt64(Int64.max), checksum == end ^ count ^ marker else { break }
            last = end
        }
        guard last > 0 else { throw CaptureError.writerFailed("No committed simulated fragment") }
        return Int64(last)
    }
}

private final class LedgerTracks: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: FragmentLedgerSink] = [:]
    func make(_ url: URL, key: String, first: CMSampleBuffer) throws -> any CaptureTrackSink {
        let sink = try FragmentLedgerSink(url: url, firstNs: CaptureClock.nanoseconds(first.presentationTimeStamp))
        lock.withLock { values[key] = sink }; return sink
    }
    var sinks: [String: FragmentLedgerSink] { lock.withLock { values } }
}

/// Buffers carry genuine CoreMedia video/PCM descriptions and timing; immutable
/// backing storage is reused. Only the sink is simulated, never the router/events.
final class InjectedCaptureSamples: @unchecked Sendable {
    private let pixel: CVPixelBuffer
    private let videoFormat: CMVideoFormatDescription
    private let audioFormat: CMAudioFormatDescription
    private let pcm: CMBlockBuffer
    init() throws {
        var image: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &image) == kCVReturnSuccess,
              let image else { throw CaptureError.writerFailed("Cannot allocate injected image") }
        pixel = image
        CVPixelBufferLockBaseAddress(pixel, [])
        if let bytes = CVPixelBufferGetBaseAddress(pixel) { memset(bytes, 80, CVPixelBufferGetDataSize(pixel)) }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var video: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescriptionOut: &video) == noErr, let video else { throw CaptureError.writerFailed("Cannot describe injected video") }
        videoFormat = video
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var audio: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audio) == noErr,
              let audio else { throw CaptureError.writerFailed("Cannot describe injected PCM") }
        audioFormat = audio
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 800 * 4,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 800 * 4,
            flags: 0, blockBufferOut: &block) == noErr, let block else { throw CaptureError.writerFailed("Cannot allocate injected PCM") }
        guard CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: 800 * 4) == noErr else {
            throw CaptureError.writerFailed("Cannot clear injected PCM")
        }
        pcm = block
    }
    func video(at ns: Int64, fps: Int32 = 60) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: fps),
            presentationTimeStamp: CMTime(value: ns, timescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescription: videoFormat, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { throw CaptureError.writerFailed("Cannot create injected video sample") }
        return sample
    }
    func audio(at ns: Int64) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: ns, timescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: pcm, formatDescription: audioFormat,
            sampleCount: 800, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample else {
            throw CaptureError.writerFailed("Cannot create injected audio sample")
        }
        return sample
    }
}

private struct RecordedEventIndex {
    var time: Int64
    var end: Int
}
private func eventIndex(_ data: Data) throws -> [RecordedEventIndex] {
    var result: [RecordedEventIndex] = [], end = 0
    let decoder = JSONDecoder()
    for line in data.split(separator: 0x0a) {
        end += line.count + 1
        result.append(RecordedEventIndex(time: try decoder.decode(CaptureEvent.self, from: Data(line)).t, end: end))
    }
    return result
}
private func prefixEnd(_ events: [RecordedEventIndex], through time: Int64) -> Int {
    var low = 0, high = events.count
    while low < high {
        let middle = (low + high) / 2
        if events[middle].time <= time { low = middle + 1 } else { high = middle }
    }
    return low == 0 ? 0 : events[low - 1].end
}

@Suite(.serialized) struct LongSessionTests {
    @Test func hourAtSixtyFPSAndHundredSeededCrashRecoveries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-hour-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host: Int64 = 9_000_000_000_000
        let duration: Int64 = 3_600_000_000_000
        let offsets: [String: Int64] = ["screen": 0, "system_audio": 20_000_000, "mic": 30_000_000]
        let tracks = LedgerTracks(), samples = try InjectedCaptureSamples()
        let writer = SegmentWriter(directory: directory, hostStartNs: host, maxFPS: 60) { try tracks.make($0, key: $1, first: $2) }
        writer.end(at: host + duration)
        let feed = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.queue.async {
                    do {
                        for second in 0..<3600 {
                            try autoreleasepool {
                                for frame in 0..<60 {
                                    let ns = host + CaptureClock.nanoseconds(CMTime(value: Int64(second * 60 + frame), timescale: 60))
                                    writer.append(try samples.video(at: ns), track: "screen")
                                    writer.append(try samples.audio(at: ns + 20_000_000), track: "system_audio")
                                    writer.append(try samples.audio(at: ns + 30_000_000), track: "mic")
                                }
                            }
                        }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        let failures = try await MainActor.run {
            let events = InputEventRecorder(directory: directory, rect: CGRect(x: -100, y: 50, width: 64, height: 64), hostStartNs: host, keys: true)
            var failures: [CaptureError] = []
            events.failure = { failures.append($0) }
            try events.openEventLog()
            for tick in 0..<36_000 {
                let ns = host + Int64(tick) * 100_000_000
                let point = CGPoint(x: -100 + tick % 64, y: 50 + tick % 63)
                events.recordPosition(point, hostNs: ns)
                if tick % 10 == 0 {
                    events.record(InputEventSnapshot(type: .leftMouseDown, hostNs: ns, location: point))
                    events.record(InputEventSnapshot(type: .leftMouseUp, hostNs: ns, location: point))
                    events.record(InputEventSnapshot(type: .keyDown, hostNs: ns, text: "k", flags: .maskCommand))
                }
            }
            try events.stop()
            return failures
        }
        try await feed.value
        let result = await writer.finish()
        try #require(result.error == nil && failures.isEmpty)
        try #require(result.hostStartNs == host && result.starts == offsets)
        #expect(tracks.sinks["screen"]?.summary.samples == 216_000)
        #expect(tracks.sinks["mic"]?.summary.samples == 215_999)
        #expect(tracks.sinks["system_audio"]?.summary.samples == 215_999)
        #expect(CaptureMediaPolicy.fragmentDurationNs == 2_000_000_000)
        let persistedHost = try JSONDecoder().decode(Int64.self, from: Data(contentsOf: directory.appendingPathComponent("host-start.json")))
        let persistedStarts = try JSONDecoder().decode([String: Int64].self, from: Data(contentsOf: directory.appendingPathComponent("track-starts.json")))
        #expect(persistedHost == host && persistedStarts == offsets)
        var media: [String: Data] = [:]
        for (key, sink) in tracks.sinks {
            let summary = sink.summary
            #expect(summary.ends.count == 1800)
            #expect(summary.ends.last == duration - offsets[key]!)
            #expect(zip(summary.ends, summary.ends.dropFirst()).allSatisfy { $1 > $0 && $1 - $0 <= 2_000_000_000 })
            let data = try Data(contentsOf: sink.url)
            #expect(data.count == 8 + 1800 * FragmentLedgerSink.recordBytes)
            let persistedCount = stride(from: 16, to: data.count, by: FragmentLedgerSink.recordBytes).reduce(UInt64(0)) { total, offset in
                total + data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
            }
            #expect(persistedCount == summary.samples)
            #expect(try FragmentLedgerSink.duration(sink.url) == duration - offsets[key]!)
            media[key] = data
        }
        let eventData = try Data(contentsOf: directory.appendingPathComponent("events.jsonl"))
        let index = try eventIndex(eventData)
        #expect(index.count == 46_800 && index.first?.time == 0 && index.last?.time == duration - 100_000_000)
        #expect(zip(index, index.dropFirst()).allSatisfy { $1.time >= $0.time })
        #expect(eventData.count > 1_000_000 && eventData.count < 8_000_000)
        var crashPoints: [Int64] = [0, 1_999_999_999, 2_000_000_000, 2_000_000_001, duration - 1]
        var seed: UInt64 = 0x59415043414D
        for _ in 0..<95 { seed = seed &* 6364136223846793005 &+ 1; crashPoints.append(Int64(seed % UInt64(duration))) }
        var recoveredTrials = 0
        for (trial, crash) in crashPoints.enumerated() {
            let package = root.appendingPathComponent("trial-\(trial).yapcam")
            let segment = package.appendingPathComponent("recording/seg-000")
            try FileManager.default.createDirectory(at: segment, withIntermediateDirectories: true)
            var manifest = SessionManifest(source: SourceMetadata(kind: "display", displayID: 1,
                contentRectPoints: [0, 0, 64, 64], scale: 1), tracks: TrackMetadata(screen: ScreenMetadata(pixelSize: [64, 64], maxFPS: 60)))
            manifest.segments = [SegmentMetadata(index: 0, dir: "seg-000", srcStartNs: 0, hostStartNs: host - 99)]
            let manifestURL = package.appendingPathComponent("recording/session.json")
            try PackageIO.write(manifest, to: manifestURL)
            try PackageIO.write(manifest, to: manifestURL) // previous durable version
            if trial % 3 == 0 { try Data("{torn manifest".utf8).write(to: manifestURL) }
            let beforeManifest = try Data(contentsOf: manifestURL)
            try PackageIO.write(persistedHost, to: segment.appendingPathComponent("host-start.json"))
            try PackageIO.write(persistedStarts.filter { $0.value <= crash }, to: segment.appendingPathComponent("track-starts.json"))
            var expectedDuration: Int64 = 0
            for (key, offset) in offsets where offset <= crash {
                let committed = Int((crash - offset) / 2_000_000_000)
                let torn = 1 + trial % (FragmentLedgerSink.recordBytes - 1)
                let length = 8 + committed * FragmentLedgerSink.recordBytes + torn
                let url = segment.appendingPathComponent(key == "screen" ? "screen.mov" : key == "mic" ? "mic.m4a" : "system.m4a")
                try Data(media[key]!.prefix(length)).write(to: url)
                #expect(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == length)
                if committed > 0 { expectedDuration = max(expectedDuration, offset + Int64(committed) * 2_000_000_000) }
            }
            var crashedEvents = Data(eventData.prefix(prefixEnd(index, through: crash)))
            if crash > 0 { crashedEvents.append(Data("{\"t\":0,\"type\":\"move\"}\n".utf8)) }
            crashedEvents.append(Data("{\"t\":\(duration + 1),\"type\":\"move\"}\n{\"t\":".utf8))
            let eventURL = segment.appendingPathComponent("events.jsonl")
            try crashedEvents.write(to: eventURL)
            if crash < 2_000_000_000 {
                #expect(throws: CaptureError.self) { try Recovery.recover(package) { url, _ in try FragmentLedgerSink.duration(url) } }
                #expect(try Data(contentsOf: manifestURL) == beforeManifest)
                #expect(try Data(contentsOf: eventURL) == crashedEvents)
            } else {
                _ = try Recovery.recover(package) { url, _ in try FragmentLedgerSink.duration(url) }
                let recovered = try PackageIO.readManifest(at: manifestURL)
                #expect(recovered.status == "complete" && recovered.segments.count == 1)
                #expect(recovered.segments[0].index == 0 && recovered.segments[0].srcStartNs == 0)
                #expect(recovered.segments[0].hostStartNs == host && recovered.segments[0].trackStartNs["screen"] == 0)
                #expect(recovered.segments[0].durationNs == expectedDuration, "trial \(trial), crash \(crash)")
                #expect(expectedDuration <= crash && crash - expectedDuration < 2_000_000_000)
                #expect(try Data(contentsOf: eventURL) == Data(eventData.prefix(prefixEnd(index, through: expectedDuration))))
                #expect(try Data(contentsOf: eventURL.appendingPathExtension("prev")) == crashedEvents)
                let stable = try Data(contentsOf: manifestURL)
                _ = try Recovery.recover(package) { _, _ in Issue.record("Complete recovery should be idempotent"); return 0 }
                #expect(try Data(contentsOf: manifestURL) == stable)
                recoveredTrials += 1
            }
            #expect(RecordingPackageLease.isAvailable(package))
            try FileManager.default.removeItem(at: package)
        }
        print("CAPTURE_HOUR fps=60 video=216000 audio=215999x2 events=\(index.count) event_bytes=\(eventData.count) fragments=1800x3 ledger_bytes=43208x3 crash_trials=100 recovered=\(recoveredTrials) seed=0x59415043414D")
    }
}
