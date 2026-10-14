import XCTest
import YapcamCore
@testable import YapcamRender

final class ProjectAdapterTests: XCTestCase {
    var package: URL!
    override func setUpWithError() throws {
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        package=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-project-render-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: fixture,to: package)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: package) }
    func testRealProjectClipsSnapshotAndAudioCompositionAgreeAfterCutAndSpeed() throws {
        let project=try Project.create(package: package)
        try project.apply(.deleteRange(startNs: 1_000_000_000,endNs: 2_000_000_000))
        struct Clip: Decodable { var id: String }
        let clips=try project.query("{\"q\":\"clips\"}",as: [Clip].self)
        try project.apply(.setSpeed(clipID: clips[0].id,speed: 2))
        let source: any RenderProjectSource=project
        let snapshot=try source.renderSnapshot()
        XCTAssertEqual(try source.renderClips().count,2)
        XCTAssertEqual(snapshot.durationNs,3_500_000_000)
        let timeline=try AudioTimeline(project: snapshot,range: 0..<snapshot.durationNs)
        XCTAssertEqual(timeline.composition.duration.seconds,3.5,accuracy: 0.001)
        try project.apply(.set(path: "canvas.padding",value: .number(100)))
        XCTAssertNotEqual(try project.frame(atNs: 0).screen_dest.x,try snapshot.frame(atNs: 0).screen_dest.x)
        XCTAssertEqual(try snapshot.frame(atNs: 500_000_000).screen.src_ns,2_000_000_000)
    }
    func testManualZoomFromSharedEvaluatorIsAvailableToRenderer() throws {
        let project=try Project.create(package: package)
        try project.apply(.addZoom(.init(startNs: 500_000_000,endNs: 2_000_000_000,target: [0.6,0.4],scale: 2,easeInNs: 0,easeOutNs: 0)))
        let source: any RenderProjectSource=project
        let frame=try source.frame(atNs: 1_000_000_000)
        XCTAssertEqual(frame.screen_crop.w,0.5,accuracy: 0.000_001)
        XCTAssertEqual(frame.screen.segment,0)
        XCTAssertThrowsError(try source.renderBackgroundAsset(index: .max))
    }
}
