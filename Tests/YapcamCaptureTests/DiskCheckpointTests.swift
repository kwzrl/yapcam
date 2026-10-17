import Foundation
import Testing
@testable import YapcamCapture

private final class CheckpointProbe: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var value = 0
    func perform() {
        let count = lock.withLock { value += 1; return value }
        if count == 1 { started.signal(); release.wait() }
    }
    var count: Int { lock.withLock { value } }
}

@Test func diskCheckpointCoalescesSlowDiskWithoutBlockingInputOrLosingFinalFlush() throws {
    let probe = CheckpointProbe()
    let checkpoint = CaptureDiskCheckpoint(url: URL(fileURLWithPath: "/unused"), originNs: 100) { _ in probe.perform() }
    try checkpoint.request(atHostNs: 100 + 1_999_999_999)
    #expect(probe.count == 0)
    try checkpoint.request(atHostNs: 100 + 2_000_000_000)
    let started = probe.started.wait(timeout: .now() + 2)
    defer { probe.release.signal() }
    try #require(started == .success)
    for tick: Int64 in 3...3600 { try checkpoint.request(atHostNs: 100 + tick * 1_000_000_000) }
    #expect(probe.count == 1) // no unbounded work despite an hour of source time
    probe.release.signal()
    try checkpoint.finish()
    #expect(probe.count == 2) // one pending fsync and one required final flush
}

@Test func diskCheckpointFailurePropagatesThroughFinishAndLaterRequests() throws {
    let checkpoint = CaptureDiskCheckpoint(url: URL(fileURLWithPath: "/unused"), originNs: 0) { _ in throw CocoaError(.fileWriteOutOfSpace) }
    try checkpoint.request(atHostNs: 2_000_000_000)
    #expect(throws: CaptureError.self) { try checkpoint.finish() }
    #expect(throws: CaptureError.self) { try checkpoint.request(atHostNs: 4_000_000_000) }
}
