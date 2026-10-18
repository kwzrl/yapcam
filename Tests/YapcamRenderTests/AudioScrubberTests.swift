import XCTest
@testable import YapcamRender

final class AudioScrubberTests: XCTestCase {
    func testReverseScrubReversesFramesAndBothDirectionsCrossfade() throws {
        let source: [Float]=[1,10,2,20,3,30,4,40]
        let forward=try AudioScrubGrain(timelineNs: 12,velocity: 1,channels: 2,sampleRate: 400,samples: source)
        let reverse=try AudioScrubGrain(timelineNs: 12,velocity: -1,channels: 2,sampleRate: 400,samples: source)
        XCTAssertEqual(forward.timelineNs,12); XCTAssertEqual(reverse.velocity,-1)
        XCTAssertEqual(Array(forward.samples[2..<6]),[2,20,3,30])
        XCTAssertEqual(Array(reverse.samples[2..<6]),[3,30,2,20])
        XCTAssertLessThan(forward.samples[0],source[0]); XCTAssertLessThan(reverse.samples[0],source[6])
    }

    func testStoppedScrubIsSilentAndRejectsInvalidPCM() throws {
        XCTAssertEqual(try AudioScrubGrain(timelineNs: 0,velocity: 0,channels: 1,sampleRate: 48_000,samples: [1]).samples,[])
        XCTAssertThrowsError(try AudioScrubGrain(timelineNs: -1,velocity: 1,channels: 1,sampleRate: 48_000,samples: [1]))
        XCTAssertThrowsError(try AudioScrubGrain(timelineNs: 0,velocity: 1,channels: 2,sampleRate: 48_000,samples: [1]))
    }
}
