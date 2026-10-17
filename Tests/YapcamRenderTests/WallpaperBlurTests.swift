import XCTest
import ImageIO
import YapcamCore
@testable import YapcamRender

final class WallpaperBlurTests: XCTestCase {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/synthetic/basic.yapcam")
    }
    private func package() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-wallpaper-blur-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: fixture,to: url)
        return url
    }
    func testImageBlurRadiusSurvivesSnapshotAndReopenWithoutOptingIntoScreenBlur() throws {
        let root=try package()
        defer { print("Cleanup render wallpaper blur: \(root.path)"); try? FileManager.default.removeItem(at: root) }
        let project=try Project.create(package: root)
        let original=try project.renderSnapshot()
        let file=root.appendingPathComponent("image.png")
        try png(checker(),to: file)
        try project.importBackgroundImage(file)
        try project.apply(.set(path: "canvas.background.blur",value: .number(37.5)))
        let frame=try project.frame(atNs: 0)
        XCTAssertEqual(frame.background_kind,2)
        XCTAssertEqual(frame.background_blur,37.5)
        XCTAssertEqual(try original.frame(atNs: 0).background_blur,0)
        try project.save()
        XCTAssertEqual(try Project.open(package: root).frame(atNs: 0).background_blur,37.5)
    }

    func testImageAndGeneratedWallpaperBlurReduceDetailAndScaleWithCanvasOnHost() throws {
        _ = try requireRenderDevice()
        let root=try package()
        defer { print("Cleanup render wallpaper blur: \(root.path)"); try? FileManager.default.removeItem(at: root) }
        let project=try Project.create(package: root)
        // The checker is all edges; the generated wallpaper is already soft, so its detail drops less.
        for (image,factor) in [(try checker(),0.6),(try BackgroundLibrary.image(for: XCTUnwrap(BackgroundLibrary.preset(id: "golden-rings")),width: 320,height: 200),0.9)] {
            let file=root.appendingPathComponent("image.png")
            try png(image,to: file); try project.importBackgroundImage(file)
            let source=try project.renderSnapshot()
            var frame=try source.frame(atNs: 0)
            frame.screen.present=0; frame.camera.present=0; frame.cursor_visible=0
            frame.background_blur=0
            let renderer=RenderTests()
            let sharp=try renderer.pixels(frame,source: source,width: 320,height: 200)
            frame.background_blur=40
            let blurred=try renderer.pixels(frame,source: source,width: 320,height: 200)
            XCTAssertLessThan(detail(blurred,width: 320,height: 200),detail(sharp,width: 320,height: 200)*factor)
            let twice=try renderer.pixels(frame,source: source,width: 640,height: 400)
            var error=0.0
            for y in 10..<190 { for x in 10..<310 {
                for channel in 0..<3 {
                    error += abs(Double(blurred[(y*320+x)*4+channel])-Double(twice[((y*2)*640+x*2)*4+channel]))
                }
            } }
            XCTAssertLessThan(error/Double(180*300*3),2,"Blur uses canvas pixels at either export size")
            frame.background_blur=0
            XCTAssertEqual(try renderer.pixels(frame,source: source,width: 320,height: 200),sharp,"Zero retains exact original image path")
        }
    }
    private func detail(_ data: [UInt8],width: Int,height: Int) -> Double {
        var sum=0.0
        for y in 10..<(height-10) { for x in 10..<(width-11) {
            sum += abs(Double(data[(y*width+x)*4])-Double(data[(y*width+x+1)*4]))
        } }
        return sum
    }
    private func checker() throws -> CGImage {
        let width=320,height=200
        var data=[UInt8](repeating: 255,count: width*height*4)
        for y in 0..<height { for x in 0..<width {
            let value: UInt8=(x/8+y/8)%2 == 0 ? 0 : 255
            for channel in 0..<3 { data[(y*width+x)*4+channel]=value }
        } }
        return try XCTUnwrap(CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: XCTUnwrap(CGDataProvider(data: Data(data) as CFData)),decode: nil,shouldInterpolate: false,intent: .defaultIntent))
    }
    private func png(_ image: CGImage,to url: URL) throws {
        let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
