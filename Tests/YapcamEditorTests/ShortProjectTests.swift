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
    @Test func tableIsConsistentAndDefaultsFollowTheReference() {
        for f in ExportFormat.allCases {
            let o = f.options
            #expect(o.fps.contains(o.defaultFPS) && o.heights.contains(o.defaultHeight), "\(f)")
            #expect(Set(o.fps).count == o.fps.count && Set(o.heights).count == o.heights.count)
            if let d = o.defaultPreset { #expect(o.presets(atHeight: o.defaultHeight).contains(d)) }
        }
        let mp4 = ExportFormat.mp4h264.options
        #expect(mp4.defaultFPS == 60 && mp4.defaultHeight == 720 && mp4.defaultPreset == .social)      // reference defaults
        #expect(ExportFormat.gif.options.presets.isEmpty)                                              // GIF has no compression presets
        #expect(!CompressionPreset.web.isAvailable(atHeight: 2160) && !CompressionPreset.webLow.isAvailable(atHeight: 2160))
        #expect(CompressionPreset.studio.isAvailable(atHeight: 2160) && CompressionPreset.web.isAvailable(atHeight: 1080))
        #expect(CompressionPreset.allCases.map(\.quality) == CompressionPreset.allCases.map(\.quality).sorted(by: >))   // studio best … web-low smallest
    }

    @Test func modelKeepsChoicesInsideTheFormatsOptions() {
        let e = ExportModel(engine: RecordingEngine())
        #expect(e.fps == 60 && e.height == 720 && e.preset == .social && e.format == .mp4h264)
        e.height = 2160; e.preset = .web                                                               // web presets do not exist at 4K
        #expect(e.preset != .web && e.preset != .webLow && e.availablePresets == [.studio, .social])
        e.height = 1080; e.preset = .webLow; e.height = 2160
        #expect(e.availablePresets.contains(e.preset))
        e.format = .gif                                                                                 // GIF: own sets and defaults, no audio
        #expect(!e.includeAudio && e.options.fps.contains(e.fps) && e.options.heights.contains(e.height) && e.availablePresets.isEmpty)
        e.fps = 12345; #expect(e.fps == e.options.defaultFPS)                                          // unknown values snap back
        e.format = .movh264; e.height = 1440; #expect(e.height == 1440)                                // MOV keeps the extra 1440p
        e.format = .mp4h264; #expect(e.options.heights.contains(e.height))
    }

    @Test func optionsReachTheEngine() async {
        let engine = RecordingEngine(), e = ExportModel(engine: engine)
        e.format = .mp4hevc; e.height = 1080; e.fps = 30; e.preset = .studio
        e.start(to: URL(fileURLWithPath: "/tmp/a.mp4")); await e.waitUntilFinished()
        let r = engine.last!
        #expect(r.height == 1080 && r.fps == 30 && r.quality == CompressionPreset.studio.quality && r.format == .mp4hevc && r.includeAudio)
        e.reset(); e.format = .gif; e.includeAudio = true                                              // never requested for GIF
        e.start(to: URL(fileURLWithPath: "/tmp/a.gif")); await e.waitUntilFinished()
        #expect(engine.last!.format == .gif && !engine.last!.includeAudio && engine.last!.speech == nil)
        #expect(ExportFormat.allCases.map(\.fileExtension) == ["mp4", "mp4", "mov", "gif"])
    }

    /// Guards the table against render's validation: every offered fps × height of every format must export.
    @Test func everyOfferedCombinationExportsARealSubSecondProject() async throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("fmt-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d)
        try doc.project.apply(.deleteRange(startNs: 500_000_000, endNs: doc.project.durationNs))
        for format in ExportFormat.allCases {
            let o = format.options
            for height in o.heights {
                for fps in o.fps where fps == o.defaultFPS || fps == o.fps.last || height == o.defaultHeight {   // all fps at the default height, extremes elsewhere
                    let out = FileManager.default.temporaryDirectory.appendingPathComponent("fmt-\(UUID().uuidString).\(format.fileExtension)")
                    defer { try? FileManager.default.removeItem(at: out) }
                    doc.export.reset()
                    doc.export.format = format; doc.export.height = height; doc.export.fps = fps
                    if let p = o.presets(atHeight: height).last { doc.export.preset = p }
                    doc.export.includeAudio = false
                    doc.export.start(to: out); await doc.export.waitUntilFinished()
                    #expect(doc.export.state == .done(out), "\(format) \(height)p \(fps) fps: \(doc.export.state)")
                }
            }
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
