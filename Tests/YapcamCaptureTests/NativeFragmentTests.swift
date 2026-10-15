@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import YapcamCapture

private struct MovieAtom {
    var type: String
    var range: Range<Int>
}
/// Top-level QTFF atom framing only; no custom media decoder.
private func movieAtoms(_ data: Data) throws -> [MovieAtom] {
    var offset = 0, atoms: [MovieAtom] = []
    while offset < data.count {
        guard data.count - offset >= 8 else { throw CaptureError.writerFailed("Truncated atom header") }
        var size = UInt64(data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) })
        let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
        var header = 8
        if size == 1 {
            guard data.count - offset >= 16 else { throw CaptureError.writerFailed("Truncated extended atom") }
            size = data.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self)) }
            header = 16
        } else if size == 0 { size = UInt64(data.count - offset) }
        guard size >= header, size <= UInt64(data.count - offset) else { throw CaptureError.writerFailed("Invalid atom bounds") }
        let end = offset + Int(size)
        atoms.append(MovieAtom(type: type, range: offset..<end)); offset = end
    }
    return atoms
}

private final class NativeTrackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var accepted = 0
    private var error: CaptureError?
    func append() { lock.withLock { accepted += 1 } }
    func fail(_ error: CaptureError) { lock.withLock { self.error = error } }
    var state: (Int, CaptureError?) { lock.withLock { (accepted, error) } }
}
private final class CountedNativeSink: CaptureTrackSink, @unchecked Sendable {
    let native: MediaTrackWriter
    let counter: NativeTrackCounter
    var url: URL { native.url }
    var firstNs: Int64 { native.firstNs }
    init(url: URL, key: String, first: CMSampleBuffer, counter: NativeTrackCounter) throws {
        native = try MediaTrackWriter(url: url, key: key, first: first); self.counter = counter
    }
    func append(_ sample: CMSampleBuffer) throws -> Bool {
        let accepted = try native.append(sample)
        if accepted { counter.append() }
        return accepted
    }
    func finish(atHostNs end: Int64?) async throws { try await native.finish(atHostNs: end) }
}

@Suite(.serialized) struct NativeFragmentTests {
    @Test func atomScannerRejectsTruncationAndAcceptsExtendedAndToEndSizes() throws {
        let data = Data([0,0,0,1, 109,111,111,102, 0,0,0,0,0,0,0,16, 0,0,0,0, 109,100,97,116, 1,2])
        let atoms = try movieAtoms(data)
        #expect(atoms.map(\.type) == ["moof", "mdat"])
        #expect(atoms.map(\.range) == [0..<16, 16..<26])
        #expect(throws: CaptureError.self) { try movieAtoms(Data(data.prefix(12))) }
        #expect(throws: CaptureError.self) { try movieAtoms(Data([0,0,0,7,109,111,111,102])) }
    }

    /// One-hour media clock, accelerated sparse 1 Hz video. No screen grant needed;
    /// real VideoToolbox/AVFoundation are needed. This is not a 60 fps throughput test.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAPCAM_CAPTURE_MEDIA_TESTS"] == "1"))
    func nativeHourHasExpectedFragmentsFileBoundsAndMonotonicSamples() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-native-hour-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host: Int64 = 9_000_000_000_000, duration: Int64 = 3_600_000_000_000
        let samples = try InjectedCaptureSamples(), counter = NativeTrackCounter()
        let writer = SegmentWriter(directory: directory, hostStartNs: host, maxFPS: 60) { url, key, first in
            try CountedNativeSink(url: url, key: key, first: first, counter: counter)
        }
        writer.onFailure = { counter.fail($0) }
        writer.end(at: host + duration)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.queue.async {
                do {
                    for second in 0..<3600 {
                        try autoreleasepool {
                            let sample = try samples.video(at: host + Int64(second) * 1_000_000_000, fps: 1)
                            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                            while counter.state.0 <= second {
                                writer.append(sample, track: "screen")
                                if let error = counter.state.1 { throw error }
                                guard ContinuousClock.now < deadline else { throw CaptureError.writerFailed("Native encoder backpressure timeout") }
                                if counter.state.0 <= second { Thread.sleep(forTimeInterval: 0.001) }
                            }
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        let result = await writer.finish()
        try #require(result.error == nil)
        #expect(counter.state.0 == 3600 && result.starts["screen"] == 0)
        let url = directory.appendingPathComponent("screen.mov")
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        try #require(size > 10_000 && size < 64 * 1024 * 1024)
        let data = try Data(contentsOf: url), atoms = try movieAtoms(data)
        let fragments = atoms.filter { $0.type == "moof" }
        #expect((1799...1801).contains(fragments.count))
        #expect(atoms.filter { $0.type == "mdat" }.count >= fragments.count)
        #expect(data.count == size)
        #expect(abs(try Recovery.inspect(url, video: true) - duration) <= 1_000_000)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        try #require(reader.startReading())
        var count = 0, last: Int64 = -1, lastSync: Int64 = 0
        while let sample = output.copyNextSampleBuffer() {
            let ns = CaptureClock.nanoseconds(sample.presentationTimeStamp)
            #expect(ns > last); last = ns; count += CMSampleBufferGetNumSamples(sample)
            let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            if (info?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool) != true {
                #expect(ns - lastSync <= 3_000_000_000); lastSync = ns
            }
        }
        #expect(reader.status == .completed && count == 3600)
        #expect(last == duration - 1_000_000_000 && duration - lastSync <= 3_000_000_000)
        print("CAPTURE_NATIVE_HOUR frames=\(count) fragments=\(fragments.count) bytes=\(data.count) duration_ns=\(duration) sparse_fps=1 target_fragment_ns=2000000000")
    }
}
