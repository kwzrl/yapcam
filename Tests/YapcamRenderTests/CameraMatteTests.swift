import XCTest
import Metal
import YapcamCore
@testable import YapcamRender

final class CameraMatteTests: XCTestCase {
    func testSettingsConfidenceRampAndOptionalCoreContract() throws {
        let defaults=CameraMatteSettings()
        XCTAssertEqual(defaults.edgeSoftness,0.2); XCTAssertEqual(defaults.edgeInsetPixels,0)
        XCTAssertNil(RenderConfiguration().cameraMatte)
        XCTAssertEqual(defaults.alpha(0.4),0,accuracy: 0.000001)
        XCTAssertEqual(defaults.alpha(0.5),0.5,accuracy: 0.000001)
        XCTAssertEqual(defaults.alpha(0.6),1,accuracy: 0.000001)
        XCTAssertEqual(CameraMatteSettings(edgeSoftness: 0).alpha(0.49),0)
        XCTAssertEqual(CameraMatteSettings(edgeSoftness: 0).alpha(0.5),1)
        for value in [CameraMatteSettings(edgeSoftness: .nan),CameraMatteSettings(edgeSoftness: 2),CameraMatteSettings(edgeInsetPixels: -1),CameraMatteSettings(edgeInsetPixels: 9)] { XCTAssertThrowsError(try value.validate()) }
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-matte-contract-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: fixture,to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let project=try Project.create(package: root)
        var json=try project.query("{\"q\":\"render_options_at\",\"tl_ns\":0}",as: [String:JSONValue].self)
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertNil(try decoder.decode(ProjectRenderOptions.self,from: JSONEncoder().encode(json)).cameraMatte)
        json["camera_matte"] = .object(["edge_softness":.number(0.7),"edge_inset_pixels":.number(2.5)])
        XCTAssertEqual(try decoder.decode(ProjectRenderOptions.self,from: JSONEncoder().encode(json)).cameraMatte,CameraMatteSettings(edgeSoftness: 0.7,edgeInsetPixels: 2.5))
    }
    func testMattePixelStepsAccountForCoverFaceCropMirrorAndOrientation() {
        let x=SIMD4<Float>(1,0,0,0), y=SIMD4<Float>(0,1,0,0)
        let step=CameraMatteProcessor.steps(displaySize: SIMD2(200,100),rowX: x,rowY: y,crop: SIMD4(0,0,1,1),destination: SIMD2(100,100),mirrored: false)
        XCTAssertEqual(step,SIMD4(0.005,0,0,0.01))
        let face=CameraMatteProcessor.steps(displaySize: SIMD2(200,100),rowX: x,rowY: y,crop: SIMD4(0.25,0,0.5,1),destination: SIMD2(100,100),mirrored: true)
        XCTAssertEqual(face,SIMD4(-0.005,0,0,0.01))
        let rotated=CameraMatteProcessor.steps(displaySize: SIMD2(100,200),rowX: SIMD4(0,1,0,0),rowY: SIMD4(-1,0,1,0),crop: SIMD4(0,0,1,1),destination: SIMD2(100,100),mirrored: false)
        XCTAssertEqual(rotated,SIMD4(0,-0.01,0.005,0))
    }
    func testOwnedMaskErosionHolesAndSoftnessOnHostWithoutCameraOrVision() throws {
        let device=try requireRenderDevice(), processor=try CameraMatteProcessor(device: device)
        let queue=try XCTUnwrap(device.makeCommandQueue())
        func process(_ bytes: [UInt8],_ settings: CameraMatteSettings) throws -> [UInt8] {
            let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,width: 64,height: 64,mipmapped: false)
            desc.usage = .shaderRead; desc.storageMode = .shared
            let input=try XCTUnwrap(device.makeTexture(descriptor: desc))
            bytes.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0,0,64,64),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 64) }
            let cb=try XCTUnwrap(queue.makeCommandBuffer())
            let output=try processor.encode(input,settings: settings,steps: SIMD4(1.0/64,0,0,1.0/64),in: cb)
            let buffer=try XCTUnwrap(device.makeBuffer(length: 256*64,options: .storageModeShared))
            let blit=try XCTUnwrap(cb.makeBlitCommandEncoder())
            blit.copy(from: output,sourceSlice: 0,sourceLevel: 0,sourceOrigin: MTLOrigin(x: 0,y: 0,z: 0),sourceSize: MTLSize(width: 64,height: 64,depth: 1),to: buffer,destinationOffset: 0,destinationBytesPerRow: 256,destinationBytesPerImage: 256*64)
            blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            XCTAssertEqual(cb.status,.completed,cb.error?.localizedDescription ?? "")
            let pointer=buffer.contents().assumingMemoryBound(to: UInt8.self)
            return (0..<64).flatMap { y in Array(UnsafeBufferPointer(start: pointer.advanced(by: y*256),count: 64)) }
        }
        var rectangle=[UInt8](repeating: 0,count: 64*64)
        for y in 16..<48 { for x in 16..<48 { rectangle[y*64+x]=255 } }
        let centered=try process(rectangle,.init(edgeSoftness: 0))
        XCTAssertEqual(centered,rectangle)
        let eroded=try process(rectangle,.init(edgeSoftness: 0,edgeInsetPixels: 3))
        XCTAssertEqual(eroded[32*64+18],0); XCTAssertEqual(eroded[32*64+19],255)
        XCTAssertEqual(eroded[32*64+44],255); XCTAssertEqual(eroded[32*64+45],0)
        rectangle[32*64+32]=0
        let hole=try process(rectangle,.init(edgeSoftness: 0,edgeInsetPixels: 4))
        XCTAssertEqual(hole[32*64+34],0,"Erosion must expand interior holes, not just sample its perimeter")
        let gradient=(0..<64).flatMap { _ in (0..<64).map { UInt8($0*4) } }
        let settings=CameraMatteSettings(edgeSoftness: 1)
        let softened=try process(gradient,settings)
        for x in 0..<64 { XCTAssertEqual(Double(softened[32*64+x]),Double(settings.alpha(Float(x*4)/255))*255,accuracy: 1) }
    }
}
