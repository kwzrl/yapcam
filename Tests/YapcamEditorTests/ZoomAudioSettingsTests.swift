import Testing
import Foundation
import YapcamCore
@testable import YapcamEditor

@MainActor @Suite struct ZoomAudioSettingsTests {
    @Test func zoomAndMicPresetSettingsRoundTrip() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("za-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        m.set("zoom_settings.start_early", bool: true); m.set("zoom_settings.default_scale", number: 3)
        m.set("audio.mic_preset", string: "podcast")
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.bool("zoom_settings.start_early") && m.number("zoom_settings.default_scale", default: 2) == 3 && m.string("audio.mic_preset") == "podcast")
    }
}

@MainActor @Suite struct CheckedTimelineEditTests {
    @Test func coreRejectsTooShortItemsAndKeepsState() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ck-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        let zooms = m.zooms.count
        m.perform(.addZoom(startNs: 1_000_000_000, endNs: 1_050_000_000, scale: 2, focusX: 0.5, focusY: 0.5))   // 50 ms < 100 ms minimum
        #expect(m.lastError != nil && m.zooms.count == zooms)
        m.lastError = nil
        m.perform(.addZoom(startNs: 1_000_000_000, endNs: 2_000_000_000, scale: 2, focusX: 0.5, focusY: 0.5))
        #expect(m.lastError == nil && m.zooms.count == zooms + 1)
    }
}

@MainActor @Suite struct InsertionStyleTests {
    @Test func newZoomsInheritTheLastEditedStyle() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("is-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        m.seek(toNs: 500_000_000); m.addZoomAtPlayhead()
        guard case .zoom(let id) = m.selection else { Issue.record("no zoom selected"); return }
        m.setZoomScale(id: id, 3.5)
        m.seek(toNs: 4_000_000_000); m.addZoomAtPlayhead()
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        guard case .zoom(let second) = m.selection, let z = m.zooms.first(where: { $0.id == second }) else { Issue.record("no second zoom"); return }
        #expect(z.scale == 3.5)                                                     // remembered from the edit of the first zoom
    }
}

@MainActor @Suite struct SegmentLayoutSettingsTests {
    @Test func segmentSettingsAreStoredAndSurviveOtherLayoutEdits() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        // The fixture has no camera track, so the segment is written through the project settings like a loaded file would be.
        let id = "layout-t1"
        m.set("camera.layouts", .array([.object(["id": .string(id), "tl_start_ns": .number(500_000_000), "tl_end_ns": .number(2_500_000_000), "mode": .string("cutout")])]))
        guard m.lastError == nil else { Issue.record("core refused the layout: \(m.lastError ?? "")"); return }
        m.setLayoutOwnSettings(id: id, true); m.setLayoutSetting(id: id, key: "cutout_size", .number(0.7))
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        m.setLayoutMode(id: id, "cutout")
        #expect(m.layouts.first { $0.id == id }?.settings?["cutout_size"] == .number(0.7))
        m.setLayoutOwnSettings(id: id, false); #expect(m.layouts.first { $0.id == id }?.settings == nil)
    }
}

@MainActor @Suite struct PreviewOptionsTests {
    @Test func optionsApplyToThePlayerAndAreRemembered() {
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let player = FakePlayer()
        let m = EditorModel(project: FakeProject(), player: player); m.defaults = iso.defaults
        var o = PreviewOptions(); o.maxHeight = 720; o.resolution = 0.5; o.rate = 2; o.motionBlur = false
        m.setPreviewOptions(o)
        #expect(player.previewOptionCalls == [o] && m.previewOptions == o)
        let again = EditorModel(project: FakeProject(), player: player); again.defaults = iso.defaults
        again.loadStoredPreviewOptions()
        #expect(again.previewOptions == o && player.previewOptionCalls.last == o)           // restored on the next document
        iso.defaults.set(999, forKey: "yapcam.preview.maxHeight")                          // junk values fall back to the defaults
        let third = EditorModel(project: FakeProject(), player: player); third.defaults = iso.defaults
        third.loadStoredPreviewOptions(); #expect(third.previewOptions.maxHeight == nil)
    }
}

@MainActor @Suite struct RealPreviewOptionsTests {
    @Test func realPlayerAcceptsEveryOffer() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("po-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d)
        for h in PreviewOptions.heights { for r in PreviewOptions.resolutions { for rate in PreviewOptions.rates {
            var o = PreviewOptions(); o.maxHeight = h; o.resolution = r.value; o.rate = rate
            doc.model.setPreviewOptions(o)
            #expect(doc.model.lastError == nil, "\(h) \(r.label) \(rate): \(doc.model.lastError ?? "")")
        } } }
        var o = PreviewOptions(); o.rate = 2; o.motionBlur = false; doc.model.setPreviewOptions(o)
        #expect(doc.player.previewSettings.playbackRate == 2 && doc.player.motionBlurEnabled == false)
        doc.model.close()
    }
}

@MainActor @Suite struct ExportPlanningWiringTests {
    @Test func gifDefaultsPresetsAndEstimateComeFromRender() throws {
        #expect(ExportFormat.gif.options.defaultFPS == 15 && ExportFormat.gif.options.defaultHeight == 480)
        #expect(ExportFormat.mp4h264.options.fps == [60, 50, 30, 25, 24, 20, 10])
        let r = ExportRequest(height: 720, fps: 60, destination: URL(fileURLWithPath: "/tmp/x.mp4"), compression: .webLow)
        #expect(RenderExportEngine.settings(for: r).compression == .webLow)
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ep-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); defer { doc.model.close() }
        let e = try #require(doc.export.estimate)
        #expect(e.height == 720 && e.width % 2 == 0 && e.bytes > 0 && e.renderSeconds > 0)
        doc.export.format = .gif
        let g = try #require(doc.export.estimate)
        #expect(g.height == 720 && g.bytes > 0)      // 720p exists for GIF, so the choice is kept
    }
}

@MainActor @Suite struct ScreenStyleSettingsTests {
    @Test func screenQualityAndInsetOriginRoundTripThroughCore() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sq-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        m.set("canvas.screen_quality", .object([:]))
        m.set("canvas.screen_quality.improve_quality", number: 0.8); m.set("canvas.screen_quality.upscaling", string: "fast")
        m.set("canvas.inset_origin", .array([.number(0.5), .number(-0.25)]))
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.number("canvas.screen_quality.improve_quality") == 0.8 && m.string("canvas.screen_quality.upscaling") == "fast")
        #expect(m.numbers("canvas.inset_origin") == [0.5, -0.25])
        m.set("canvas.screen_quality", .null)
        if case .null? = m.value("canvas.screen_quality") {} else { Issue.record("screen quality should be cleared") }
        m.set("canvas.inset_origin", .array([.number(2), .number(0)]))                   // out of range is rejected by core
        #expect(m.lastError != nil && m.numbers("canvas.inset_origin") == [0.5, -0.25])
    }
}

@MainActor @Suite struct ZoomLensTests {
    @Test func glassLoupeStyleRoundTripsThroughCore() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("zl-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        m.seek(toNs: 500_000_000); m.addZoomAtPlayhead()
        guard case .zoom(let id) = m.selection else { Issue.record("no zoom"); return }
        #expect(m.zooms.first { $0.id == id }?.lens == nil)
        m.setZoomLens(id: id, ZoomLensParams(radius: 0.9, bevel: 0.4, chromaticAberration: 0.1))        // radius clamps to 0.75
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.zooms.first { $0.id == id }?.lens == ZoomLensParams(radius: 0.75, bevel: 0.4, chromaticAberration: 0.1))
        m.setZoomLens(id: id, nil); #expect(m.zooms.first { $0.id == id }?.lens == nil)
        m.undo(); #expect(m.zooms.first { $0.id == id }?.lens != nil)
    }
}

@MainActor @Suite struct MarkerTests {
    @Test func markersAreSnapTargetsAndEditPoints() {
        let p = FakeProject(durationNs: 30_000_000_000); p.markerTimesNs = [4_000_000_000, 9_000_000_000]
        let m = EditorModel(project: p, player: FakePlayer())
        #expect(m.snapTargets().filter { $0.kind == .marker }.map(\.ns) == [4_000_000_000, 9_000_000_000])
        m.seek(toNs: 1_000_000_000); #expect(m.jumpToEditPoint(forward: true) && m.playheadNs == 4_000_000_000)
        #expect(m.jumpToEditPoint(forward: true) && m.playheadNs == 9_000_000_000)
    }
}

@MainActor @Suite struct VisualRefreshTests {
    @Test func appearanceEditsKeepAudioOthersRebuildFully() async {
        let p = FakeProject(), pl = FakePlayer()
        let m = EditorModel(project: p, player: pl); m.invalidateInterval = .milliseconds(1)
        m.set("canvas.padding", number: 20)
        #expect(pl.visualInvalidations == 1)
        try? await Task.sleep(for: .milliseconds(20))
        m.set("audio.mic_muted", bool: true); await m.waitForPlayerRefresh()
        #expect(pl.visualInvalidations == 1 && pl.invalidations == 2)                 // audio edit: full rebuild
        #expect(EditorCommand.set(path: "camera.style.warmth", value: .number(1)).isVisualOnly)
        #expect(!EditorCommand.split(atNs: 5).isVisualOnly && !EditorCommand.set(path: "canvas.captions", value: .null).isVisualOnly)
        #expect(EditorCommand.set(path: "cursor.size_points", value: .number(2)).isVisualOnly)
    }
}

@MainActor @Suite struct CaptionTypographyTests {
    @Test func typographyAndWordTimingSurviveCaptionEdits() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ct-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let m = try EditorDocument(package: d, presets: iso.store).model
        m.seek(toNs: 500_000_000)
        let id = try #require(m.addText(.caption, text: "hello brave world"))
        m.setCaptionTypography("font_family", "serif"); m.setCaptionTypography("reveal", "word"); m.setCaptionTypography("language", "en-US")
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        var c = try #require(m.textItems(.caption).first { $0.id == id })
        #expect(c.extraStyle["font_family"] == .string("serif") && c.extraStyle["reveal"] == .string("word") && c.extraStyle["language"] == .string("en-US"))
        #expect(c.words.isEmpty)                                                              // untimed: core spreads words at evaluation time
        let s0 = c.startNs, step = (c.endNs - c.startNs) / 3
        m.updateText(.caption, id: id) { t in
            t.words = ["hello", "brave", "world"].enumerated().map { CaptionWord(text: $1, startNs: s0 + Int64($0) * step, endNs: s0 + Int64($0 + 1) * step) }
        }
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        c = try #require(m.textItems(.caption).first { $0.id == id })
        #expect(c.words.count == 3)
        let first = c.words[0]
        m.updateText(.caption, id: id) { $0.startNs += 100_000_000; $0.endNs += 100_000_000 }  // moving keeps the words aligned
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        c = try #require(m.textItems(.caption).first { $0.id == id })
        #expect(c.words.count == 3 && c.words[0].startNs == first.startNs + 100_000_000)
        m.updateText(.caption, id: id) { $0.text = "something else entirely" }                  // text correction drops stale timing
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        c = try #require(m.textItems(.caption).first { $0.id == id })
        #expect(c.extraStyle["font_family"] == .string("serif") && c.text == "something else entirely")
        m.setCaptionTypography("language", "not a tag!!")                                      // core validates the tag
        #expect(m.lastError != nil)
        m.close()
    }
}

@MainActor @Suite struct TranscriptExportTests {
    private func word(_ t: String, _ a: Int64, _ b: Int64) -> TextItem { TextItem.make(.caption, id: "w\(a)", start: a, end: b, text: t) }

    @Test func srtVttAndTextUseTheWordsTimelineTimes() {
        let w = [word("Hello", 1_000_000_000, 1_400_000_000), word("world.", 1_500_000_000, 2_100_000_000), word("Later", 5_000_000_000, 5_500_000_000)]
        #expect(TranscriptExporter.render(w, as: .srt) == "1\n00:00:01,000 --> 00:00:02,100\nHello world.\n\n2\n00:00:05,000 --> 00:00:05,500\nLater\n")
        #expect(TranscriptExporter.render(w, as: .vtt) == "WEBVTT\n\n00:00:01.000 --> 00:00:02.100\nHello world.\n\n00:00:05.000 --> 00:00:05.500\nLater\n")
        #expect(TranscriptExporter.render(w, as: .txt) == "Hello world.\nLater\n")
        #expect(TranscriptExporter.render([], as: .txt) == "")
    }

    @Test func exportedTimesFollowCutsAndSpeedThroughCore() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tx-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let m = try EditorDocument(package: d, presets: iso.store).model
        // Words at 3.0 s and 4.0 s of the timeline (set as a whole list like the transcript import does).
        m.writeTextList(.caption, [word("keep", 3_000_000_000, 3_400_000_000), word("later", 4_000_000_000, 4_400_000_000)])
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        m.cut([TimeSpan(startNs: 1_000_000_000, endNs: 2_000_000_000)])                 // 1 s cut before both words
        m.seek(toNs: 3_000_000_000); m.splitAtPlayhead()                                 // second clip starts at 3 s of the cut timeline
        let c2 = try #require(m.clips.last); m.setSpeed(clipID: c2.id, 2)                // 2× from there on
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        let words = m.transcriptWords
        #expect(words.count == 2 && words[0].startNs == 2_000_000_000)                  // moved earlier by the cut
        let srt = m.transcriptText(.srt)
        #expect(srt.contains("00:00:02,000 -->"))                                        // edited time, not the source 3 s
        if let second = words.last { #expect(second.startNs < 3_000_000_000 + 1_000_000_000 && second.startNs >= 2_000_000_000) }   // speed pulled it closer
        m.close()
    }
}

@MainActor @Suite struct TranscriptOptionTests {
    @Test func keytermsAreParsedRememberedAndPassedWithRegenerate() async {
        #expect(EditorModel.parseKeyterms(" Yapcam, SwiftUI ,yapcam,\n, Kilian ") == ["Yapcam", "SwiftUI", "Kilian"])
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let p = FakeProject()
        let m = EditorModel(project: p, player: FakePlayer()); m.defaults = iso.defaults
        m.keytermsText = "Yapcam, SwiftUI"; m.transcriptionLanguage = "de-DE"
        final class Box: @unchecked Sendable { var got: [(TranscriptionOptions, Bool)] = [] }
        let box = Box()
        m.captionSourceWithOptions = { o, force in box.got.append((o, force)); return Data(#"{"words":[]}"#.utf8) }
        m.generateCaptions(); await m.waitForCaptions()
        m.regenerateTranscript(); await m.waitForCaptions()
        #expect(box.got.map(\.1) == [false, true] && box.got[0].0 == TranscriptionOptions(keyterms: ["Yapcam", "SwiftUI"], language: "de-DE"))
    }
}

@MainActor @Suite struct CursorRangesTests {
    private func doc() throws -> (EditorDocument, URL) {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cr-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d)
        return (try EditorDocument(package: d, presets: EditorStorage.makeIsolated().store), d)
    }

    @Test func cursorSizeAndTogglesKeepTheirRangesAndSurviveReopen() throws {
        let (doc, d) = try doc(); defer { try? FileManager.default.removeItem(at: d) }
        let m = doc.model
        #expect(m.number("cursor.size_points") == 48 || m.value("cursor.size_points") == nil)          // new projects: 48 px default
        for px in [16.0, 64, 128] { m.set("cursor.size_points", number: px); #expect(m.lastError == nil && m.number("cursor.size_points") == px) }
        m.set("cursor.size_points", number: 129); #expect(m.lastError != nil && m.number("cursor.size_points") == 128)    // above 128 px is rejected
        m.lastError = nil
        m.set("cursor.size_points", number: 15); #expect(m.lastError != nil && m.number("cursor.size_points") == 128)     // below 16 px too
        m.lastError = nil
        for k in ["always_default", "rotate_on_move", "remove_shakes", "optimize_types"] {
            #expect(!m.bool("cursor." + k)); m.set("cursor." + k, bool: true); #expect(m.bool("cursor." + k), "\(k)")
        }
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        m.saveNow(); m.close()
        let again = try EditorDocument(package: d, presets: EditorStorage.makeIsolated().store).model
        #expect(again.number("cursor.size_points") == 128)
        for k in ["always_default", "rotate_on_move", "remove_shakes", "optimize_types"] { #expect(again.bool("cursor." + k), "\(k) after reopen") }
        again.close()
    }

    @Test func coreAcceptsAHiddenCaptionWordAndKeepsTheTranscript() throws {
        let (doc, d) = try doc(); defer { try? FileManager.default.removeItem(at: d) }
        let m = doc.model
        m.writeTextList(.caption, [TextItem.make(.caption, id: "w1", start: 1_000_000_000, end: 1_400_000_000, text: "hi")])
        m.hideWord(id: "w1")
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.transcriptWords.count == 1 && m.isHidden(m.transcriptWords[0]))
        m.unhideWord(id: "w1"); #expect(!m.isHidden(m.transcriptWords[0]))
        m.close()
    }
}
