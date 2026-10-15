import XCTest
@testable import YapcamRender

final class PreviewRenderQueueTests: XCTestCase {
    func testGPUCompletionAdmitsNextFrameWithoutWaitingForUIBookkeeping() throws {
        let queue=PreviewRenderQueue()
        let first=try XCTUnwrap(queue.reserve()), second=try XCTUnwrap(queue.reserve())
        XCTAssertNil(queue.reserve(),"Bound queued CPU/GPU work to two frames")
        // Model GPU completion while its MainActor reporting task is delayed.
        // Keeping the completed ticket alive must not keep its slot occupied.
        first.finish()
        let third=try XCTUnwrap(queue.reserve())
        first.finish()
        XCTAssertNil(queue.reserve(),"Repeated completion cannot release another frame's capacity")
        second.finish(); third.finish()
        let fourth=try XCTUnwrap(queue.reserve()), fifth=try XCTUnwrap(queue.reserve())
        XCTAssertNil(queue.reserve())
        fourth.finish(); fifth.finish()
    }

    func testEncodingAndCommitRemainFIFOAndFailureReturnsCapacity() throws {
        let queue=PreviewRenderQueue(), order=Order()
        let first=try XCTUnwrap(queue.reserve()), second=try XCTUnwrap(queue.reserve())
        let entered=expectation(description: "First encode started")
        let completed=expectation(description: "Second encode committed")
        let releaseFirst=DispatchSemaphore(value: 0)
        queue.submit(first) { ticket in
            order.append(1); entered.fulfill()
            _ = releaseFirst.wait(timeout: .now()+2)
            order.append(2); ticket.finish() // Also the failed-encode cleanup path.
        }
        wait(for: [entered],timeout: 2)
        queue.submit(second) { ticket in
            order.append(3); ticket.finish(); completed.fulfill()
        }
        XCTAssertNil(queue.reserve())
        releaseFirst.signal()
        wait(for: [completed],timeout: 2)
        XCTAssertEqual(order.values,[1,2,3],"Decode/encode/commit cannot reorder timeline frames")
        let next=try XCTUnwrap(queue.reserve()), last=try XCTUnwrap(queue.reserve())
        XCTAssertNil(queue.reserve())
        next.finish(); last.finish()
    }

    func testAbandonedDrawableReservationReturnsCapacity() throws {
        let queue=PreviewRenderQueue()
        var first: PreviewRenderQueue.Ticket?=try XCTUnwrap(queue.reserve())
        let second=try XCTUnwrap(queue.reserve())
        XCTAssertNotNil(first)
        XCTAssertNil(queue.reserve())
        first=nil // currentDrawable failure/deallocation must not strand a slot.
        let replacement=try XCTUnwrap(queue.reserve())
        XCTAssertNil(queue.reserve())
        second.finish(); replacement.finish()
    }

    func testConcurrentCompletionCannotOverReleaseAnotherFramesSlot() throws {
        let queue=PreviewRenderQueue()
        let first=try XCTUnwrap(queue.reserve()), second=try XCTUnwrap(queue.reserve())
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in first.finish() }
        let replacement=try XCTUnwrap(queue.reserve())
        XCTAssertNil(queue.reserve(),"Completion races must still preserve the two-frame bound")
        second.finish(); replacement.finish()
    }

    private final class Order: @unchecked Sendable {
        private let lock=NSLock()
        private var rows: [Int]=[]
        func append(_ value: Int) { lock.withLock { rows.append(value) } }
        var values: [Int] { lock.withLock { rows } }
    }
}
