import Testing
import Foundation
import YapcamCore
import YapcamRender
import AVFoundation
@testable import YapcamEditor

private func pkgCopy2() throws -> URL {
    let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("r2-\(UUID().uuidString).yapcam")
    try FileManager.default.copyItem(at: src, to: d); return d
}

/// Finding 1: background work belongs to one document instance.
@MainActor @Suite struct DocumentLifetimeTests {
    private func make() -> (EditorModel, FakeProject) {
        let p = FakeProject(durationNs: 20_000_000_000); return (EditorModel(project: p, player: FakePlayer()), p)
    }

    @Test func closingCancelsASlowMusicImportAndNothingIsApplied() async throws {
        let (m, p) = make(); p.importDelay = .seconds(5)
        m.importMusicFile(URL(fileURLWithPath: "/tmp/x.m4a"))
        m.close()
        await m.waitForMusicImport()
        #expect(p.importedMusic.isEmpty && m.music.isEmpty && m.lastError == nil)
        #expect(m.isClosed)
    }

    @Test func closingCancelsAWallpaperAndClearsBusy() async throws {
        let (m, p) = make(); p.wallpaperDelay = .seconds(5)
        m.applyWallpaper(id: "boreal-glow"); #expect(m.wallpaperBusy == "boreal-glow")
        m.close()
        await m.waitForWallpaper()
        #expect(p.appliedWallpapers.isEmpty && m.wallpaperBusy == nil && m.lastError == nil)
    }

    @Test func closingDiscardsCaptionAndSilenceResults() async throws {
        let (m, p) = make()
        m.captionSource = { try await Task.sleep(for: .seconds(5)); return Data(#"{"words":[]}"#.utf8) }
        m.generateCaptions()
        p.silenceDelay = .seconds(5); m.findSilences()
        m.close()
        await m.waitForCaptions(); await m.waitForSilenceAnalysis()
        #expect(p.importedTranscripts == 0 && m.silenceState == .analyzing)    // nothing was published after close
    }

    @Test func closedModelRefusesEditsAndSaves() {
        let (m, p) = make()
        m.addZoomAtPlayhead(); m.close()                  // close saves pending edits first
        #expect(p.saveCount == 1 && m.saveState == .clean)
        let zooms = m.zooms.count
        m.addZoomAtPlayhead(); m.set("canvas.padding", number: 5); m.undo()
        m.saveNow()
        #expect(m.zooms.count == zooms && p.saveCount == 1 && m.number("canvas.padding") != 5)
        m.importMusicFile(URL(fileURLWithPath: "/tmp/y.m4a"))
        #expect(m.music.isEmpty)
    }

    @Test func staleModelCannotJournalOverAReopenedDocument() async throws {
        let d = try pkgCopy2(); defer { try? FileManager.default.removeItem(at: d) }
        let first = try EditorDocument(package: d)
        first.model.set("canvas.padding", number: 41); first.model.saveNow()
        first.model.close()                                      // window closed
        let second = try EditorDocument(package: d)             // reopened
        second.model.set("canvas.padding", number: 77); second.model.saveNow()
        // Late work on the stale instance does nothing: no edit, no save, no journal.
        first.model.set("canvas.padding", number: 12); first.model.addZoomAtPlayhead(); first.model.saveNow()
        first.model.applyWallpaper(id: "quiet-dawn"); await first.model.waitForWallpaper()
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("autosave/project.json").path))
        let verify = try EditorDocument(package: d)
        #expect(verify.model.number("canvas.padding") == 77 && verify.model.zooms.isEmpty)
    }
}

/// Finding 3: music and click sounds must reach preview and export.
@MainActor @Suite struct AudioOverlayForwardingTests {
    @Test func renderSourceCarriesMusicAndClickSounds() throws {
        let d = try pkgCopy2(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let m = doc.model
        m.seek(toNs: 500_000_000); m.addBuiltInMusic(builtInMusic[0])
        m.set("audio.click_sound.enabled", bool: true); m.set("audio.click_sound.variant", string: "crisp")
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        let source = ProjectRenderSource(doc.project)
        func kinds(_ o: [AudioOverlay]) -> (music: Bool, click: Bool) {
            (o.contains { if case .music(.calm) = $0.source { true } else { false } },
             o.contains { if case .click(.crisp) = $0.source { true } else { false } })
        }
        let overlays = try source.renderAudioOverlays()
        let direct = kinds(overlays)
        #expect(direct.music && direct.click, "\(overlays)")
        // Export and preview use a snapshot: it must carry the same overlays.
        let snap = kinds(try source.renderSnapshot().renderAudioOverlays())
        #expect(snap.music && snap.click)
        // And the overlays match what core evaluates.
        let coreCount = try doc.project.audioOverlays().count
        #expect(overlays.count == coreCount)
    }

    @Test func disablingClickSoundsRemovesThem() throws {
        let d = try pkgCopy2(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d)
        let source = ProjectRenderSource(doc.project)
        let none = try source.renderAudioOverlays(); #expect(none.isEmpty)
        doc.model.set("audio.click_sound.enabled", bool: true)
        let some = try source.renderAudioOverlays(); #expect(!some.isEmpty)
        doc.model.set("audio.click_sound.enabled", bool: false)
        let gone = try source.renderAudioOverlays(); #expect(gone.isEmpty)
    }
}

/// Finding 6: overlapping chips.
@Suite struct LaneHitTestTests {
    private let g = TimelineGeometry(pixelsPerSecond: 100)
    private func item(_ id: String, _ a: Int64, _ b: Int64) -> LaneHitTest.Item {
        .init(key: id, span: TimeSpan(startNs: a, endNs: b), top: 100, tag: .highlight(id))
    }
    @Test func laterOverlappingItemWins() {
        let items = [item("first", 1_000_000_000, 4_000_000_000), item("second", 1_000_000_000, 4_000_000_000)]
        let hit = LaneHitTest.topmost(x: 250, y: 110, items: items, preview: [:], geometry: g)
        #expect(hit?.key == "second" && hit?.tag == .highlight("second"))
        if case .body? = hit?.part {} else { Issue.record("expected body hit") }
    }
    @Test func partialOverlapPicksTheVisibleChipAndFallsThroughOutsideIt() {
        let items = [item("a", 0, 3_000_000_000), item("b", 2_000_000_000, 5_000_000_000)]
        #expect(LaneHitTest.topmost(x: 250, y: 110, items: items, preview: [:], geometry: g)?.key == "b")   // overlap: b is on top
        #expect(LaneHitTest.topmost(x: 100, y: 110, items: items, preview: [:], geometry: g)?.key == "a")   // only a here
        #expect(LaneHitTest.topmost(x: 100, y: 10, items: items, preview: [:], geometry: g) == nil)        // other lane
        #expect(LaneHitTest.topmost(x: 600, y: 110, items: items, preview: [:], geometry: g) == nil)
    }
    @Test func edgesAndDragPreviewAreRespected() {
        let items = [item("a", 1_000_000_000, 4_000_000_000)]
        #expect(LaneHitTest.topmost(x: 101, y: 110, items: items, preview: [:], geometry: g)?.part == .start)
        #expect(LaneHitTest.topmost(x: 399, y: 110, items: items, preview: [:], geometry: g)?.part == .end)
        // While dragging, hit-testing follows the previewed span.
        #expect(LaneHitTest.topmost(x: 250, y: 110, items: items, preview: ["a": (6_000_000_000, 8_000_000_000)], geometry: g) == nil)   // old spot is empty
        #expect(LaneHitTest.topmost(x: 650, y: 110, items: items, preview: ["a": (6_000_000_000, 8_000_000_000)], geometry: g)?.key == "a")
    }
}

/// Finding 7: captions are not zoom-sized.
@MainActor @Suite struct CaptionTrimTests {
    @Test func captionCanBeTrimmedToWordLength() {
        let m = EditorModel(project: FakeProject(durationNs: 20_000_000_000), player: FakePlayer())
        m.seek(toNs: 1_000_000_000)
        let id = m.addText(.caption, text: "word")!
        m.updateText(.caption, id: id) { $0.startNs = 1_000_000_000; $0.endNs = 1_100_000_000 }
        let t = m.textItems(.caption)[0], key = EditorModel.textKey(t)
        m.previewRange(key: key, current: t.span, endNs: 1_150_000_000); m.commitRange(key: key)
        #expect(m.textItems(.caption)[0].endNs == 1_150_000_000)                 // not forced to 1.30 s
        m.previewRange(key: key, current: m.textItems(.caption)[0].span, endNs: 1_000_000_001); m.commitRange(key: key)
        #expect(m.textItems(.caption)[0].endNs - m.textItems(.caption)[0].startNs == 20_000_000)   // floor: 20 ms
        m.previewRange(key: key, current: m.textItems(.caption)[0].span, startNs: 5_000_000_000)
        #expect(m.zoomPreview[key]!.end - m.zoomPreview[key]!.start == 20_000_000)
    }
    @Test func zoomsAndOtherItemsKeepTheirMinimums() {
        let m = EditorModel(project: FakeProject(durationNs: 20_000_000_000), player: FakePlayer())
        m.addZoomAtPlayhead(); let z = m.zooms[0]
        m.previewZoom(id: z.id, endNs: z.startNs + 1)
        #expect(m.zoomPreview[z.id]!.end - m.zoomPreview[z.id]!.start == minZoomDurationNs)
        let id = m.addText(.annotation)!
        #expect(m.minDurationNs(forKey: EditorModel.textKey(m.textItems(.annotation).first { $0.id == id }!)) == 100_000_000)
        #expect(m.minDurationNs(forKey: "layout-x") == minZoomDurationNs)
    }
}

/// Core `Project.close()` removes the residual window of finding #1.
@MainActor @Suite struct ProjectCloseTests {
    @Test func closingTheModelClosesTheProject() {
        let p = FakeProject(durationNs: 5_000_000_000), m = EditorModel(project: p, player: FakePlayer())
        m.addZoomAtPlayhead(); m.close()
        #expect(p.closed && p.saveCount == 1)
    }

    @Test func realProjectRefusesEveryMutationAfterClose() throws {
        let d = try pkgCopy2(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let m = doc.model
        m.set("canvas.padding", number: 31)
        m.close()
        #expect(throws: (any Error).self) { try doc.project.apply(.set(path: "canvas.padding", value: .number(5))) }
        #expect(throws: (any Error).self) { try doc.project.save() }
        #expect(throws: (any Error).self) { try doc.project.undo() }
        #expect(doc.project.durationNs > 0)                                       // reads keep working
        let reopened = try EditorDocument(package: d)
        #expect(reopened.model.number("canvas.padding") == 31)                    // the pre-close save won
    }

    @Test func lateBackgroundImportCannotTouchAReopenedPackage() async throws {
        let d = try pkgCopy2(); defer { try? FileManager.default.removeItem(at: d) }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("late-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        do {
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            let f = try AVAudioFile(forWriting: wav, settings: fmt.settings)
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100)!; b.frameLength = 44100
            try f.write(from: b)
        }
        let stale = try EditorDocument(package: d)
        stale.model.importMusicFile(wav)
        stale.model.close()                                                       // window closed while the import is running
        let fresh = try EditorDocument(package: d)                                // reopened
        fresh.model.set("canvas.padding", number: 66); fresh.model.saveNow()
        await stale.model.waitForMusicImport()
        let verify = try EditorDocument(package: d)
        #expect(verify.model.number("canvas.padding") == 66 && verify.model.music.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("autosave/project.json").path))
    }
}
