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
