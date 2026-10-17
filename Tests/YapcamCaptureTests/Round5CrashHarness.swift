#if ROUND5_CAPTURE_CRASH_HARNESS
@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import Foundation
@testable import YapcamCapture

private func require(_ value: Bool, _ message: String) throws {
    guard value else { throw CaptureError.writerFailed(message) }
}

/// Reads only complete top-level atoms; a writer can have an incomplete tail.
private func fragments(_ data: Data) -> Int {
    var offset = 0, count = 0, pending = false
    while offset + 8 <= data.count {
        var size = UInt64(data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) })
        let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
        var header = 8
        if size == 1 {
            guard offset + 16 <= data.count else { break }
            size = data.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self)) }
            header = 16
        }
        guard size >= header, size <= data.count - offset else { break }
        if type == "moof" { pending = true }
        if type == "mdat", pending { count += 1; pending = false }
        offset += Int(size)
    }
    return count
}

private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    private var failure: CaptureError?
    func accepted(_ key: String) { lock.withLock { values[key, default: 0] += 1 } }
    func fail(_ error: CaptureError) { lock.withLock { failure = error } }
    func count(_ key: String) throws -> Int {
        try lock.withLock { if let failure { throw failure }; return values[key, default: 0] }
    }
}

private final class CountedSink: CaptureTrackSink, @unchecked Sendable {
    let native: MediaTrackWriter
    let key: String
    let counts: Counts
    var url: URL { native.url }
    var firstNs: Int64 { native.firstNs }
    init(url: URL, key: String, first: CMSampleBuffer, counts: Counts) throws {
        self.key = key; self.counts = counts
        native = try MediaTrackWriter(url: url, key: key, first: first, maxFPS: 30)
    }
    func append(_ sample: CMSampleBuffer) throws -> Bool {
        let accepted = try native.append(sample)
        if accepted { counts.accepted(key) }
        return accepted
    }
    func finish(atHostNs end: Int64?) async throws { try await native.finish(atHostNs: end) }
}

/// Immutable pixels/format are read only on the writer queue after construction.
private struct Samples: @unchecked Sendable {
    let pixel: CVPixelBuffer
    let format: CMVideoFormatDescription
    init() throws {
        var pixel: CVPixelBuffer?
        try require(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess, "Pixel allocation")
        guard let pixel else { throw CaptureError.sourceUnavailable }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let p = CVPixelBufferGetBaseAddress(pixel) { memset(p, 80, CVPixelBufferGetDataSize(pixel)) }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        try require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format) == noErr, "Video format")
        guard let format else { throw CaptureError.sourceUnavailable }
        self.pixel = pixel; self.format = format
    }
    func sample(at ns: Int64) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: ns, timescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try require(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr, "Sample allocation")
        guard let sample else { throw CaptureError.sourceUnavailable }; return sample
    }
}

@main private enum CrashHarness {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count >= 3 else { throw CaptureError.writerFailed("Use --verify <new scratch root> or --write <package> <frames> <static>") }
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            if CommandLine.arguments[1] == "--write" {
                guard CommandLine.arguments.count == 5, let frames = Int(CommandLine.arguments[3]), (150...600).contains(frames) else {
                    throw CaptureError.writerFailed("Invalid fixture frame count")
                }
                try await write(root, frames: frames, isStatic: CommandLine.arguments[4] == "1")
            } else if CommandLine.arguments[1] == "--recover-external-fixture" {
                try require(FileManager.default.fileExists(atPath: root.appendingPathComponent("capture-test-fixture.json").path), "Not a marked synthetic fixture")
                _ = try RecordingSession.recover(root)
                let manifest = try Recovery.readManifest(root)
                guard let segment = manifest.segments.first else { throw CaptureError.sourceUnavailable }
                let report: [String: Int64] = ["complete": manifest.status == "complete" ? 1 : 0, "index": Int64(segment.index),
                    "src_start_ns": segment.srcStartNs, "duration_ns": segment.durationNs,
                    "screen_start_ns": segment.trackStartNs["screen"] ?? -1]
                try PackageIO.write(report, to: root.appendingPathComponent("recovered-check.json"))
                print("CAPTURE_FIXTURE_RECOVERED duration_ns=\(segment.durationNs)")
            } else {
                try require(CommandLine.arguments[1] == "--verify", "Unknown mode")
                try await verify(root)
            }
        } catch {
            print("CAPTURE_CRASH_FAIL \(String(reflecting: error))")
            exit(1)
        }
    }

    @MainActor static func write(_ package: URL, frames: Int, isStatic: Bool) async throws {
        try require(!FileManager.default.fileExists(atPath: package.path), "Fixture already exists")
        let directory = package.appendingPathComponent("recording/seg-000")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lease = try RecordingPackageLease(package: package)
        defer { withExtendedLifetime(lease) {} }
        let host: Int64 = 9_000_000_000_000
        var manifest = SessionManifest(source: SourceMetadata(kind: "display", displayID: 1, displayName: "Synthetic fixture",
            contentRectPoints: [0, 0, 64, 64], scale: 1), tracks: TrackMetadata(screen: ScreenMetadata(pixelSize: [64, 64], maxFPS: 30),
                camera: CameraMetadata(deviceName: "Injected camera samples", pixelSize: [64, 64], fps: 30)))
        manifest.segments = [SegmentMetadata(index: 0, dir: "seg-000", srcStartNs: 0, hostStartNs: host)]
        try PackageIO.write(manifest, to: package.appendingPathComponent("recording/session.json"))
        let events = InputEventRecorder(directory: directory, rect: CGRect(x: 0, y: 0, width: 64, height: 64), hostStartNs: host, keys: false)
        try events.openEventLog()
        let counts = Counts(), samples = try Samples()
        let writer = SegmentWriter(directory: directory, hostStartNs: host, maxFPS: 30) { url, key, first in
            try CountedSink(url: url, key: key, first: first, counts: counts)
        }
        writer.onFailure = { counts.fail($0) }
        let ticks = isStatic ? frames / 30 : frames
        let step: Int64 = isStatic ? 1_000_000_000 : 1_000_000_000 / 30
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.queue.async {
                do {
                    for index in 0...ticks {
                        try autoreleasepool {
                            let ns = host + Int64(index) * step
                            for key in ["screen", "camera"] {
                                let sample = try samples.sample(at: ns)
                                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                                while try counts.count(key) <= index {
                                    if isStatic && index > 0 && key == "screen" { writer.appendStaticScreen(atHostNs: ns) }
                                    else { writer.append(sample, track: key) }
                                    try require(ContinuousClock.now < deadline, "Encoder backpressure timeout")
                                    if try counts.count(key) <= index { Thread.sleep(forTimeInterval: 0.001) }
                                }
                            }
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        let last = Int64(ticks) * step
        _ = try events.addMarker(id: "durable-before-crash", hostNs: host + 1_000_000_000)
        for second in 0...Int(last / 1_000_000_000) {
            events.recordPosition(CGPoint(x: second, y: 1), hostNs: host + Int64(second) * 1_000_000_000)
        }
        try events.checkpoint(atHostNs: host + last + CaptureMediaPolicy.fragmentDurationNs)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        let expected = max(1, Int(last / CaptureMediaPolicy.fragmentDurationNs))
        while true {
            let done = ["screen.mov", "camera.mov"].allSatisfy {
                guard let data = try? Data(contentsOf: directory.appendingPathComponent($0)) else { return false }
                return fragments(data) >= expected
            }
            if done { break }
            try require(ContinuousClock.now < deadline, "No complete 2s fragments reached disk")
            try await Task.sleep(for: .milliseconds(10))
        }
        try PackageIO.write(["last_source_ns": last, "static": isStatic ? 1 : 0], to: package.appendingPathComponent("ready.json"))
        // Never finish/endSession/cancel/close the tracks: parent must kill this PID.
        try await Task.sleep(for: .seconds(30))
        withExtendedLifetime((writer, events)) {}
        throw CaptureError.writerFailed("Parent did not kill its fixture process")
    }

    @MainActor static func verify(_ root: URL) async throws {
        var seed: UInt64 = 0x59415043414D5235
        for trial in 0..<3 {
            seed = seed &* 6364136223846793005 &+ 1
            let frames = 155 + Int(seed % 150), isStatic = trial == 2
            let package = root.appendingPathComponent("crash-\(trial).yapcam")
            let log = root.appendingPathComponent("child-\(trial).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--write", package.path, String(frames), isStatic ? "1" : "0"]
            child.standardOutput = handle; child.standardError = handle
            try child.run()
            defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
            let ready = package.appendingPathComponent("ready.json")
            let deadline = ContinuousClock.now.advanced(by: .seconds(25))
            while !FileManager.default.fileExists(atPath: ready.path) {
                try require(child.isRunning, "Fixture exited before crash checkpoint: \((try? String(contentsOf: log, encoding: .utf8)) ?? "")")
                try require(ContinuousClock.now < deadline, "Fixture checkpoint timeout")
                try await Task.sleep(for: .milliseconds(10))
            }
            let checkpoint = try JSONDecoder().decode([String: Int64].self, from: Data(contentsOf: ready))
            try require(kill(child.processIdentifier, SIGKILL) == 0, "Cannot kill owned fixture PID")
            child.waitUntilExit()
            try require(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL, "Child was not killed by SIGKILL")
            try require(RecordingSession.interruptedPackages(in: root).contains(package), "Dead writer's lease still hides the interrupted package")
            let screen = package.appendingPathComponent("recording/seg-000/screen.mov")
            let before = SHA256.hash(data: try Data(contentsOf: screen))
            _ = try RecordingSession.recover(package)
            let manifest = try Recovery.readManifest(package)
            try require(manifest.status == "complete" && manifest.segments.count == 1, "Recovery did not finalize the take")
            let segment = manifest.segments[0], last = checkpoint["last_source_ns"]!
            try require(segment.index == 0 && segment.srcStartNs == 0 && segment.trackStartNs["screen"] == 0, "Recovery timeline/origin")
            try require(segment.durationNs > 0 && segment.durationNs <= last + 100_000_000 && last - segment.durationNs <= 2_100_000_000, "More than one fragment lost or invalid media duration")
            try require(before == SHA256.hash(data: try Data(contentsOf: screen)), "Recovery changed original media")
            for key in ["screen", "camera"] {
                let path = try segment.files[key].unwrap("Missing recovered \(key)")
                try await decode(package.appendingPathComponent("recording/\(path)"))
            }
            let data = try Data(contentsOf: screen)
            let eventData = try Data(contentsOf: package.appendingPathComponent("recording/seg-000/events.jsonl"))
            let events = try eventData.split(separator: 10).map { try JSONDecoder().decode(CaptureEvent.self, from: Data($0)) }
            try require(events.allSatisfy { $0.t <= segment.durationNs }, "Events exceed recovered media")
            try require(events.contains { $0.markerID == "durable-before-crash" }, "Acknowledged marker within retained footage was lost")
            print("CAPTURE_SIGKILL_PASS trial=\(trial) static=\(isStatic) signal=9 frames_requested=\(frames) fragments=\(fragments(data)) bytes=\(data.count) recovered_ns=\(segment.durationNs) uncommitted_tail_ns=\(max(0, last-segment.durationNs))")
        }
    }

    static func decode(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CaptureError.sourceUnavailable }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); try require(reader.startReading(), "Recovered reader could not start")
        var count = 0, prior: Int64 = -1
        while let sample = output.copyNextSampleBuffer() {
            let ns = CaptureClock.nanoseconds(sample.presentationTimeStamp)
            try require(ns > prior && sample.imageBuffer != nil, "Recovered frames must decode with increasing timestamps")
            prior = ns; count += 1
        }
        try require(reader.status == .completed && count > 0, "Recovered media did not decode through the retained tail")
    }
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw CaptureError.writerFailed(message) }; return value
    }
}
#endif
