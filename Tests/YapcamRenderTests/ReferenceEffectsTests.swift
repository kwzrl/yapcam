import XCTest
import CoreGraphics
import YapcamCore
@testable import YapcamRender

final class ReferenceEffectsTests: XCTestCase {
    func testLoupeGeometryDefaultsCropAndValidation() throws {
        let settings = GlassLoupeSettings()
        XCTAssertEqual(settings.radius,0.35); XCTAssertEqual(settings.bevel,0.2); XCTAssertEqual(settings.chromaticAberration,0.5)
        var f = frame()
        f.screen.present = 1; f.screen_crop = .init(x: 0.25,y: 0.25,w: 0.5,h: 0.5)
        let g = settings.geometry(f)
        XCTAssertEqual(g.focus,SIMD2(0.5,0.5)); XCTAssertEqual(g.scale,2); XCTAssertEqual(g.radius,70); XCTAssertEqual(g.opacity,1)
        let crop = GlassLoupeSettings(baseCrop: SIMD4(0.25,0.25,0.5,0.5))
        f.screen_crop = .init(x: 0.375,y: 0.375,w: 0.25,h: 0.25)
        XCTAssertEqual(crop.geometry(f).scale,2)
        f.screen_crop = .init(x: 0.25,y: 0.25,w: 0.5,h: 0.5)
        XCTAssertEqual(crop.geometry(f).opacity,0)
        var config = RenderConfiguration(); config.glassLoupe = crop
        XCTAssertNoThrow(try validateFrame(f,configuration: config))
        f.screen_crop = .init(x: 0,y: 0,w: 0.5,h: 0.5)
        XCTAssertThrowsError(try validateFrame(f,configuration: config))
        for settings in [GlassLoupeSettings(radius: 0.1),GlassLoupeSettings(bevel: .nan),GlassLoupeSettings(chromaticAberration: 2)] { XCTAssertThrowsError(try settings.validate()) }
    }
    func testLoupeRejectsCoverMasksButPreservesFullCanvasFades() throws {
        var f = frame(); f.screen.present = 1; f.screen_crop = .init(x: 0,y: 0,w: 1,h: 1)
        var config = RenderConfiguration(); config.glassLoupe = .init()
        var mask = RenderLayer(content: .highlight(dimOpacity: 0,fill: SIMD4(0,0,0,1),stroke: .zero,strokeWidth: 0),rect: CGRect(x: 30,y: 30,width: 100,height: 100))
        XCTAssertThrowsError(try validateFrame(f,configuration: config,layers: [mask]))
        mask.rect = CGRect(x: 0,y: 0,width: 320,height: 200)
        XCTAssertNoThrow(try validateFrame(f,configuration: config,layers: [mask]))
        config.glassLoupe = nil; mask.rect = CGRect(x: 30,y: 30,width: 100,height: 100)
        XCTAssertNoThrow(try validateFrame(f,configuration: config,layers: [mask]))
    }
    func testCubeOrderingTrilinearSamplingDomainAndInvalidInputs() throws {
        // Both imported modules expose CubeLUT; this suite exercises Render's parser.
        let identity = try YapcamRender.CubeLUT(data: cube())
        XCTAssertEqual(identity.dimension,2)
        for r in 0...10 { for g in 0...10 { for b in 0...10 {
            let color = SIMD3<Float>(Float(r)/10,Float(g)/10,Float(b)/10)
            let output = try identity.sample(color)
            for i in 0..<3 { XCTAssertEqual(output[i],color[i],accuracy: 0.000001) }
        } } }
        let swapped = try YapcamRender.CubeLUT(data: cube(swap: true,domain: true))
        let c = try swapped.sample(SIMD3<Float>(-0.5,0,0.5))
        XCTAssertEqual(c.x,0.75,accuracy: 0.000001); XCTAssertEqual(c.y,0.5,accuracy: 0.000001); XCTAssertEqual(c.z,0.25,accuracy: 0.000001)
        XCTAssertThrowsError(try identity.sample(SIMD3<Float>(Float.nan,0,0)))
        let invalid = [Data(),Data([0xff]),Data("LUT_1D_SIZE 2".utf8),Data("LUT_3D_SIZE 66".utf8),Data("LUT_3D_SIZE 2\nNaN 0 0".utf8),Data("LUT_3D_SIZE 2\nLUT_3D_SIZE 2".utf8),cube()+Data("0 0 0\n".utf8),Data(repeating: 32,count: 32*1024*1024+1)]
        for data in invalid { XCTAssertThrowsError(try YapcamRender.CubeLUT(data: data)) }
        let badDomain = String(decoding: cube(),as: UTF8.self).replacingOccurrences(of: "LUT_3D_SIZE 2",with: "DOMAIN_MIN 1 1 1\nDOMAIN_MAX 0 0 0\nLUT_3D_SIZE 2")
        XCTAssertThrowsError(try YapcamRender.CubeLUT(data: Data(badDomain.utf8)))
    }
    func testCubeImportIsImmutableDeduplicatedAndCannotEscapeProject() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("project.yapcam")
        try FileManager.default.createDirectory(at: package,withIntermediateDirectories: true)
        let selected = root.appendingPathComponent("selected.cube"), original = cube()
        try original.write(to: selected)
        let first = try YapcamRender.CubeLUT.importFile(selected,into: package), second = try YapcamRender.CubeLUT.importFile(selected,into: package)
        XCTAssertEqual(first,second); XCTAssertTrue(first.hasPrefix("assets/luts/")); XCTAssertFalse(first.hasPrefix("/"))
        XCTAssertEqual(try Data(contentsOf: selected),original)
        let asset = package.appendingPathComponent(first)
        XCTAssertEqual(try YapcamRender.CubeLUT(contentsOf: asset).dimension,2)
        try Data("corrupted existing asset".utf8).write(to: asset)
        XCTAssertThrowsError(try YapcamRender.CubeLUT.importFile(selected,into: package))
        let escaped = root.appendingPathComponent("escape.yapcam"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: escaped,withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside,withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: escaped.appendingPathComponent("assets"),withDestinationURL: outside)
        XCTAssertThrowsError(try YapcamRender.CubeLUT.importFile(selected,into: escaped))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testOwnCameraCatalogAndColorBlend() throws {
        XCTAssertEqual(CameraColorLibrary.presets.count,12)
        XCTAssertEqual(Set(CameraColorLibrary.presets.map(\.id)).count,12)
        var signatures = Set<[Float]>()
        let colors: [SIMD3<Float>] = [SIMD3(0.2,0.4,0.7),SIMD3(0.8,0.3,0.1)]
        for preset in CameraColorLibrary.presets {
            let settings = CameraColorSettings(presetID: preset.id)
            let signature = try colors.flatMap { color -> [Float] in let c = try settings.transform(color); return [c.x,c.y,c.z] }
            XCTAssertTrue(signatures.insert(signature).inserted)
            let bypassed = try CameraColorSettings(presetID: preset.id,intensity: 0).transform(colors[0])
            XCTAssertEqual(bypassed,colors[0])
        }
        let mono = try CameraColorSettings(presetID: "graphite").transform(colors[0])
        XCTAssertEqual(mono.x,mono.y,accuracy: 0.000001); XCTAssertEqual(mono.y,mono.z,accuracy: 0.000001)
        for settings in [CameraColorSettings(presetID: "unknown"),CameraColorSettings(intensity: .nan),CameraColorSettings(sharpen: 2),CameraColorSettings(contrast: -2)] { XCTAssertThrowsError(try settings.validate()) }
        XCTAssertFalse(CameraColorSettings().isEnabled)
    }
    func testEvaluatedQueryOptionalEffectsContractWithoutChangingFrameABI() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let package = try fixture(in: root)
        let project = try Project.create(package: package)
        var json = try project.query("{\"q\":\"render_options_at\",\"tl_ns\":0}",as: [String:JSONValue].self)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let legacy = try decoder.decode(ProjectRenderOptions.self,from: JSONEncoder().encode(json))
        XCTAssertNil(legacy.glassLoupe); XCTAssertNil(legacy.cameraColor)
        json["glass_loupe"] = .object(["radius":.number(0.4),"base_crop":.array([0.25,0.25,0.5,0.5].map(JSONValue.number))])
        json["camera_color"] = .object(["preset_id":.string("honey"),"intensity":.number(0.6),"sharpen":.number(0.2)])
        let selected = try decoder.decode(ProjectRenderOptions.self,from: JSONEncoder().encode(json))
        XCTAssertEqual(selected.glassLoupe?.radius,0.4); XCTAssertEqual(selected.glassLoupe?.baseCrop,SIMD4(0.25,0.25,0.5,0.5))
        let color = try XCTUnwrap(selected.cameraColor).value(package: package)
        XCTAssertEqual(color.presetID,"honey"); XCTAssertEqual(color.intensity,0.6); XCTAssertEqual(color.sharpen,0.2)
        json["camera_color"] = .object(["lut_path":.string("../../outside.cube")])
        let invalid = try decoder.decode(ProjectRenderOptions.self,from: JSONEncoder().encode(json))
        XCTAssertThrowsError(try invalid.cameraColor?.value(package: package))
    }
    func testLoupeKeepsOutsidePixelsUnzoomedAndMagnifiesInsideOnHost() throws {
        _ = try requireRenderDevice()
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let package = try fixture(in: root)
        var f = frame(); f.screen.present = 1; f.screen.segment = 0; f.screen.file_ns = 500_000_000
        f.screen_crop = .init(x: 0,y: 0,w: 1,h: 1)
        let base = try pixels(f,package: package)
        f.screen_crop = .init(x: 0.25,y: 0.25,w: 0.5,h: 0.5)
        let classic = try pixels(f,package: package)
        var config = RenderConfiguration(); config.glassLoupe = .init(radius: 0.25,bevel: 0,chromaticAberration: 0)
        let lens = try pixels(f,package: package,configuration: config)
        for (x,y) in [(10,10),(310,190),(30,170)] { for c in 0..<3 { XCTAssertEqual(Int(lens[(y*320+x)*4+c]),Int(base[(y*320+x)*4+c]),accuracy: 1) } }
        for (x,y) in [(160,100),(150,100),(160,110)] { for c in 0..<3 { XCTAssertEqual(Int(lens[(y*320+x)*4+c]),Int(classic[(y*320+x)*4+c]),accuracy: 2) } }
        XCTAssertNotEqual(lens,base)
        config.glassLoupe = .init(radius: 0.25)
        XCTAssertNotEqual(try pixels(f,package: package,configuration: config),lens)
    }
    func testCameraGradesLUTAndStrengthUseSharedCompositorOnHost() throws {
        _ = try requireRenderDevice()
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let package = try fixture(in: root,camera: true)
        var f = frame(); f.camera.present = 1; f.camera.segment = 0; f.camera.file_ns = 500_000_000; f.camera_dest = f.screen_dest; f.camera_opacity = 1
        let original = try pixels(f,package: package)
        for preset in CameraColorLibrary.presets {
            var config = RenderConfiguration(); config.cameraColor = .init(presetID: preset.id)
            let graded = try pixels(f,package: package,configuration: config)
            for (x,y) in [(80,80),(160,100),(230,140)] {
                let i = (y*320+x)*4
                let input = SIMD3(Float(original[i]),Float(original[i+1]),Float(original[i+2]))/255
                let expected = try config.cameraColor.transform(input)
                for channel in 0..<3 { XCTAssertEqual(Float(graded[i+channel]),expected[channel]*255,accuracy: 4,preset.id) }
            }
        }
        let url = root.appendingPathComponent("swap.cube"); try cube(swap: true).write(to: url)
        var config = RenderConfiguration(); config.cameraColor = .init(lutURL: url)
        let swapped = try pixels(f,package: package,configuration: config)
        for (x,y) in [(80,80),(160,100),(230,140)] {
            let i = (y*320+x)*4
            XCTAssertEqual(Int(swapped[i]),Int(original[i+2]),accuracy: 3)
            XCTAssertEqual(Int(swapped[i+2]),Int(original[i]),accuracy: 3)
        }
        config.cameraColor.intensity = 0
        XCTAssertEqual(try pixels(f,package: package,configuration: config),original)
        config.cameraColor = .init(sharpen: 0.8,grain: 0.3)
        XCTAssertNotEqual(try pixels(f,package: package,configuration: config),original)
    }
    private func frame() -> YcFrame {
        var f = YcFrame(); f.canvas_w = 320; f.canvas_h = 200; f.screen_dest = .init(x: 0,y: 0,w: 320,h: 200); f.click_progress = -1; f.background_color = (0,0,0,1); return f
    }
    private func cube(swap: Bool = false, domain: Bool = false) -> Data {
        var s = "# Our synthetic regression cube\nTITLE \"Synthetic\"\nLUT_3D_SIZE 2\n"
        if domain { s += "DOMAIN_MIN -1 -1 -1\nDOMAIN_MAX 1 1 1\n" }
        for b in 0...1 { for g in 0...1 { for r in 0...1 { s += swap ? "\(b) \(g) \(r)\n" : "\(r) \(g) \(b)\n" } } }
        return Data(s.utf8)
    }
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-reference-effects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true); return root
    }
    private func fixture(in root: URL,camera: Bool = false) throws -> URL {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let package = root.appendingPathComponent("fixture.yapcam"); try FileManager.default.copyItem(at: source,to: package)
        if camera {
            let url = package.appendingPathComponent("recording/session.json")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String:Any])
            var segments = try XCTUnwrap(json["segments"] as? [[String:Any]])
            var files = try XCTUnwrap(segments[0]["files"] as? [String:String]); files["camera"] = files["screen"]; segments[0]["files"] = files
            json["segments"] = segments; try JSONSerialization.data(withJSONObject: json).write(to: url)
        }
        return package
    }
    private func pixels(_ f: YcFrame,package: URL,configuration: RenderConfiguration = .init()) throws -> [UInt8] {
        let source = TestSource(package: package,configuration: configuration)
        let compositor = try FrameCompositor(device: requireRenderDevice(),project: source)
        return try GIFPalette.rgba(compositor.image(f))
    }
}
