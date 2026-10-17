import XCTest
import AppKit
import MetalKit
@testable import YapcamRender

final class ReelPreviewTests: XCTestCase {
    func testGuideModesUseTopLeftCoordinatesAndTrackCanvasAtAnySize() throws {
        XCTAssertEqual(ReelPreviewMode.allCases.map(\.title),["Off","Instagram","TikTok"])
        let base=CGRect(x: 0,y: 0,width: 1080,height: 1920)
        XCTAssertNil(ReelSafeAreaLayout(mode: .off,bounds: base))
        for mode in [ReelPreviewMode.instagram,.tiktok] {
            let layout=try XCTUnwrap(ReelSafeAreaLayout(mode: mode,bounds: base))
            XCTAssertTrue(base.contains(layout.safeRect))
            XCTAssertEqual(layout.safeRect.minY,layout.topRegion.maxY)
            XCTAssertEqual(layout.safeRect.maxY,layout.bottomRegion.minY,accuracy: 0.000001)
            XCTAssertEqual(layout.safeRect.maxX,layout.actionRegion.minX,accuracy: 0.000001)
            let shifted=try XCTUnwrap(ReelSafeAreaLayout(mode: mode,bounds: CGRect(x: 17,y: 23,width: 540,height: 960)))
            XCTAssertEqual(shifted.safeRect.minX,17+layout.safeRect.minX/2,accuracy: 0.000001)
            XCTAssertEqual(shifted.safeRect.minY,23+layout.safeRect.minY/2,accuracy: 0.000001)
            XCTAssertEqual(shifted.safeRect.width,layout.safeRect.width/2)
            XCTAssertEqual(shifted.safeRect.height,layout.safeRect.height/2)
        }
        XCTAssertNotEqual(ReelSafeAreaLayout(mode: .instagram,bounds: base),ReelSafeAreaLayout(mode: .tiktok,bounds: base))
        for bounds in [CGRect.zero,CGRect(x: 0,y: 0,width: -1,height: 100),CGRect(x: 0,y: 0,width: CGFloat.infinity,height: 100)] {
            XCTAssertNil(ReelSafeAreaLayout(mode: .instagram,bounds: bounds))
        }
    }

    func testGuidesShadeInterfaceButLeaveTheSafeInteriorTransparent() throws {
        let width=270,height=480
        for mode in [ReelPreviewMode.instagram,.tiktok] {
            let context=try XCTUnwrap(CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,
                space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let bounds=CGRect(x: 0,y: 0,width: width,height: height)
            let layout=try XCTUnwrap(ReelSafeAreaLayout(mode: mode,bounds: bounds))
            layout.draw(in: context,bounds: bounds)
            let pixels=try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            func alpha(_ x: Int,_ y: Int) -> UInt8 { pixels[y*width*4+x*4+3] }
            XCTAssertEqual(alpha(100,200),0,"The safe interior must not dim or obscure the preview")
            XCTAssertGreaterThan(alpha(2,2),0,"Top interface occupancy")
            XCTAssertGreaterThan(alpha(2,height-2),0,"Bottom interface occupancy")
            XCTAssertGreaterThan(alpha(width-2,250),0,"Right action rail occupancy")
        }
    }

    @MainActor func testOverlayNeverInterceptsPreviewEditingAndOffHidesIt() {
        let overlay=ReelOverlayView(mode: .instagram)
        overlay.frame=CGRect(x: 0,y: 0,width: 270,height: 480)
        XCTAssertNil(overlay.hitTest(CGPoint(x: 100,y: 200)))
        XCTAssertTrue(overlay.isFlipped); XCTAssertFalse(overlay.isOpaque)
        XCTAssertFalse(overlay.isHidden)
        overlay.mode = .off
        XCTAssertTrue(overlay.isHidden)
        overlay.mode = .tiktok
        XCTAssertFalse(overlay.isHidden)
    }

    @MainActor func testPlayerGuideIsLocalAndDoesNotChangeCompositorPixelsOnHost() throws {
        let device=try requireRenderDevice()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-reel-\(UUID().uuidString)")
        defer { print("Cleanup render-owned reel fixture: \(root.lastPathComponent)"); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recording"),withIntermediateDirectories: true)
        try Data(#"{"segments":[]}"#.utf8).write(to: root.appendingPathComponent("recording/session.json"))
        let source=TestSource(package: root)
        let player=try PreviewPlayer(project: source)
        defer { player.pause() }
        let view=PreviewMetalView(frame: CGRect(x: 0,y: 0,width: 270,height: 480),device: device)
        player.view=view; view.player=player
        XCTAssertEqual(player.previewSettings.reelMode,.off)
        let before=source.renderConfiguration
        let image=try compositorImage(source,device: device)
        try player.setPreviewSettings(.init(reelMode: .instagram))
        XCTAssertEqual(player.previewSettings.reelMode,.instagram)
        XCTAssertEqual(view.subviews.count,1)
        XCTAssertFalse(view.subviews[0].isHidden)
        XCTAssertEqual(source.renderConfiguration,before)
        XCTAssertEqual(try compositorImage(source,device: device),image,"Preview guides never enter the shared compositor/export surface")
        try player.setPreviewSettings(.init(reelMode: .tiktok))
        XCTAssertEqual(view.subviews.count,1,"Reuse one view instead of accumulating overlays")
        try player.setPreviewSettings(.init())
        XCTAssertTrue(view.subviews[0].isHidden)
        XCTAssertFalse(player.isPlaying)
    }

    private func compositorImage(_ source: any RenderProjectSource,device: MTLDevice) throws -> Data {
        let compositor=try FrameCompositor(device: device,project: source)
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,width: 108,height: 192,mipmapped: false)
        descriptor.usage=[.renderTarget,.shaderRead]
        let texture=try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let command=try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        try compositor.encode(source.frame(atNs: 0),from: source,to: texture,in: command)
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status,.completed,command.error?.localizedDescription ?? "")
        var bytes=[UInt8](repeating: 0,count: 108*192*4)
        texture.getBytes(&bytes,bytesPerRow: 108*4,from: MTLRegionMake2D(0,0,108,192),mipmapLevel: 0)
        return Data(bytes)
    }
}
