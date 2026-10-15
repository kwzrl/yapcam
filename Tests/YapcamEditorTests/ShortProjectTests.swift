import Testing
import Foundation
import YapcamCore
@testable import YapcamEditor

@MainActor @Suite struct ShortProjectTests {
    private func model(_ ns: Int64) -> (EditorModel, FakeProject, FakePlayer) {
        let p = FakeProject(durationNs: ns), pl = FakePlayer(); return (EditorModel(project: p, player: pl), p, pl)
    }

    @Test func itemsFitProjectsShorterThanTheDefaultMinimums() {
        for dur in [Int64(800_000_000), 250_000_000, 50_000_000] {
            let (m, _, _) = model(dur)
            m.seek(toNs: dur / 2)
            m.addZoomAtPlayhead()
            #expect(m.zooms.count == 1 && m.lastError == nil, "zoom at \(dur)")
            #expect(m.zooms[0].startNs >= 0 && m.zooms[0].endNs <= dur && m.zooms[0].endNs > m.zooms[0].startNs)
            m.seek(toNs: 0)
            m.addHighlightAtPlayhead(); m.addText(.annotation); m.addText(.caption); m.addText(.reaction, text: "🎉")
            m.addCursorHideAtPlayhead(); m.addAudioRangeAtPlayhead(track: "system_audio"); m.addBuiltInMusic(builtInMusic[0])
            #expect(m.lastError == nil, "items at \(dur): \(m.lastError ?? "")")
            #expect(m.highlights.count == 1 && m.allText.count == 3 && m.cursorHides.count == 1 && m.audioRanges.count == 1 && m.music.count == 1)
            for t in m.allText { #expect(t.endNs <= dur && t.endNs > t.startNs) }
        }
    }

    @Test func zoomInAProjectShorterThanMinimumSpansTheProject() {
        let (m, _, _) = model(200_000_000)
        m.seek(toNs: 150_000_000); m.addZoomAtPlayhead()
        #expect(m.zooms[0].startNs == 0 && m.zooms[0].endNs == 200_000_000)
        m.resizeZoom(id: m.zooms[0].id, endNs: 10)          // cannot collapse below the (project-sized) minimum
        #expect(m.zooms[0].endNs - m.zooms[0].startNs == 200_000_000)
    }

    @Test func splitSeekAndTrimAtTheEdges() {
        let (m, _, _) = model(500_000_000)
        m.seek(toNs: -5); #expect(m.playheadNs == 0)
        m.seek(toNs: 9_000_000_000); #expect(m.playheadNs == 500_000_000)
        m.splitAtPlayhead(); #expect(m.clips.count == 1)                 // boundary: no-op
        m.seek(toNs: 250_000_000); m.splitAtPlayhead(); #expect(m.clips.count == 2)
        m.seek(toNs: 0); m.trim(keepAfter: true); #expect(m.lastError != nil)
        m.lastError = nil; m.selection = .clip(m.clips[1].id); m.deleteSelection()
        #expect(m.durationNs == 250_000_000)
        m.undo(); #expect(m.durationNs == 500_000_000)
    }

    @Test func geometryAndRulerForSubSecondProjects() {
        let g = TimelineGeometry.fitting(durationNs: 400_000_000, width: 900)
        #expect(g.pixelsPerSecond <= TimelineGeometry.maxPPS && g.pixelsPerSecond > 500)
        #expect(g.rulerStepSeconds() <= 0.25)                              // labels stay readable at 10 ms granularity
        #expect(formatTimecode(400_000_000) == "0:00.40" && formatTimecode(5_000_000) == "0:00.00")
        let zero = TimelineGeometry.fitting(durationNs: 0, width: 900)
        #expect(zero.pixelsPerSecond.isFinite && zero.pixelsPerSecond > 0)
        #expect(g.contentWidth(durationNs: 400_000_000) > 100)
    }

    @Test func snappingAndSteppingInTinyProjects() {
        let (m, p, _) = model(300_000_000)
        p.clickTimesNs = [100_000_000]
        m.geometry = TimelineGeometry.fitting(durationNs: 300_000_000, width: 900)
        #expect(m.snapped(102_000_000, includePlayhead: false) == 100_000_000)       // 8 px threshold is ~1 ms here
        m.step(bySeconds: 1.0 / 30); #expect(m.playheadNs == 33_333_333)
        m.step(bySeconds: 5); #expect(m.playheadNs == 300_000_000)
    }
}

@MainActor @Suite struct ShortProjectRealCoreTests {
    private func pkg() throws -> URL {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("short-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); return d
    }

    @Test func coreAcceptsEveryItemKindInASubSecondProject() throws {
        let d = try pkg(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let m = doc.model
        try doc.project.apply(.deleteRange(startNs: 400_000_000, endNs: doc.project.durationNs))
        #expect(m.durationNs == 400_000_000)
        m.seek(toNs: 350_000_000); m.addZoomAtPlayhead()
        m.seek(toNs: 0)
        m.addHighlightAtPlayhead(); m.addText(.annotation); m.addText(.caption); m.addText(.reaction, text: "👍"); m.addCursorHideAtPlayhead()
        m.addAudioRangeAtPlayhead(track: "system_audio"); m.addBuiltInMusic(builtInMusic[1])
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.zooms.count == 1 && m.highlights.count == 1 && m.allText.count == 3 && m.music.count == 1)
        let frame = try doc.project.frame(atNs: 399_999_999)               // last frame evaluates
        #expect(frame.canvas_w > 0)
        let fx = try doc.project.effects(atNs: 100_000_000); #expect(!fx.layers.isEmpty)
        m.saveNow()
        let reopened = try EditorDocument(package: d)
        #expect(reopened.model.durationNs == 400_000_000 && reopened.model.zooms.count == 1)
    }

    @Test func subSecondProjectExports() async throws {
        let d = try pkg(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d)
        try doc.project.apply(.deleteRange(startNs: 600_000_000, endNs: doc.project.durationNs))
        doc.model.seek(toNs: 0); doc.model.addZoomAtPlayhead()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("short-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        doc.export.height = 720; doc.export.includeAudio = true
        doc.export.start(to: out); await doc.export.waitUntilFinished()
        #expect(doc.export.state == .done(out), "\(doc.export.state)")
    }
}

@MainActor @Suite struct ExportOptionsTests {
    @Test func optionsReachTheEngineAndGifDropsAudio() async {
        let engine = RecordingEngine(), e = ExportModel(engine: engine)
        #expect(ExportModel.heights == [720, 1080, 1440, 2160] && ExportModel.fpsOptions == [24, 30, 60])
        e.height = 2160; e.fps = 24; e.quality = 0.5; e.format = .mp4hevc
        e.start(to: URL(fileURLWithPath: "/tmp/a.mp4")); await e.waitUntilFinished()
        let r = engine.last!
        #expect(r.height == 2160 && r.fps == 24 && r.quality == 0.5 && r.format == .mp4hevc && r.includeAudio)
        e.reset(); e.height = 2160; e.fps = 60; e.format = .gif                      // GIF: no audio, clamped to 720p / ≤ 30 fps
        #expect(!e.includeAudio && e.height == 720 && e.fps == 24)
        e.includeAudio = true                                                          // even if re-enabled it is not requested
        e.start(to: URL(fileURLWithPath: "/tmp/a.gif")); await e.waitUntilFinished()
        #expect(engine.last!.format == .gif && !engine.last!.includeAudio && engine.last!.speech == nil)
        #expect(ExportFormat.allCases.map(\.fileExtension) == ["mp4", "mp4", "mov", "gif"])
    }

    @Test func everyFormatExportsARealSubSecondProject() async throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        for format in ExportFormat.allCases {
            let d = FileManager.default.temporaryDirectory.appendingPathComponent("fmt-\(UUID().uuidString).yapcam")
            try FileManager.default.copyItem(at: src, to: d)
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("fmt-\(UUID().uuidString).\(format.fileExtension)")
            defer { try? FileManager.default.removeItem(at: d); try? FileManager.default.removeItem(at: out) }
            let doc = try EditorDocument(package: d)
            try doc.project.apply(.deleteRange(startNs: 700_000_000, endNs: doc.project.durationNs))
            doc.export.format = format; doc.export.height = 720; doc.export.fps = 24; doc.export.quality = 0.6
            doc.export.start(to: out); await doc.export.waitUntilFinished()
            #expect(doc.export.state == .done(out), "\(format): \(doc.export.state)")
            #expect((try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0)
        }
    }
}

@MainActor @Suite struct ExportFallbackTests {
    struct AudioBreaksEngine: ExportEngine {
        func run(_ r: ExportRequest, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
            if r.includeAudio { throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "audio decode failed"]) }
            return r.destination
        }
    }
    @Test func failedAudioExportCanBeRetriedWithoutAudioToTheSameFile() async {
        let e = ExportModel(engine: AudioBreaksEngine()); let url = URL(fileURLWithPath: "/tmp/fb.mp4")
        e.start(to: url); await e.waitUntilFinished()
        #expect(e.state == .failed("audio decode failed") && e.failedWithAudio)
        e.retryWithoutAudio(); await e.waitUntilFinished()
        #expect(e.state == .done(url) && !e.includeAudio && !e.failedWithAudio)
    }
    @Test func noFallbackWhenAudioWasNotInvolved() async {
        struct Fails: ExportEngine { func run(_ r: ExportRequest, progress: @Sendable @escaping (Double) -> Void) async throws -> URL { throw NSError(domain: "t", code: 2, userInfo: [NSLocalizedDescriptionKey: "disk full"]) } }
        let e = ExportModel(engine: Fails()); e.includeAudio = false
        e.start(to: URL(fileURLWithPath: "/tmp/x.mp4")); await e.waitUntilFinished()
        #expect(!e.failedWithAudio)
        e.retryWithoutAudio(); #expect(e.state == .failed("disk full"))      // refused: nothing to retry
    }
}
