import XCTest
import YapcamCore
import AVFoundation
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
    func testCoreFrameExtrasMapConfigurationHighlightsAndFinalFadeOnce() throws {
        let project=try Project.create(package: package)
        try project.apply(.batch([
            .set(path: "cursor.style",value: .string("touch")),
            .set(path: "cursor.motion_blur",value: .number(0.4)),
            .set(path: "cursor.spotlight_radius",value: .number(56)),
            .set(path: "canvas.background.noise",value: .number(0.08)),
            .set(path: "canvas.window_chrome",value: .bool(true)),
            .set(path: "camera.background_removal",value: .bool(true)),
            .set(path: "camera.face_framing",value: .bool(true)),
            .set(path: "camera.shadow_radius",value: .number(32)),
            .set(path: "canvas.animation.entrance",value: .string("fade")),
            .set(path: "canvas.animation.entrance_duration_ns",value: .integer(1_000_000_000)),
            .set(path: "canvas.highlights",value: .array([.object([
                "id": .string("region"),"tl_start_ns": .integer(0),"tl_end_ns": .integer(2_000_000_000),
                "space": .string("canvas"),"rect": .array([0.25,0.25,0.5,0.5].map(JSONValue.number))
            ])]))
        ]))
        let source: any RenderProjectSource=try project.snapshot()
        let frame=try source.frame(atNs: 500_000_000)
        let effects=try source.renderEffects(atNs: frame.tl_ns,canvasSize: CGSize(width: Int(frame.canvas_w),height: Int(frame.canvas_h)))
        let configuration=effects.configuration
        XCTAssertEqual(configuration.cursorStyle,.touch)
        XCTAssertEqual(configuration.cursorMotionBlur,0.4)
        XCTAssertEqual(configuration.cursorSpotlightRadius,56)
        XCTAssertEqual(configuration.backgroundNoise,0.08)
        XCTAssertTrue(configuration.windowChrome)
        XCTAssertTrue(configuration.cameraBackgroundRemoval)
        XCTAssertTrue(configuration.cameraFaceFraming)
        XCTAssertEqual(configuration.cameraShadowRadius,32)
        XCTAssertEqual(effects.layers.count,2,"One highlight followed by one fade; no duplicate cold layers")
        XCTAssertEqual(effects.layers[0].rect,CGRect(x: 480,y: 270,width: 960,height: 540))
        XCTAssertEqual(effects.layers[1].rect,CGRect(x: 0,y: 0,width: 1920,height: 1080))
        XCTAssertEqual(effects.layers[1].opacity,0.5)
        try project.apply(.set(path: "cursor.style",value: .string("pointer")))
        XCTAssertEqual(try source.renderEffects(atNs: 500_000_000,canvasSize: CGSize(width: 1920,height: 1080)).configuration.cursorStyle,.touch)
        XCTAssertEqual(try project.renderEffects(atNs: 500_000_000,canvasSize: CGSize(width: 1920,height: 1080)).configuration.cursorStyle,.pointer)
    }
    @MainActor func testPreviewFreezesAnEditGenerationUntilInvalidated() throws {
        _ = try requireRenderDevice()
        let project=try Project.create(package: package)
        let preview=try PreviewPlayer(project: project)
        let old=try preview.renderProject.frame(atNs: 0)
        try project.apply(.set(path: "canvas.padding",value: .number(150)))
        XCTAssertEqual(try preview.renderProject.frame(atNs: 0).screen_dest.x,old.screen_dest.x)
        preview.invalidate()
        XCTAssertEqual(try preview.renderProject.frame(atNs: 0).screen_dest.x,try project.frame(atNs: 0).screen_dest.x)
        XCTAssertNotEqual(try preview.renderProject.frame(atNs: 0).screen_dest.x,old.screen_dest.x)
    }
    func testAudioQueryRampsFollowCoreAndDoNotBleedAcrossAutomationBoundaries() throws {
        let project=try Project.create(package: package)
        try project.apply(.batch([
            .set(path: "audio.system_gain_db",value: .number(-3)),
            .set(path: "audio.ranges",value: .array([.object([
                "id": .string("volume"),"track": .string("system_audio"),
                "tl_start_ns": .integer(105_000_000),"tl_end_ns": .integer(205_000_000),
                "start_gain_db": .number(-6),"end_gain_db": .number(-18)
            ])]))
        ]))
        let source=try project.snapshot()
        let rows=try XCTUnwrap(source.renderAudioRanges())
        XCTAssertEqual(rows.count,4)
        XCTAssertEqual(rows[1].tlStartNs,105_000_000)
        XCTAssertEqual(rows[1].tlEndNs,205_000_000)
        let timeline=try AudioTimeline(project: source,range: 50_000_000..<250_000_000)
        let parameter=try XCTUnwrap(timeline.mix.inputParameters.first)
        for ns: Int64 in [104_000_000,105_000_000,150_000_000,204_000_000,205_000_000] {
            let time=CMTime(value: ns-50_000_000,timescale: 1_000_000_000)
            var initial: Float=0, final: Float=0, ramp=CMTimeRange.zero
            XCTAssertTrue(parameter.getVolumeRamp(for: time,startVolume: &initial,endVolume: &final,timeRange: &ramp))
            let fraction=Float((time-ramp.start).seconds/ramp.duration.seconds)
            XCTAssertEqual(initial+(final-initial)*fraction,try source.frame(atNs: ns).system_gain,accuracy: 0.005)
        }
        XCTAssertEqual(timeline.composition.duration.seconds,0.2,accuracy: 0.000_001)
    }
}
