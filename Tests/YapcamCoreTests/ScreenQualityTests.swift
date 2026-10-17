import Foundation
import Testing
import YapcamCore

@Test func projectScreenQualityIsExplicitPortableAndPreservesLegacyRendering() throws {
    #expect(try JSONDecoder().decode(CoreScreenQuality.self, from: Data("{}".utf8)) == CoreScreenQuality())
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let package = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-core-quality-\(UUID().uuidString).yapcam")
    defer { try? FileManager.default.removeItem(at: package) }
    try FileManager.default.copyItem(at: fixtures.appendingPathComponent("Fixtures/synthetic/basic.yapcam"), to: package)
    let project = try Project.create(package: package)
    #expect(try project.renderOptions().screenQuality == CoreScreenQuality())
    try project.setScreenQuality(nil) // Explicit legacy/null baseline for the opt-in regression.
    #expect(try project.renderOptions().screenQuality == nil)
    let frame = try project.frame(atNs: 500_000_000)
    let snapshot = try project.snapshot()
    let selected = CoreScreenQuality(improveQuality: 0.75, upscaling: .fast)
    try project.setScreenQuality(selected)
    #expect(try project.renderOptions().screenQuality == selected)
    #expect(try project.renderOptions(atNs: 500_000_000).screenQuality == selected)
    #expect(try snapshot.renderOptions().screenQuality == nil)
    #expect(try project.frame(atNs: 500_000_000).screen_dest.w == frame.screen_dest.w)
    #expect(try project.frame(atNs: 500_000_000).screen.src_ns == frame.screen.src_ns)
    let before = try project.toJSON()
    #expect(throws: CoreError.self) { try project.setScreenQuality(.init(improveQuality: 1.1)) }
    #expect(try project.toJSON() == before)
    try project.save()
    #expect(try Project.open(package: package).renderOptions().screenQuality == selected)
    let preset = package.appendingPathComponent("quality.yapcampreset")
    try project.exportPreset(to: preset)
    try project.setScreenQuality(nil)
    #expect(try project.renderOptions().screenQuality == nil)
    try project.importPreset(from: preset)
    #expect(try project.renderOptions().screenQuality == selected)
    try project.undo(); #expect(try project.renderOptions().screenQuality == nil)
    try project.redo(); #expect(try project.renderOptions().screenQuality == selected)
    for mode in CoreScreenQuality.Upscaling.allCases {
        try project.setScreenQuality(.init(improveQuality: 0, upscaling: mode))
        #expect(try project.renderOptions().screenQuality?.upscaling == mode)
    }
    try project.setScreenQuality(nil)
    try project.save()
    #expect(try Project.open(package: package).renderOptions().screenQuality == nil)
}

@Test func insetOriginIsPortableAndKeepsCenteredLegacyDefault() throws {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let package = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-core-inset-\(UUID().uuidString).yapcam")
    defer { try? FileManager.default.removeItem(at: package) }
    try FileManager.default.copyItem(at: fixtures.appendingPathComponent("Fixtures/synthetic/basic.yapcam"), to: package)
    let project = try Project.create(package: package)
    #expect(try project.renderOptions().insetOrigin == [0,0])
    let snapshot = try project.snapshot()
    try project.apply(.set(path: "canvas.inset_origin", value: .array([.number(-1),.number(1)])))
    #expect(try project.renderOptions(atNs: 500_000_000).insetOrigin == [-1,1])
    #expect(try snapshot.renderOptions().insetOrigin == [0,0])
    let before = try project.toJSON()
    #expect(throws: CoreError.self) { try project.apply(.set(path: "canvas.inset_origin", value: .array([.number(1.1),.number(0)]))) }
    #expect(try project.toJSON() == before)
    try project.undo(); #expect(try project.renderOptions().insetOrigin == [0,0])
    try project.redo()
    try project.save()
    #expect(try Project.open(package: package).renderOptions().insetOrigin == [-1,1])
}
