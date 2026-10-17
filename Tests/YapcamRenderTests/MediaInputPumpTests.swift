import XCTest
@testable import YapcamRender

/// Model of muxer backpressure at the editor's reported frame 93 boundary.
/// This reproduces the scheduling deadlock, not the host's native codec behavior.
private final class InterleaveGate: @unchecked Sendable {
    private let lock=NSLock()
    private var audio=0
    private var finished=false
    func read() -> Int? { lock.withLock { audio<500 ? audio : nil } }
    func append(_ value: Int) { lock.withLock { audio=value+1 } }
    func finish() { lock.withLock { finished=true } }
    func videoReady(at frame: Int) -> Bool { lock.withLock { frame<93 || audio>=340 } }
    var isFinished: Bool { lock.withLock { finished } }
}

private final class FinalVideoGate: @unchecked Sendable {
    var next=0, appended: [Int]=[]
    var ended=false
    var finished: Bool { appended.count==12 }
    // Native writers may stop accepting data immediately after the final frame.
    var writerReady: Bool { !finished }
}

final class MediaInputPumpTests: XCTestCase {
    func testVideoCallbackMarksEOFEvenWhenFinalAppendRemovesWriterReadiness() async throws {
        let state=FinalVideoGate()
        let pump=MediaInputPump<Int>(name: "video",request: { queue,callback in queue.async(execute: callback) },
            ready: { state.finished || state.writerReady },read: {
                guard state.next<12 else { return nil }; defer { state.next+=1 }; return state.next
            },append: { state.appended.append($0) },end: { state.ended=true },stop: {},cancelSource: {})
        try await pump.run()
        XCTAssertEqual(state.appended,Array(0..<12)); XCTAssertTrue(state.ended)
        XCTAssertFalse(state.writerReady,"EOF must not depend on another native readiness transition")
    }
    func testFrameLimitedAudioFeedingStallsButIndependentPumpDrains() async throws {
        let old=InterleaveGate()
        var stoppedAt=0
        for frame in 0..<150 {
            while let sample=old.read(), sample*10<=frame*1000/30 { old.append(sample) }
            if !old.videoReady(at: frame) { stoppedAt=frame; break }
        }
        XCTAssertEqual(stoppedAt,93)
        XCTAssertFalse(old.isFinished)
        let gate=InterleaveGate()
        let pump=MediaInputPump<Int>(request: { queue,callback in queue.async(execute: callback) },ready: { true },read: { gate.read() },append: { gate.append($0) },end: { gate.finish() },stop: {},cancelSource: {})
        try await pump.run()
        XCTAssertTrue(gate.videoReady(at: 93)); XCTAssertTrue(gate.isFinished)
    }
    func testNeverReadyInputFailsWithBoundedTimeout() async throws {
        let pump=MediaInputPump<Int>(timeout: 0.05,request: { _,_ in },ready: { false },read: { nil },append: { _ in },end: {},stop: {},cancelSource: {})
        let start=ProcessInfo.processInfo.systemUptime
        do { try await pump.run(); XCTFail("Expected stalled-input timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Timed out")) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,2)
    }
    func testCancellationCompletesEvenWithoutAReadinessCallback() async throws {
        let pump=MediaInputPump<Int>(request: { _,_ in },ready: { false },read: { nil },append: { _ in },end: {},stop: {},cancelSource: {})
        let task=Task { try await pump.run() }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
