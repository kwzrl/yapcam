import XCTest
import Metal
import ImageIO
@testable import YapcamRender

final class CursorCompositorTests: XCTestCase {
    func testRippleIsThreeDistinctStaggeredRingsOnHost() throws {
        let device=try requireRenderDevice()
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let queue=try XCTUnwrap(device.makeCommandQueue())
        let target=try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,width: 240,height: 200,mipmapped: false)))
        func render(_ effect: RenderConfiguration.CursorClickEffect) throws -> [UInt8] {
            var configuration=RenderConfiguration()
            configuration.cursorSetID="classic"; configuration.cursorStyle = .arrow
            configuration.cursorClickEffect=effect; configuration.cursorClickDurationNs=450_000_000
            let source=TestSource(package: fixture,configuration: configuration) { _ in
                var frame=YcFrame(); frame.canvas_w=240; frame.canvas_h=200
                frame.background_color=(0.08,0.08,0.08,1)
                frame.cursor_visible=1; frame.cursor_opacity=1; frame.cursor_scale=3
                frame.cursor_x=18; frame.cursor_y=18
                frame.click_x=120; frame.click_y=100
                // 300 ms: all three 450 ms rings are active at distinct radii.
                frame.click_progress=300.0/590.0
                return frame
            }
            let cb=try XCTUnwrap(queue.makeCommandBuffer())
            try FrameCompositor(device: device,project: source).encode(source.frame(atNs: 0),to: target,in: cb)
            cb.commit(); cb.waitUntilCompleted()
            XCTAssertEqual(cb.status,.completed,cb.error?.localizedDescription ?? "")
            var bytes=[UInt8](repeating: 0,count: 240*200*4)
            target.getBytes(&bytes,bytesPerRow: 240*4,from: MTLRegionMake2D(0,0,240,200),mipmapLevel: 0)
            return bytes
        }
        let circle=try render(.circle), ripple=try render(.ripple)
        var changed=0
        for i in stride(from: 0,to: circle.count,by: 4) {
            let blue=abs(Int(circle[i])-Int(ripple[i]))
            let green=abs(Int(circle[i+1])-Int(ripple[i+1]))
            let red=abs(Int(circle[i+2])-Int(ripple[i+2]))
            if blue+green+red>12 { changed += 1 }
        }
        XCTAssertGreaterThan(changed,150,"Ripple must be materially distinct from Circle")

        let base=(100*240+230)*4
        let background=[Int(ripple[base]),Int(ripple[base+1]),Int(ripple[base+2])]
        var activeRuns=0, inside=false
        for x in 125..<230 {
            let i=(100*240+x)*4
            let score=(0..<3).map { abs(Int(ripple[i+$0])-background[$0]) }.max()!
            if score>10 && !inside { activeRuns += 1 }
            inside=score>10
        }
        XCTAssertEqual(activeRuns,3,"Ripple must expose three separated radial ring maxima")
    }

    func testOriginalSidecarTypedReplacementVariantsAndTouchPressOnHost() throws {
        let device = try requireRenderDevice()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-cursor-gpu-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture,to: root)
        defer { print("Cleanup render-owned cursor fixture: \(root.lastPathComponent)"); try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("recording/seg-000/cursors.json")
        try Data(#"{"1":{"file":"cursors/1.png","hotspot":[5,7],"size_points":[16,24],"shape":"text"}}"#.utf8).write(to: metadata)
        let compositor = try FrameCompositor(device: device,project: TestSource(package: root))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let target = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,width: 192,height: 144,mipmapped: false)))
        func render(_ configuration: RenderConfiguration,click: Float = -1,scale: Float = 1.75) throws -> Data {
            let source = TestSource(package: root,configuration: configuration) { ns in
                var frame = YcFrame(); frame.tl_ns = ns; frame.canvas_w = 192; frame.canvas_h = 144
                frame.background_color = (0.2,0.2,0.2,1); frame.click_progress = click
                frame.cursor_visible = 1; frame.cursor_opacity = 1; frame.cursor_scale = scale; frame.cursor_id = 1; frame.screen.segment = 0
                frame.cursor_x = 84; frame.cursor_y = 58; frame.click_x = 84; frame.click_y = 58
                return frame
            }
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            try compositor.encode(source.frame(atNs: 0),from: source,to: target,in: command)
            command.commit(); command.waitUntilCompleted(); XCTAssertEqual(command.status,.completed,command.error?.localizedDescription ?? "")
            var pixels = [UInt8](repeating: 0,count: 192*144*4)
            target.getBytes(&pixels,bytesPerRow: 192*4,from: MTLRegionMake2D(0,0,192,144),mipmapLevel: 0)
            return Data(pixels)
        }
        let legacy = try render(.init(),scale: 0.75)
        var c = RenderConfiguration(); c.cursorSetID = "original"; c.cursorStyle = .crosshair
        XCTAssertEqual(try render(c,scale: 0.75),legacy,"Original keeps native-sized captured artwork and its nonzero hotspot")
        let enlarged=try render(c,scale: 8)
        c.cursorUseDefaultIfAppHasLowResolution=false
        XCTAssertNotEqual(try render(c,scale: 8),enlarged,"Enlarged typed low-res art must use our sharp equivalent")
        c.cursorUseDefaultIfAppHasLowResolution=true
        c.cursorSetID = "paper"; c.cursorStyle = .recorded
        let typed = try render(c)
        c.cursorStyle = .text
        XCTAssertEqual(try render(c),typed,"Optional sidecar shape selects the matching set type")
        c.cursorVariants = ["text": .alternate]
        XCTAssertNotEqual(try render(c),typed,"Variant must participate in the GPU cache key")
        c.cursorSetID = "touch"; c.cursorVariants = [:]; c.cursorStyle = .arrow
        let released = try render(c)
        c.cursorStyle = .notAllowed
        XCTAssertEqual(try render(c),released,"Touch never becomes an arrow or a recorded-type glyph")
        c.cursorPressed = true
        let pressed = try render(c) // Click ring disabled: only the sprite changes.
        let center = (58*192+84)*4
        XCTAssertNotEqual(released.subdata(in: center..<center+3),pressed.subdata(in: center..<center+3),"Press changes the circle center, independently of the outer click ring")
        c.cursorPressed = false
        XCTAssertEqual(try render(c),released,"Releasing must reuse the correct unpressed texture")
        for style in [VectorCursorStyle.crosshair,.notAllowed] {
            c.cursorSetID = "classic"; c.cursorStyle = .init(style); c.cursorVariants = [:]
            let standard = try render(c)
            c.cursorVariants = [style.shapeID: .alternate]
            XCTAssertNotEqual(try render(c),standard)
        }
    }

    /// Circle (the default for new projects) eases a two-tone ring out of the click point and briefly presses
    /// the cursor; both must read on light and dark content. Set YAPCAM_CLICK_FRAMES_DIR to save the frames as PNGs.
    func testCircleClickRingAndPressReadOnLightAndDarkOnHost() throws {
        let device=try requireRenderDevice()
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let queue=try XCTUnwrap(device.makeCommandQueue())
        let (w,h)=(360,240)
        let target=try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,width: w,height: h,mipmapped: false)))
        let out=ProcessInfo.processInfo.environment["YAPCAM_CLICK_FRAMES_DIR"].map { URL(fileURLWithPath: $0) }
        if let out { try FileManager.default.createDirectory(at: out,withIntermediateDirectories: true) }
        func render(gray: Float,ms: Double) throws -> [UInt8] {
            var configuration=RenderConfiguration()
            configuration.cursorSetID="classic"; configuration.cursorStyle = .arrow
            configuration.cursorClickEffect = .circle; configuration.cursorClickDurationNs=400_000_000
            let source=TestSource(package: fixture,configuration: configuration) { _ in
                var frame=YcFrame(); frame.canvas_w=UInt32(w/2); frame.canvas_h=UInt32(h/2)
                frame.background_color=(gray,gray,gray,1)
                frame.cursor_visible=1; frame.cursor_opacity=1; frame.cursor_scale=1.5
                frame.cursor_x=90; frame.cursor_y=60; frame.click_x=90; frame.click_y=60
                frame.click_progress=ms<400 ? Float(ms/400) : -1
                return frame
            }
            let cb=try XCTUnwrap(queue.makeCommandBuffer())
            try FrameCompositor(device: device,project: source).encode(source.frame(atNs: 0),to: target,in: cb)
            cb.commit(); cb.waitUntilCompleted()
            XCTAssertEqual(cb.status,.completed,cb.error?.localizedDescription ?? "")
            var bytes=[UInt8](repeating: 0,count: w*h*4)
            target.getBytes(&bytes,bytesPerRow: w*4,from: MTLRegionMake2D(0,0,w,h),mipmapLevel: 0)
            if let out {
                let provider=try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
                let image=try XCTUnwrap(CGImage(width: w,height: h,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: w*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue),provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent))
                let url=out.appendingPathComponent("click-\(gray>0.5 ? "light" : "dark")-\(Int(ms))ms.png")
                let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil))
                CGImageDestinationAddImage(destination,image,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
            return bytes
        }
        func differing(_ a: [UInt8],_ b: [UInt8],rows: Range<Int>? = nil) -> Int {
            var n=0
            for y in rows ?? 0..<h { for x in 0..<w { let i=(y*w+x)*4; if (0..<3).map({ abs(Int(a[i+$0])-Int(b[i+$0])) }).max()!>12 { n+=1 } } }
            return n
        }
        // WCAG relative luminance of an sRGB BGRA pixel, and the best ring-to-background contrast ratio.
        func luminance(_ p: [UInt8],_ i: Int) -> Double {
            func lin(_ v: UInt8) -> Double { let c=Double(v)/255; return c<=0.04045 ? c/12.92 : pow((c+0.055)/1.055,2.4) }
            return 0.2126*lin(p[i+2])+0.7152*lin(p[i+1])+0.0722*lin(p[i])
        }
        func ringContrast(_ p: [UInt8]) -> Double {
            let background=luminance(p,0)
            var best=1.0
            // Left of the click point only (x < 170 px), so the cursor glyph never counts as ring.
            for y in 0..<h { for x in 0..<170 {
                let l=luminance(p,(y*w+x)*4)
                best=max(best,(max(l,background)+0.05)/(min(l,background)+0.05))
            } }
            return best
        }
        for gray: Float in [18.0/255,242.0/255] {
            let idle=try render(gray: gray,ms: 400)
            let frames=try [0.0,100,250,350].map { try render(gray: gray,ms: $0) }
            for (index,ms) in [(1,100),(2,250)] {
                let ratio=ringContrast(frames[index])
                print(String(format: "Click ring contrast on #%02X%02X%02X at +%d ms: %.2f:1",frames[index][2],frames[index][1],frames[index][0],ms,ratio))
                XCTAssertGreaterThanOrEqual(ratio,3,"ring must reach WCAG 3:1 at +\(ms) ms (gray \(gray))")
            }
            // Ring and press are clearly visible mid-flight on either background.
            XCTAssertGreaterThan(differing(frames[1],idle),200,"ring/press must be visible at +100 ms (gray \(gray))")
            XCTAssertGreaterThan(differing(frames[2],idle),100,"ring must still read at +250 ms (gray \(gray))")
            // It fades out instead of popping: later frames differ less from idle than the peak.
            XCTAssertLessThan(differing(frames[3],idle),differing(frames[1],idle))
        }
    }
}
