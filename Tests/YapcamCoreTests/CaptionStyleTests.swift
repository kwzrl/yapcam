import Foundation
import Testing
import YapcamCore

private func withCaptionFixture(_ body: (URL, Project) throws -> Void) throws {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let package = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-core-caption-\(UUID().uuidString).yapcam")
    defer { try? FileManager.default.removeItem(at: package) }
    try FileManager.default.copyItem(at: fixtures.appendingPathComponent("Fixtures/synthetic/basic.yapcam"), to: package)
    try body(package, Project.create(package: package))
}

@Test func captionStylesAndWordPhasesRoundTripWithTypedSwiftAPI() throws {
    try withCaptionFixture { package, project in
        let style = TextStyle(fontFamily: .serif, reveal: .word, growth: .expanding, entrance: .fade, language: "de-DE")
        let record = TextEffectRecord(startNs: 0, endNs: 2_000_000_000, text: "Hallo Welt", style: style, words: [
            CaptionWord(text: "Hallo", startNs: 200_000_000, endNs: 600_000_000),
            CaptionWord(text: "Welt", startNs: 1_200_000_000, endNs: 1_600_000_000)
        ])
        let id = try #require(project.apply(.addText(.caption, record)).createdIDs.first)
        let options = try project.captionOptions()
        #expect(options.fontFamilies == TextStyle.FontFamily.allCases)
        #expect(options.revealModes == TextStyle.Reveal.allCases)
        #expect(options.growthModes == TextStyle.Growth.allCases)
        #expect(options.entrances == TextStyle.Entrance.allCases)
        #expect(options.language.automatic == "auto" && options.language.supportedLocalesRequireCapture)
        let saved = try #require(project.textEffects(.caption).first)
        #expect(saved.style == style && saved.words == record.words)
        let layer = try #require(project.renderLayers(atNs: 1_300_000_000).first { $0.id == "core:caption:\(id)" })
        let evaluated = try #require(layer.caption)
        #expect(layer.fontFamily == .serif && layer.text == "Hallo Welt")
        #expect(evaluated.fontFamily == .serif && evaluated.reveal == .word && evaluated.growth == .expanding)
        #expect(evaluated.words[0].opacity == 1 && evaluated.words[1].opacity == 0.5)
        #expect(evaluated.words[1].tlStartNs == 1_200_000_000)
        #expect(try !project.renderLayers(atNs: 199_999_999).contains { $0.id == "core:caption:\(id)" })
        let snapshot = try project.snapshot()
        try project.apply(.updateText(.caption, id: id, patch: ["text":.string("corrected words")]))
        #expect(try project.textEffects(.caption)[0].words.isEmpty)
        #expect(try snapshot.textEffects(.caption)[0] == saved)
        try project.undo(); #expect(try project.textEffects(.caption)[0] == saved)
        try project.redo(); #expect(try project.textEffects(.caption)[0].words.isEmpty)
        try project.undo()
        try project.save()
        #expect(try Project.open(package: package).textEffects(.caption) == [saved])
        let before = try project.toJSON()
        #expect(throws: CoreError.self) {
            try project.apply(.updateText(.caption, id: id, patch: ["style":.object(["font_family":.string("unavailable-font")])]))
        }
        #expect(try project.toJSON() == before)
    }
}

@Test func legacyCaptionStylesDecodeWithUnchangedAppearanceAndCaptureLanguageIsRetained() throws {
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let legacy = Data(#"{"id":"old","tl_start_ns":0,"tl_end_ns":1000000000,"text":"older caption","rect":[0.1,0.75,0.8,0.15],"space":"canvas","style":{"font_size":36,"color":[1,1,1,1],"background":[0,0,0,0.65],"radius":12,"opacity":1}}"#.utf8)
    let record = try decoder.decode(TextEffectRecord.self, from: legacy)
    #expect(record.style == TextStyle() && record.words.isEmpty)
    try withCaptionFixture { _, project in
        let transcript = Data(#"{"schema_version":1,"locale":"zh-Hans-CN","words":[{"text":"你好","src_start_ns":100000000,"src_end_ns":800000000}]}"#.utf8)
        try project.importTranscript(transcript)
        let row = try #require(project.textEffects(.caption).first)
        #expect(row.style.language == "zh-Hans-CN" && row.style.reveal == .line && row.style.growth == .expanding && row.style.fontSizeRatio == 0.05)
        #expect(row.words == [CaptionWord(text: "你好", startNs: row.tlStartNs, endNs: row.tlEndNs)])
        let layer = try #require(project.renderLayers(atNs: 200_000_000).first { $0.kind == "text" && $0.caption != nil })
        #expect(layer.text == "你好" && layer.opacity == 1 && layer.caption?.lineOffsetY == 0)
    }
}

@Test func captionWordTimingsFollowRealSpeedAndCutCommands() throws {
    try withCaptionFixture { _, project in
        let caption = TextEffectRecord(startNs: 0, endNs: 3_000_000_000, text: "one two three", style: TextStyle(reveal: .word), words: [
            .init(text: "one", startNs: 0, endNs: 1_000_000_000),
            .init(text: "two", startNs: 1_000_000_000, endNs: 2_000_000_000),
            .init(text: "three", startNs: 2_000_000_000, endNs: 3_000_000_000)
        ])
        try project.apply(.addText(.caption, caption))
        try project.apply(.split(atNs: 1_000_000_000))
        let clip = try project.query("{\"q\":\"clips\"}", as: [ClipInfo].self)[1]
        try project.apply(.setSpeed(clipID: clip.id, speed: 2))
        #expect(try project.textEffects(.caption)[0].words[2].tlStartNs == 1_500_000_000)
        try project.apply(.deleteRange(startNs: 1_000_000_000, endNs: 1_500_000_000))
        #expect(try project.textEffects(.caption)[0].text == "one three")
        try project.undo()
        #expect(try project.textEffects(.caption)[0].text == "one two three")
    }
}
