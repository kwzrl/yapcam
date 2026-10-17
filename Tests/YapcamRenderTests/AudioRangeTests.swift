import XCTest
@testable import YapcamRender

final class AudioRangeTests: XCTestCase {
    func testFullWidthRangeMappingPreservesNanosecondsBeyondDoublePrecision() throws {
        let row=RenderAudioRange(track: .mic,path: "audio.wav",fileStartNs: 0,fileEndNs: .max,tlStartNs: 0,tlEndNs: .max)
        try row.validate()
        for timestamp: Int64 in [0,9_007_199_254_740_993,Int64.max-1,Int64.max] {
            XCTAssertEqual(row.fileNs(atTimelineNs: timestamp),timestamp)
            XCTAssertEqual(row.timelineNs(atFileNs: timestamp),timestamp)
        }
        let fast=RenderAudioRange(track: .mic,path: "audio.wav",fileStartNs: 10,fileEndNs: 6_000_000_000_000_000_010,tlStartNs: 0,tlEndNs: 3_000_000_000_000_000_000)
        XCTAssertEqual(fast.fileNs(atTimelineNs: 2_000_000_000_000_000_001),4_000_000_000_000_000_012)
        XCTAssertEqual(fast.timelineNs(atFileNs: 4_000_000_000_000_000_012),2_000_000_000_000_000_001)
    }
    func testGainEndpointsInterpolateInDecibelsAndMuteStaysZero() throws {
        var row=RenderAudioRange(track: .systemAudio,path: "audio.wav",fileStartNs: 0,fileEndNs: 100,tlStartNs: 0,tlEndNs: 100,gainStart: 1,gainEnd: 0.01)
        XCTAssertEqual(row.gain(atTimelineNs: 50),0.1,accuracy: 0.000_001)
        row.gainStart=0; row.gainEnd=0
        XCTAssertEqual(row.gain(atTimelineNs: 50),0)
        row.tlEndNs=0
        XCTAssertThrowsError(try row.validate())
    }

    func testZeroPhysicalSpanAndOutOfRangeQueriesClampWithoutTrapping() throws {
        let missing=RenderAudioRange(track: .mic,path: "missing.wav",fileStartNs: 50,fileEndNs: 50,tlStartNs: 100,tlEndNs: 200)
        try missing.validate()
        XCTAssertEqual(missing.fileNs(atTimelineNs: 150),50)
        XCTAssertEqual(missing.timelineNs(atFileNs: 50),100)
        let row=RenderAudioRange(track: .mic,path: "audio.wav",fileStartNs: 10,fileEndNs: 20,tlStartNs: 100,tlEndNs: 200)
        XCTAssertEqual(row.fileNs(atTimelineNs: .min),10)
        XCTAssertEqual(row.fileNs(atTimelineNs: .max),20)
        XCTAssertEqual(row.timelineNs(atFileNs: .min),100)
        XCTAssertEqual(row.timelineNs(atFileNs: .max),200)
    }
}
