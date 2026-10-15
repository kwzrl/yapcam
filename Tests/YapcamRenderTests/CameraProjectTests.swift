import XCTest
import YapcamCore
@testable import YapcamRender

final class CameraProjectTests: XCTestCase {
    private var package: URL!
    override func setUpWithError() throws {
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        package=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-camera-project-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: fixture,to: package)
        let url=package.appendingPathComponent("recording/session.json")
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var tracks=try XCTUnwrap(json["tracks"] as? [String: Any])
        tracks["camera"]=["device_name":"Original synthetic fixture","pixel_size":[320,200],"fps":30,"mirrored":false]
        json["tracks"]=tracks
        var segments=try XCTUnwrap(json["segments"] as? [[String: Any]])
        for index in segments.indices {
            var files=try XCTUnwrap(segments[index]["files"] as? [String: String])
            files["camera"]=files["screen"]; segments[index]["files"]=files
        }
        json["segments"]=segments
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: package) }
    func testCameraZoomScaleGeometryFromCoreReachesFrozenRendererSource() throws {
        let project=try Project.create(package: package)
        try project.apply(.addZoom(.init(startNs: 0,endNs: 2_000_000_000,target: [0.5,0.5],scale: 2,easeInNs: 500_000_000,easeOutNs: 500_000_000)))
        let normal=try project.frame(atNs: 1_000_000_000).camera_dest
        try project.apply(.set(path: "camera.zoom_scale",value: .number(1.5)))
        let source=try project.renderSnapshot()
        let zoomed=try source.frame(atNs: 1_000_000_000)
        XCTAssertEqual(zoomed.camera.present,1)
        XCTAssertEqual(zoomed.camera_dest.w,normal.w*1.5,accuracy: 0.000_001)
        XCTAssertEqual(zoomed.camera_dest.h,normal.h*1.5,accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(zoomed.camera_dest.x,0)
        XCTAssertLessThanOrEqual(zoomed.camera_dest.x+zoomed.camera_dest.w,Double(zoomed.canvas_w))
        XCTAssertEqual(try source.frame(atNs: 0).camera_dest.w,normal.w,accuracy: 0.000_001)
        try project.apply(.set(path: "camera.zoom_scale",value: .number(1)))
        XCTAssertEqual(try source.frame(atNs: 1_000_000_000).camera_dest.w,zoomed.camera_dest.w)
        XCTAssertEqual(try project.frame(atNs: 1_000_000_000).camera_dest.w,normal.w,accuracy: 0.000_001)
    }
    func testCameraMediaAndVisionOptionsAreEvaluatedFromRealProjectData() throws {
        let project=try Project.create(package: package)
        try project.apply(.batch([
            .set(path: "camera.background_removal",value: .bool(true)),
            .set(path: "camera.face_framing",value: .bool(true)),
            .set(path: "camera.shadow_radius",value: .number(36))
        ]))
        let source=try project.renderSnapshot()
        let frame=try source.frame(atNs: 800_000_000)
        XCTAssertEqual(frame.camera.present,1); XCTAssertEqual(frame.camera.segment,0)
        XCTAssertEqual(frame.camera.file_ns,800_000_000)
        XCTAssertGreaterThan(frame.camera_dest.w,0)
        let effects=try source.renderEffects(atNs: frame.tl_ns,canvasSize: CGSize(width: Int(frame.canvas_w),height: Int(frame.canvas_h)))
        XCTAssertTrue(effects.configuration.cameraBackgroundRemoval)
        XCTAssertTrue(effects.configuration.cameraFaceFraming)
        XCTAssertEqual(effects.configuration.cameraShadowRadius,36)
        try project.apply(.set(path: "camera.background_removal",value: .bool(false)))
        XCTAssertTrue(try source.renderEffects(atNs: frame.tl_ns,canvasSize: .zero).configuration.cameraBackgroundRemoval)
        XCTAssertFalse(try project.renderEffects(atNs: frame.tl_ns,canvasSize: .zero).configuration.cameraBackgroundRemoval)
    }
    func testVisionTogglesUseProjectDataAndDoNotLeaveAStaleMatte() throws {
        let device=try requireRenderDevice(), project=try Project.create(package: package)
        try project.apply(.set(path: "camera.face_framing",value: .bool(true)))
        let compositor=try FrameCompositor(device: device,project: project)
        let frame=try project.frame(atNs: 800_000_000)
        func pixels() throws -> Data {
            let image=try compositor.image(frame,size: CGSize(width: 320,height: 180))
            return try XCTUnwrap(image.dataProvider?.data) as Data
        }
        let unmasked=try pixels()
        try project.apply(.set(path: "camera.background_removal",value: .bool(true)))
        let masked=try pixels()
        XCTAssertNotEqual(masked,unmasked,"Synthetic test pattern has no person; segmentation must affect the camera layer")
        try project.apply(.set(path: "camera.background_removal",value: .bool(false)))
        XCTAssertEqual(try pixels(),unmasked,"Disabling matting while keeping face framing must clear the cached mask")
    }
}
