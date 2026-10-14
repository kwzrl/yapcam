import XCTest
@testable import YapcamRender

final class FrameValidationTests: XCTestCase {
    func testMalformedTransformsAndNaNReturnErrorsBeforeGPUSubmission() throws {
        var frame=YcFrame(); frame.canvas_w=1920; frame.canvas_h=1080; frame.background_color=(0.2,0.3,0.4,1); frame.click_progress = -1
        XCTAssertNoThrow(try validateFrame(frame,configuration: .init()))
        frame.background_color.0 = .nan
        XCTAssertThrowsError(try validateFrame(frame,configuration: .init()))
        frame.background_color.0=0.2; frame.screen.present=1
        XCTAssertThrowsError(try validateFrame(frame,configuration: .init()))
        frame.screen_crop = .init(x: 0,y: 0,w: 1,h: 1); frame.screen_dest = .init(x: 48,y: 48,w: 1824,h: 984)
        XCTAssertNoThrow(try validateFrame(frame,configuration: .init()))
        frame.screen_crop.w=2
        XCTAssertThrowsError(try validateFrame(frame,configuration: .init()))
    }
}
