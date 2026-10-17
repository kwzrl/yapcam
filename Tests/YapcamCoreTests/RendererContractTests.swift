import Foundation
import Testing
@testable import YapcamCore

private func rendererFixture<T>(_ body: (URL) throws -> T) throws -> T {
    let input = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
    let package = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-core-renderer-\(UUID().uuidString).yapcam")
    defer { try? FileManager.default.removeItem(at: package) }
    try FileManager.default.copyItem(at: input, to: package)
    return try body(package)
}

@Test func explicitCursorReplacementBooleansCrossFFIAndPersistWithoutReinterpretingOldQueries() throws {
    try rendererFixture { package in
        let p = try Project.create(package: package)
        #expect(try p.renderOptions().cursorUseDefaultIfAppHasLowResolution == true)
        #expect(try p.renderOptions(atNs: 0).cursorAlwaysUseDefault == false)
        #expect(try p.renderOptions().backgroundWallpaperId == "deep-slate")
        #expect(try p.renderOptions().backgroundWallpaperIndex == 1)
        try p.apply(.applyPreset(["canvas": .object(["background": .object([
            "color": .array([0.1, 0.2, 0.3, 1].map(JSONValue.number))
        ])])]))
        #expect(try p.renderOptions().backgroundWallpaperId == nil)
        try p.undo()
        #expect(try p.renderOptions().backgroundWallpaperId == "deep-slate")
        let snapshot = try p.snapshot()
        try p.apply(.batch([.set(path: "cursor.use_default_if_app_has_low_resolution", value: .bool(false)), .set(path: "cursor.always_default", value: .bool(true))]))
        #expect(try p.renderOptions(atNs: 0).cursorUseDefaultIfAppHasLowResolution == false)
        #expect(try p.renderOptions(atNs: 0).cursorAlwaysUseDefault == true)
        #expect(try snapshot.renderOptions().cursorAlwaysUseDefault == false)
        try p.undo(); #expect(try p.renderOptions().cursorUseDefaultIfAppHasLowResolution == true); try p.redo()
        let before = try p.toJSON()
        #expect(throws: CoreError.self) { try p.apply(.set(path: "cursor.use_default_if_app_has_low_resolution", value: .number(1))) }
        #expect(try p.toJSON() == before)
        try p.save(); #expect(try Project.open(package: package).renderOptions() == p.renderOptions())
        try p.apply(.set(path: "cursor.always_default", value: .bool(false)))
        for shape in CoreRenderOptions.CursorShape.allCases {
            try p.apply(.set(path: "cursor.shape", value: .string(shape.rawValue)))
            #expect(try p.renderOptions().cursorShape == shape)
        }
        let data = try p.query("{\"q\":\"render_options\"}", as: JSONValue.self)
        let encoded = try JSONEncoder().encode(data)
        var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        old.removeValue(forKey: "cursor_use_default_if_app_has_low_resolution"); old.removeValue(forKey: "cursor_always_use_default")
        old.removeValue(forKey: "background_wallpaper_id"); old.removeValue(forKey: "background_wallpaper_index")
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(CoreRenderOptions.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.cursorUseDefaultIfAppHasLowResolution == nil && decoded.cursorAlwaysUseDefault == nil)
        #expect(decoded.backgroundWallpaperId == nil && decoded.backgroundWallpaperIndex == nil)
    }
}

@Test func sourcePrivacyPacketAndPurposeTagsReachTypedSwiftOnLensSnapshots() throws {
    try rendererFixture { package in
        let p = try Project.create(package: package)
        try p.apply(.batch([
            .set(path: "canvas.crop", value: .array([0.1,0.1,0.5,0.5].map(JSONValue.number))),
            .set(path: "canvas.highlights", value: .array([
                .object(["id": .string("core:caption:fake:background"), "space": .string("source"), "kind": .string("blur"), "tl_start_ns": .integer(0), "tl_end_ns": .integer(3_000_000_000), "rect": .array([0.8,0.8,0.1,0.1].map(JSONValue.number))]),
                .object(["id": .string("cover"), "space": .string("canvas"), "tl_start_ns": .integer(0), "tl_end_ns": .integer(3_000_000_000), "fill": .array([0,0,0,1].map(JSONValue.number))])
            ])),
            .addText(.caption, .init(id: "words", startNs: 0, endNs: 2_000_000_000, text: "Caption", style: try p.captionDefaults()))
        ]))
        var lens = ZoomSpec(startNs: 0, endNs: 3_000_000_000, target: [0.4,0.4], easeInNs: 0, easeOutNs: 0)
        lens.style = "lens"; try p.apply(.addZoom(lens))
        let packet = try p.privacyMasks(atNs: 500_000_000)
        let frame = try p.frame(atNs: 500_000_000)
        #expect(packet.schemaVersion == 1 && packet.tlNs == 500_000_000)
        var future = try p.query("{\"q\":\"privacy_masks_at\",\"tl_ns\":500000000}", as: JSONValue.self)
        if case .object(var fields) = future { fields["schema_version"] = .number(2); future = .object(fields) }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        #expect(throws: (any Error).self) { try decoder.decode(CorePrivacyMaskFrame.self, from: JSONEncoder().encode(future)) }
        #expect(packet.screen.present && packet.screen.srcNs == frame.screen.src_ns)
        #expect(packet.screen.fileNs == frame.screen.file_ns && packet.screen.segment == frame.screen.segment)
        #expect(packet.masks.count == 2 && packet.masks[0].space == .source && packet.masks[1].space == .canvas)
        #expect(packet.masks[0].rect == [0.8,0.8,0.1,0.1] && packet.masks[0].blurRadius == 32)
        #expect(packet.masks[0].purpose == .privacyMask && packet.masks[1].order == 1)
        #expect(try p.effects(atNs: 500_000_000).privacyMasks == packet)
        let layers = try p.renderLayers(atNs: 500_000_000)
        #expect(layers.first(where: { $0.id == "cover" })?.purpose == .privacyMask)
        #expect(layers.first(where: { $0.id == "core:caption:words:background" })?.purpose == .textBackground)
        #expect(!layers.contains { $0.id == "core:caption:fake:background" }) // outside base crop, still in source packet
        let snapshot = try p.snapshot()
        try p.apply(.deleteRange(startNs: 0, endNs: 500_000_000))
        #expect(try snapshot.privacyMasks(atNs: 500_000_000) == packet)
        try p.undo(); #expect(try p.privacyMasks(atNs: 500_000_000) == packet)
        try p.save(); #expect(try Project.open(package: package).privacyMasks(atNs: 500_000_000) == packet)
        let before = try p.toJSON()
        #expect(throws: CoreError.self) { try p.apply(.set(path: "canvas.highlights.0.purpose", value: .string("text_background"))) }
        #expect(try p.toJSON() == before)
        #expect(throws: CoreError.self) { try p.privacyMasks(atNs: -1) }
    }
}


@Test func factoryMirrorCorrectionPreservesSavedRevisionTwoAndLegacyMissingValues() throws {
    try rendererFixture { package in
        let p = try Project.create(package: package)
        #expect(try p.frame(atNs: 0).camera_mirror == 0)
        try p.apply(.insertTimelineItem(.mask))
        #expect(try p.maskEffects(atNs: 0).effects[0].kind == 1)
        #expect(try p.insertionStyles().mask?.kind == "blur")
        try p.apply(.set(path: "camera.mirrored", value: .bool(true)))
        try p.save()
        #expect(try Project.open(package: package).frame(atNs: 0).camera_mirror == 1)
        var raw = try JSONSerialization.jsonObject(with: p.toJSON()) as! [String: Any]
        #expect(raw["defaults_revision"] as? Int == 3)
        var camera = raw["camera"] as! [String: Any]; camera.removeValue(forKey: "mirrored"); raw["camera"] = camera
        try JSONSerialization.data(withJSONObject: raw).write(to: package.appendingPathComponent("project.json"))
        #expect(try Project.open(package: package).frame(atNs: 0).camera_mirror == 1)
    }
}
