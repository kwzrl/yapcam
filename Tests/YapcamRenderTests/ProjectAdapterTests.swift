import XCTest
import YapcamCore
import AVFoundation
import Metal
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
    func testEveryDocumentedCoreCursorStyleRendersAndSurvivesSnapshot() throws {
        let project=try Project.create(package: package)
        // ABI values from yapcam_core.h / SWIFT_API.md. Core's pointer and
        // always_default retain their historical system-arrow meaning.
        let styles: [(String, UInt32, RenderConfiguration.CursorStyle)] = [
            ("recorded",0,.recorded), ("pointer",1,.arrow),
            ("touch",2,.touch), ("arrow",3,.arrow)
        ]
        let size=CGSize(width: 1920,height: 1080)
        for (style,code,expected) in styles {
            try project.apply(.set(path: "cursor.style",value: .string(style)))
            XCTAssertEqual(try project.frameExtras(atNs: 0).cursor_style,code,style)
            let snapshot=try project.renderSnapshot()
            for ns: Int64 in [0,500_000_000,4_999_999_999] {
                XCTAssertEqual(try project.renderEffects(atNs: ns,canvasSize: size).configuration.cursorStyle,expected,style)
                XCTAssertEqual(try snapshot.renderEffects(atNs: ns,canvasSize: size).configuration.cursorStyle,expected,style)
            }
            try project.apply(.set(path: "cursor.always_default",value: .bool(true)))
            XCTAssertEqual(try project.frameExtras(atNs: 0).cursor_style,1,style)
            XCTAssertEqual(try project.renderEffects(atNs: 0,canvasSize: size).configuration.cursorStyle,.arrow,style)
            XCTAssertEqual(try snapshot.renderEffects(atNs: 0,canvasSize: size).configuration.cursorStyle,expected,style)
            try project.apply(.set(path: "cursor.always_default",value: .bool(false)))
        }
    }
    func testDocumentedArrowAndPointerUseTheSameOriginalArtworkInRealProjectFrames() throws {
        _ = try requireRenderDevice()
        let project=try Project.create(package: package)
        try project.apply(.set(path: "cursor.size",value: .number(4)))
        let renderer=RenderTests()
        var images: [String: Data]=[:]
        for style in ["recorded","pointer","touch","arrow"] {
            try project.apply(.set(path: "cursor.style",value: .string(style)))
            let snapshot=try project.snapshot()
            let frame=try snapshot.frame(atNs: 500_000_000)
            XCTAssertNotEqual(frame.cursor_visible,0)
            images[style]=Data(try renderer.pixels(frame,source: snapshot,width: 320,height: 180))
        }
        XCTAssertEqual(images["arrow"],images["pointer"])
        XCTAssertNotEqual(images["arrow"],images["touch"])
    }
    private let shapes: [(CoreRenderOptions.CursorShape, RenderConfiguration.CursorStyle)] = [
        (.arrow,.arrow), (.pointingHand,.pointer), (.touch,.touch), (.text,.text),
        (.resizeHorizontal,.resizeHorizontal), (.resizeVertical,.resizeVertical),
        (.resizeDiagonalNWSE,.resizeDiagonalNWSE), (.resizeDiagonalNESW,.resizeDiagonalNESW),
        (.openHand,.openHand), (.closedHand,.closedHand)
    ]
    private let sizes: [(CoreRenderOptions.CursorLogicalSize, VectorCursorSize)] = [
        (.small,.small), (.regular,.regular), (.large,.large), (.extraLarge,.extraLarge)
    ]
    func testEveryPersistedCursorSelectionMapsOnRealProjectAndSnapshot() throws {
        let project=try Project.create(package: package)
        let library=try project.cursorLibrary()
        XCTAssertEqual(Set(library.sets.map(\.id)),Set(VectorCursorLibrary.presets.map(\.id)))
        XCTAssertEqual(Set(library.shapes),Set(shapes.map { $0.0 }))
        XCTAssertEqual(Set(library.shapes),Set(CoreRenderOptions.CursorShape.allCases))
        XCTAssertEqual(Set(library.logicalSizes.map(\.id)),Set(sizes.map { $0.0 }))
        XCTAssertEqual(Set(library.logicalSizes.map(\.id)),Set(CoreRenderOptions.CursorLogicalSize.allCases))
        for (core,render) in sizes {
            XCTAssertEqual(try XCTUnwrap(library.logicalSizes.first { $0.id==core }).scale,Double(render.multiplier))
        }
        let canvas=CGSize(width: 1920,height: 1080)
        try project.apply(.set(path: "cursor.style",value: .string("touch")))
        let scale=try project.frame(atNs: 500_000_000).cursor_scale
        for preset in library.sets {
            for (shape,expectedShape) in shapes {
                for (size,expectedSize) in sizes {
                    try project.apply(.batch([
                        .set(path: "cursor.set_id",value: .string(preset.id)),
                        .set(path: "cursor.shape",value: .string(shape.rawValue)),
                        .set(path: "cursor.logical_size",value: .string(size.rawValue))
                    ]))
                    let snapshot=try project.renderSnapshot()
                    for source in [project as any RenderProjectSource,snapshot] {
                        for ns: Int64 in [0,500_000_000,4_999_999_999] {
                            let configuration=try source.renderEffects(atNs: ns,canvasSize: canvas).configuration
                            XCTAssertEqual(configuration.cursorSetID,preset.id)
                            XCTAssertEqual(configuration.cursorStyle,expectedShape)
                            XCTAssertEqual(configuration.cursorSize,expectedSize)
                        }
                        XCTAssertEqual(try source.frame(atNs: 500_000_000).cursor_scale,scale,"Logical size is applied only to authored artwork")
                    }
                }
            }
        }
    }
    func testCursorSelectionPersistenceDefaultPrecedenceAndSnapshotIsolation() throws {
        let project=try Project.create(package: package)
        let canvas=CGSize(width: 1920,height: 1080)
        let defaults=try project.renderEffects(atNs: 0,canvasSize: canvas).configuration
        XCTAssertNil(defaults.cursorSetID)
        XCTAssertEqual(defaults.cursorStyle,.recorded)
        XCTAssertEqual(defaults.cursorSize,.regular)
        try project.apply(.batch([
            .set(path: "cursor.style",value: .string("touch")),
            .set(path: "cursor.set_id",value: .string("coral")),
            .set(path: "cursor.shape",value: .string("pointing_hand")),
            .set(path: "cursor.logical_size",value: .string("extra_large"))
        ]))
        let frozen=try project.renderSnapshot()
        let selected=try frozen.renderEffects(atNs: 0,canvasSize: canvas).configuration
        XCTAssertEqual(selected.cursorStyle,.pointer)
        XCTAssertEqual(selected.cursorSetID,"coral")
        XCTAssertEqual(selected.cursorSize,.extraLarge)
        try project.save()
        let reopened=try Project.open(package: package)
        XCTAssertEqual(try reopened.renderEffects(atNs: 0,canvasSize: canvas).configuration,selected)
        try project.apply(.set(path: "cursor.always_default",value: .bool(true)))
        var expected=selected; expected.cursorStyle = .arrow
        XCTAssertEqual(try project.renderEffects(atNs: 0,canvasSize: canvas).configuration,expected)
        XCTAssertEqual(try frozen.renderEffects(atNs: 0,canvasSize: canvas).configuration,selected)
        try project.undo()
        XCTAssertEqual(try project.renderEffects(atNs: 0,canvasSize: canvas).configuration,selected)
        try project.apply(.set(path: "cursor.shape",value: .null))
        expected.cursorStyle = .touch
        XCTAssertEqual(try project.renderEffects(atNs: 0,canvasSize: canvas).configuration,expected)
        try project.apply(.set(path: "cursor.style",value: .string("recorded")))
        XCTAssertEqual(try project.renderEffects(atNs: 0,canvasSize: canvas).configuration.cursorSetID,"coral","Palette alone must select authored artwork")
        try project.apply(.batch([
            .set(path: "cursor.set_id",value: .null),
            .set(path: "cursor.logical_size",value: .string("regular"))
        ]))
        XCTAssertEqual(try project.renderEffects(atNs: 0,canvasSize: canvas).configuration,defaults)
    }
    func testPersistedCursorSelectionsChangeRealProjectPixelsThroughOneCompositor() throws {
        let device=try requireRenderDevice()
        let project=try Project.create(package: package)
        try project.apply(.batch([
            .set(path: "cursor.size",value: .number(4)),
            .set(path: "cursor.click_effect",value: .string("none"))
        ]))
        let compositor=try FrameCompositor(device: device,project: project)
        let target=try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,width: 320,height: 180,mipmapped: false)))
        let queue=try XCTUnwrap(device.makeCommandQueue())
        func pixels(_ source: any RenderProjectSource) throws -> Data {
            let frame=try source.frame(atNs: 500_000_000)
            XCTAssertNotEqual(frame.cursor_visible,0)
            let buffer=try XCTUnwrap(queue.makeCommandBuffer())
            try compositor.encode(frame,from: source,to: target,in: buffer)
            buffer.commit(); buffer.waitUntilCompleted()
            XCTAssertEqual(buffer.status,.completed,buffer.error?.localizedDescription ?? "")
            var bytes=[UInt8](repeating: 0,count: 320*180*4)
            target.getBytes(&bytes,bytesPerRow: 320*4,from: MTLRegionMake2D(0,0,320,180),mipmapLevel: 0)
            return Data(bytes)
        }
        let recorded=try pixels(project)
        var distinct=Set<Data>(), first: (any RenderProjectSource)?, firstPixels: Data?
        for preset in ["classic","lagoon"] {
            for (shape,_) in shapes {
                for (size,_) in sizes {
                    try project.apply(.batch([
                        .set(path: "cursor.set_id",value: .string(preset)),
                        .set(path: "cursor.shape",value: .string(shape.rawValue)),
                        .set(path: "cursor.logical_size",value: .string(size.rawValue))
                    ]))
                    let source=try project.renderSnapshot(), image=try pixels(source)
                    if first==nil { first=source; firstPixels=image }
                    XCTAssertTrue(distinct.insert(image).inserted,"Persisted palette/shape/size must change pixels: \(preset)/\(shape)/\(size)")
                }
            }
        }
        XCTAssertEqual(distinct.count,80)
        XCTAssertEqual(try pixels(XCTUnwrap(first)),firstPixels,"Snapshot and cache retain the first selection after 80 edits")
        try project.apply(.batch([
            .set(path: "cursor.set_id",value: .null),
            .set(path: "cursor.shape",value: .null),
            .set(path: "cursor.logical_size",value: .string("regular"))
        ]))
        XCTAssertEqual(try pixels(project),recorded)
        try project.apply(.set(path: "cursor.set_id",value: .string("lagoon")))
        XCTAssertNotEqual(try pixels(project),recorded,"Palette alone replaces captured PNG")
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
        XCTAssertEqual(try project.renderEffects(atNs: 500_000_000,canvasSize: CGSize(width: 1920,height: 1080)).configuration.cursorStyle,.arrow)
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
