import XCTest
@testable import YapcamRender

final class ExportTimingTests: XCTestCase {
    func testNanosecondRangeBoundariesRoundToTheMinimumCoveringFrameCount() {
        XCTAssertEqual(ExportTiming.frameCount(durationNs: 1,fps: 30),1)
        XCTAssertEqual(ExportTiming.frameCount(durationNs: 1_000_000_000,fps: 30),30)
        XCTAssertEqual(ExportTiming.frameCount(durationNs: 1_000_000_001,fps: 30),31)
        XCTAssertEqual(ExportTiming.frameCount(durationNs: 33_333_333,fps: 30),1)
        XCTAssertEqual(ExportTiming.frameCount(durationNs: 33_333_334,fps: 30),2)
        XCTAssertEqual(ExportTiming.frameCount(durationNs: Int64.max,fps: 60),553_402_322_212)
    }
    func testTenThousandFrameTimestampGridHasNoAccumulatedDrift() {
        XCTAssertEqual(ExportTiming.offsetNs(index: 10_000,fps: 24),416_666_666_667)
        XCTAssertEqual(ExportTiming.offsetNs(index: 10_000,fps: 30),333_333_333_333)
        XCTAssertEqual(ExportTiming.offsetNs(index: 10_000,fps: 60),166_666_666_667)
    }
    func testGIFCentisecondGridPreservesTimingAcrossLongExports() {
        for fps in [24,30,60] {
            let count=ExportTiming.frameCount(durationNs: 123_456_789_000,fps: fps)
            let delays=(0..<count).map { ExportTiming.gifDelay(index: $0,count: count,durationNs: 123_456_789_000) }
            XCTAssertTrue(delays.allSatisfy { $0>=0.01 })
            XCTAssertEqual(delays.reduce(0,+),123.46,accuracy: 0.000_001)
        }
        XCTAssertEqual(ExportTiming.gifDelay(index: 0,count: 1,durationNs: 1),0.01)
    }
}
