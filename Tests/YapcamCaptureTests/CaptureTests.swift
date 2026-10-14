import AVFoundation
import Foundation
import ScreenCaptureKit
import Testing
@testable import YapcamCapture

@Test func clockConversionUsesIntegerRounding() {
    #expect(CaptureClock.nanoseconds(CMTime(value: 1, timescale: 60)) == 16_666_667)
    #expect(CaptureClock.nanoseconds(CMTime(value: 1, timescale: 30)) == 33_333_333)
    #expect(CaptureClock.nanoseconds(CMTime(value: 9_123_456_789_012, timescale: 1_000_000)) == 9_123_456_789_012_000)
    #expect(CaptureClock.nanoseconds(.invalid) == 0)
}

@Test func geometryKeepsPointsAndNativePixelsSeparate() throws {
    let geometry = try CaptureGeometry(rect: CGRect(x: -1920, y: -200, width: 800, height: 600), scale: 2)
    #expect(geometry.pixelWidth == 1600)
    #expect(geometry.pixelHeight == 1200)
    #expect(geometry.local(CGPoint(x: -1900, y: -150)) == CGPoint(x: 20, y: 50))
    #expect(geometry.local(CGPoint(x: 0, y: 0)) == CGPoint(x: 1920, y: 200))
    #expect(throws: CaptureError.self) { try CaptureGeometry(rect: .zero, scale: 2) }
    #expect(throws: CaptureError.self) { try CaptureGeometry(rect: CGRect(x: 0, y: 0, width: 100, height: 100), scale: .infinity) }
}

@Test func eventEncodingMatchesWireContract() throws {
    let event = CaptureEvent(t: 123_456_789, type: "key", key: "k", modifiers: ["cmd"])
    let data = try JSONEncoder().encode(event)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["t"] as? Int64 == 123_456_789)
    #expect(json["type"] as? String == "key")
    #expect(json["modifiers"] as? [String] == ["cmd"])
    #expect(json["x"] == nil)
    #expect(try JSONDecoder().decode(CaptureEvent.self, from: data) == event)
    let move = CaptureEvent(t: 0, type: "move", x: -50.25, y: 2)
    #expect(try JSONDecoder().decode(CaptureEvent.self, from: JSONEncoder().encode(move)) == move)
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-capture-tests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func manifest() -> SessionManifest {
    SessionManifest(source: SourceMetadata(kind: "display", displayID: 2, displayName: "Test", contentRectPoints: [0, 0, 1680, 1050], scale: 1),
        tracks: TrackMetadata(screen: ScreenMetadata(pixelSize: [1680, 1050], maxFPS: 60), systemAudio: AudioMetadata(sampleRate: 48_000, channels: 2)),
        segments: [SegmentMetadata(index: 0, dir: "seg-000", srcStartNs: 0, durationNs: 123, hostStartNs: 987654321,
            files: ["screen": "seg-000/screen.mov"], trackStartNs: ["screen": 42])])
}

@Test func manifestRoundTripUsesExactSnakeCaseKeys() throws {
    let value = manifest()
    let data = try PackageIO.encoder.encode(value)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["schema_version"] as? Int == 1)
    let source = try #require(json["source"] as? [String: Any])
    #expect(source["display_id"] as? Int == 2)
    let tracks = try #require(json["tracks"] as? [String: Any])
    #expect(tracks["system_audio"] != nil)
    let screen = try #require(tracks["screen"] as? [String: Any])
    #expect(screen["max_fps"] as? Int == 60)
    #expect(screen["cursor_in_video"] as? Bool == false)
    let segments = try #require(json["segments"] as? [[String: Any]])
    #expect(segments[0]["src_start_ns"] as? Int64 == 0)
    let decoded = try JSONDecoder().decode(SessionManifest.self, from: data)
    #expect(decoded.source.displayID == 2)
    #expect(decoded.tracks.screen.maxFPS == 60)
    #expect(decoded.segments.first?.trackStartNs["screen"] == 42)
}

@Test func atomicManifestWritePreservesPreviousVersion() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("session.json")
    var value = manifest()
    try PackageIO.write(value, to: url)
    value.status = "complete"
    try PackageIO.write(value, to: url)
    #expect(try PackageIO.readManifest(at: url).status == "complete")
    #expect(try PackageIO.readManifest(at: url.appendingPathExtension("prev")).status == "recording")
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["session.json", "session.json.prev"])
}

@Test func recoveryTrimsCorruptTailAndOutOfOrderEvents() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("events.jsonl")
    let log = "{\"t\":0,\"type\":\"move\",\"x\":1,\"y\":2}\n{\"t\":40,\"type\":\"cursor\",\"id\":0}\n{\"t\":30,\"type\":\"move\"}\n{\"t\":200,\"type\":\"move\"}\n{\"t\":90"
    try Data(log.utf8).write(to: url)
    try Recovery.repairEvents(at: url, duration: 100)
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[1].contains("40"))
}

@Test @MainActor func idleSessionCancellationAndInvalidTransitions() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = RecordingSession(options: RecordingOptions(target: .display(0), outputDirectory: directory))
    #expect(session.state == .idle)
    await #expect(throws: CaptureError.self) { try await session.pause() }
    await #expect(throws: CaptureError.self) { try await session.resume() }
    await #expect(throws: CaptureError.self) { try await session.stop() }
    await session.cancel()
    #expect(session.state == .cancelled)
    #expect(session.packageURL == nil)
}

@Test @MainActor func absentDevicesWarnAndContinue() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = SegmentWriter(directory: directory, hostStartNs: CaptureClock.now, maxFPS: 30)
    let devices = AuxiliaryCapture(writer: writer, fps: 30)
    let metadata = await devices.start(microphoneID: "nonexistent-test-microphone", cameraID: "nonexistent-test-camera")
    #expect(metadata.mic == nil)
    #expect(metadata.camera == nil)
    await devices.stop()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["YAPCAM_CAPTURE_MEDIA_TESTS"] == "1"))
func actualHEVCWriterAndInterruptedRecovery() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = directory.appendingPathComponent("Test.yapcam")
    let segment = package.appendingPathComponent("recording/seg-000")
    try FileManager.default.createDirectory(at: segment, withIntermediateDirectories: true)
    let host = CaptureClock.now
    let writer = SegmentWriter(directory: segment, hostStartNs: host, maxFPS: 30)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        writer.queue.async {
            for i in 0..<10 {
                var pixel: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                    nil, &pixel) == kCVReturnSuccess, let pixel else { continue }
                CVPixelBufferLockBaseAddress(pixel, [])
                if let bytes = CVPixelBufferGetBaseAddress(pixel) { memset(bytes, Int32(100 + i), CVPixelBufferGetDataSize(pixel)) }
                CVPixelBufferUnlockBaseAddress(pixel, [])
                var format: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format)
                guard let format else { continue }
                var sample: CMSampleBuffer?
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10),
                    presentationTimeStamp: CMTime(value: host + 20_000_000 + Int64(i) * 100_000_000, timescale: 1_000_000_000), decodeTimeStamp: .invalid)
                CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
                if let sample { writer.append(sample, track: "screen") }
                // Real-time input is allowed to apply backpressure; emulate capture pacing.
                Thread.sleep(forTimeInterval: 0.02)
            }
            continuation.resume()
        }
    }
    let result = await writer.finish()
    #expect(result.error == nil)
    #expect(result.files["screen"] == "screen.mov")
    #expect(result.starts["screen"] == 20_000_000)
    let mediaDuration = try Recovery.inspect(segment.appendingPathComponent("screen.mov"), video: true)
    #expect(mediaDuration > 500_000_000)
    var value = manifest()
    value.segments = [SegmentMetadata(index: 0, dir: "seg-000", srcStartNs: 0, hostStartNs: host)]
    try PackageIO.write(value, to: package.appendingPathComponent("recording/session.json"))
    #expect(RecordingSession.interruptedPackages(in: directory) == [package])
    #expect(try RecordingSession.recover(package) == package)
    let recovered = try PackageIO.readManifest(at: package.appendingPathComponent("recording/session.json"))
    #expect(recovered.status == "complete")
    #expect(recovered.segments[0].trackStartNs["screen"] == 20_000_000)
    #expect(recovered.segments[0].durationNs == mediaDuration + 20_000_000)
    #expect(RecordingSession.interruptedPackages(in: directory).isEmpty)
}

@Test func lowDiskThresholdStopsBeforeExhaustion() throws {
    try PackageIO.requireSpace(1_000_000_000)
    #expect(throws: CaptureError.diskFull(availableBytes: 999_999_999)) { try PackageIO.requireSpace(999_999_999) }
    #expect(throws: CaptureError.diskFull(availableBytes: 0)) { try PackageIO.requireSpace(0) }
}

@Test func recoveryRejectsTraversalAndPreservesOriginalManifest() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = directory.appendingPathComponent("Test.yapcam")
    let recording = package.appendingPathComponent("recording")
    try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
    var value = manifest()
    value.segments[0].dir = "../escape"
    let url = recording.appendingPathComponent("session.json")
    try PackageIO.write(value, to: url)
    let original = try Data(contentsOf: url)
    #expect(throws: CaptureError.self) { try RecordingSession.recover(package) }
    #expect(try Data(contentsOf: url) == original)
}

@Test func segmentMathRemovesPausesWithoutAccumulatingRoundingDrift() throws {
    var segments: [SegmentMetadata] = []
    let duration: Int64 = 5_048_333_333
    #expect(try SegmentTimeline.nextSourceStart(after: segments) == 0)
    for index in 0..<10_000 {
        let offset = try SegmentTimeline.nextSourceStart(after: segments)
        segments.append(SegmentMetadata(index: index, dir: String(format: "seg-%03d", index), srcStartNs: offset,
            durationNs: duration, hostStartNs: Int64(index) * (duration + 60_000_000_000)))
    }
    #expect(try SegmentTimeline.nextSourceStart(after: segments) == 10_000 * duration)
    let invalid = SegmentMetadata(index: 0, dir: "seg-000", srcStartNs: Int64.max, durationNs: 1, hostStartNs: 0)
    #expect(throws: CaptureError.self) { try SegmentTimeline.nextSourceStart(after: [invalid]) }
}

@Test func recordingOptionsPersistKeystrokeOptInAndTargets() throws {
    for target in [CaptureTarget.display(2), .window(17), .area(display: 2, rect: CGRect(x: 10, y: 20, width: 800, height: 600))] {
        let options = RecordingOptions(target: target, outputDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(!options.recordKeystrokes)
        #expect(options.excludeYapcamWindows)
        let decoded = try JSONDecoder().decode(RecordingOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.target == target)
        #expect(decoded.maxFPS == 60)
    }
}

@Test func movedAndResizedWindowCoordinatesFollowLetterboxing() {
    let mapping = CaptureCoordinateMapping.fitted(source: CGRect(x: -800, y: 200, width: 400, height: 400),
                                                  outputSize: CGSize(width: 800, height: 600))
    #expect(mapping.local(CGPoint(x: -800, y: 200)) == CGPoint(x: 100, y: 0))
    #expect(mapping.local(CGPoint(x: -400, y: 600)) == CGPoint(x: 700, y: 600))
    #expect(mapping.local(CGPoint(x: -1000, y: 0)) == CGPoint(x: -200, y: -300))
    #expect(mapping.cursorScale == 1.5)
}

@Test func microphoneLevelComputesNormalizedRMS() throws {
    var block: CMBlockBuffer?
    let samples: [Float] = [-0.5, 0.5, -0.5, 0.5]
    let byteCount = samples.count * MemoryLayout<Float>.stride
    #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
        flags: 0, blockBufferOut: &block) == noErr)
    let bytes = try #require(block)
    samples.withUnsafeBytes { raw in
        #expect(CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bytes, offsetIntoDestination: 0, dataLength: byteCount) == noErr)
    }
    var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
        mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bytes, formatDescription: format,
        sampleCount: samples.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
        sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
    #expect(abs(SegmentWriter.level(try #require(sample)) - 0.5) < 0.00001)
}

@Test func screenFailureMappingPreservesActionableErrors() {
    #expect(CaptureError.from(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)) == .permissionDenied(.screen))
    #expect(CaptureError.from(CaptureError.diskFull(availableBytes: 100)) == .diskFull(availableBytes: 100))
}
