import Testing
import Foundation
@testable import YapcamEditor

@MainActor
private func makeModel(duration: Int64 = 10_000_000_000) -> (EditorModel, FakeProject, FakePlayer) {
    let p = FakeProject(durationNs: duration), pl = FakePlayer()
    let m = EditorModel(project: p, player: pl)
    m.autosaveDelay = .milliseconds(50)
    return (m, p, pl)
}

@MainActor @Suite struct EditorModelTests {
    @Test func splitAtPlayheadCreatesTwoClips() {
        let (m, _, _) = makeModel()
        m.seek(toNs: 4_000_000_000)
        m.splitAtPlayhead()
        #expect(m.clips.count == 2)
        #expect(m.clips[0].srcEndNs == 4_000_000_000)
        #expect(m.durationNs == 10_000_000_000)
    }

    @Test func splitIgnoredAtBoundaries() {
        let (m, _, _) = makeModel()
        m.seek(toNs: 0); m.splitAtPlayhead()
        m.seek(toNs: 10_000_000_000); m.splitAtPlayhead()
        #expect(m.clips.count == 1)
        m.seek(toNs: 5_000_000_000); m.splitAtPlayhead(); m.splitAtPlayhead()
        #expect(m.clips.count == 2)
    }

    @Test func deleteClipRipplesAndClampsPlayhead() {
        let (m, _, _) = makeModel()
        m.seek(toNs: 6_000_000_000); m.splitAtPlayhead()
        m.selection = .clip(m.clips[1].id)
        m.deleteSelection()
        #expect(m.durationNs == 6_000_000_000)
        #expect(m.selection == .none)
        m.seek(toNs: 6_000_000_000)
        #expect(m.playheadNs == 6_000_000_000)
    }

    @Test func cannotDeleteOnlyClip() {
        let (m, _, _) = makeModel()
        m.selection = .clip("c0"); m.deleteSelection()
        #expect(m.clips.count == 1)
        #expect(m.lastError != nil)
    }

    @Test func addZoomSelectsIt() {
        let (m, _, _) = makeModel()
        m.seek(toNs: 3_000_000_000)
        m.addZoomAtPlayhead()
        #expect(m.zooms.count == 1)
        #expect(m.zooms[0].startNs == 3_000_000_000 && m.zooms[0].endNs == 5_000_000_000)
        #expect(m.selectedZoom?.id == m.zooms[0].id)
    }

    @Test func zoomNearEndIsRejected() {
        let (m, _, _) = makeModel()
        m.seek(toNs: 9_900_000_000)
        m.addZoomAtPlayhead()
        #expect(m.zooms.isEmpty && m.lastError != nil)
    }

    @Test func moveAndResizeZoomRespectBounds() {
        let (m, _, _) = makeModel()
        m.addZoomAtPlayhead()
        let id = m.zooms[0].id
        m.moveZoom(id: id, toStartNs: 9_500_000_000)
        #expect(m.zooms[0].endNs == 10_000_000_000)
        m.resizeZoom(id: id, endNs: m.zooms[0].startNs + 10)
        #expect(m.zooms[0].endNs - m.zooms[0].startNs == minZoomDurationNs)
        m.moveZoom(id: id, toStartNs: -5)
        #expect(m.zooms[0].startNs == 0)
    }

    @Test func undoRedoAndPlayerInvalidation() {
        let (m, _, pl) = makeModel()
        m.addZoomAtPlayhead()
        let inv = pl.invalidations
        m.undo()
        #expect(m.zooms.isEmpty && m.canRedo && pl.invalidations > inv)
        m.redo()
        #expect(m.zooms.count == 1)
    }

    @Test func autosaveDebouncesAndSaveNowFlushes() async throws {
        let (m, p, _) = makeModel()
        m.addZoomAtPlayhead(); m.addZoomAtPlayhead()
        #expect(p.saveCount == 0 && m.saveState == .dirty)
        for _ in 0..<200 where p.saveCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(p.saveCount == 1 && m.saveState == .clean)
        m.seek(toNs: 5_000_000_000); m.splitAtPlayhead()
        m.saveNow()
        #expect(p.saveCount == 2)
        try await Task.sleep(for: .milliseconds(300))
        #expect(p.saveCount == 2)
    }

    @Test func saveFailureIsSurfaced() {
        let (m, p, _) = makeModel()
        p.failSave = true
        m.addZoomAtPlayhead(); m.saveNow()
        #expect(m.saveState == .failed("disk full") && m.lastError != nil)
    }

    @Test func seekClampsAndShuttleKeys() {
        let (m, _, pl) = makeModel()
        m.seek(toNs: 99_000_000_000)
        #expect(m.playheadNs == 10_000_000_000)
        m.shuttle("l"); #expect(m.isPlaying)
        m.shuttle("k"); #expect(!m.isPlaying)
        m.shuttle("j"); #expect(pl.currentNs == 9_000_000_000)
    }

    @Test func speedChangeAltersTimelineDuration() {
        let (m, _, _) = makeModel()
        m.setSpeed(clipID: "c0", 2)
        #expect(m.durationNs == 5_000_000_000)
        m.setSpeed(clipID: "c0", 1000)
        #expect(m.clips[0].speed == 16)
    }

    @Test func zoomFocusIsClampedInsideFrame() {
        let (m, _, _) = makeModel()
        m.addZoomAtPlayhead()
        m.setZoomFocus(id: m.zooms[0].id, x: 0.0, y: 1.0)   // scale 2 → crop half = 0.25
        #expect(m.zooms[0].focusX == 0.25 && m.zooms[0].focusY == 0.75)
    }

    @Test func snapsToPlayheadAndClicksOnlyWhenEnabled() {
        let (m, p, _) = makeModel()
        p.clickTimesNs = [2_000_000_000]
        m.geometry = TimelineGeometry(pixelsPerSecond: 100)
        #expect(m.snapped(2_050_000_000) == 2_000_000_000)   // 5 px away
        #expect(m.snapGuideNs == 2_000_000_000)
        #expect(m.snapped(2_500_000_000) == 2_500_000_000)
        #expect(m.snapGuideNs == nil)
        m.snappingEnabled = false
        #expect(m.snapped(2_050_000_000) == 2_050_000_000)
    }
}

@MainActor @Suite struct ExportModelTests {
    @Test func successReportsDone() async throws {
        let m = ExportModel(engine: FakeExporter())
        let url = URL(fileURLWithPath: "/tmp/x.mp4")
        m.start(to: url)
        #expect(m.isRunning)
        await m.waitUntilFinished()
        #expect(m.state == .done(url))
    }
    @Test func failureAndCancel() async throws {
        let f = ExportModel(engine: FakeExporter(failure: NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "encoder died"])))
        f.start(to: URL(fileURLWithPath: "/tmp/y.mp4"))
        await f.waitUntilFinished()
        #expect(f.state == .failed("encoder died"))
        let c = ExportModel(engine: FakeExporter())
        c.start(to: URL(fileURLWithPath: "/tmp/z.mp4")); c.cancel()
        await c.waitUntilFinished()
        #expect(c.state == .cancelled)
    }
}

@Suite struct GeometryTests {
    @Test func roundTripAndZoomAnchor() {
        let g = TimelineGeometry(pixelsPerSecond: 100)
        #expect(g.ns(forX: g.x(forNs: 1_234_000_000)) == 1_234_000_000)
        let z = g.zoomed(by: 2, anchorX: 300)
        #expect(abs(Double(z.ns(forX: 300) - g.ns(forX: 300))) < 1000)
    }
    @Test func rulerStepAndTimecode() {
        #expect(TimelineGeometry(pixelsPerSecond: 100).rulerStepSeconds() == 1)
        #expect(TimelineGeometry(pixelsPerSecond: 2).rulerStepSeconds() == 60)
        #expect(formatTimecode(65_500_000_000) == "1:05.50")
        #expect(formatTimecode(3_725_000_000_000, showFraction: false) == "1:02:05")
    }
    @Test func clampedZoomLevels() {
        #expect(TimelineGeometry(pixelsPerSecond: 1e9).pixelsPerSecond == TimelineGeometry.maxPPS)
    }
}

@MainActor @Suite struct GestureAndSettingsTests {
    @Test func zoomDragIsOneUndoStep() {
        let p = FakeProject(), pl = FakePlayer(), m = EditorModel(project: p, player: pl)
        m.addZoomAtPlayhead()
        let id = m.zooms[0].id
        for s in stride(from: 100_000_000, through: 3_000_000_000, by: 100_000_000) { m.previewZoom(id: id, moveToStartNs: Int64(s)) }
        #expect(m.zooms[0].startNs == 0)                       // not committed yet
        #expect(m.displayedRange(of: m.zooms[0]).start == 3_000_000_000)
        m.commitZoomPreview(id: id)
        #expect(m.zooms[0].startNs == 3_000_000_000)
        m.undo()
        #expect(m.zooms[0].startNs == 0 && m.zooms.count == 1)  // one undo reverts the whole drag
    }

    @Test func settingsReadWriteByPath() {
        let p = FakeProject(), m = EditorModel(project: p, player: FakePlayer())
        m.set("cursor.size", number: 2); m.set("cursor.hide_when_idle", bool: true)
        m.set("canvas.background.color", color: [1, 0, 0.5, 1]); m.set("cursor.click_effect", string: "none")
        #expect(m.number("cursor.size") == 2 && m.bool("cursor.hide_when_idle"))
        #expect(m.color("canvas.background.color") == [1, 0, 0.5, 1] && m.string("cursor.click_effect") == "none")
        #expect(m.number("missing.path", default: 7) == 7)
        m.undo(); #expect(m.string("cursor.click_effect") == "ring")
    }

    @Test func aspectChangeIsOneStep() {
        let p = FakeProject(), m = EditorModel(project: p, player: FakePlayer())
        m.setAspect(.vertical)
        #expect(m.string("canvas.aspect") == "9:16" && m.numbers("canvas.output_size") == [1080, 1920])
        m.undo(); #expect(m.string("canvas.aspect") == "")
    }

    @Test func focusPickerMapsThroughPaddingAndCrop() {
        let g = FrameGeometry(canvasWidth: 1920, canvasHeight: 1080, dest: CGRect(x: 96, y: 54, width: 1728, height: 972))
        #expect(g.sourcePoint(fromPreview: CGPoint(x: 0.01, y: 0.5)) == nil)
        let tl = g.sourcePoint(fromPreview: CGPoint(x: 96 / 1920.0, y: 54 / 1080.0))!
        #expect(abs(tl.x) < 1e-9 && abs(tl.y) < 1e-9)
        var z = g; z.crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let c = z.sourcePoint(fromPreview: CGPoint(x: 0.5, y: 0.5))!
        #expect(abs(c.x - 0.5) < 1e-9)
    }

    @Test func clickingPreviewSetsFocusOfSelectedZoom() {
        let p = FakeProject(), m = EditorModel(project: p, player: FakePlayer())
        #expect(!m.setFocus(fromPreview: CGPoint(x: 0.5, y: 0.5)))      // nothing selected
        m.addZoomAtPlayhead()
        #expect(m.setFocus(fromPreview: CGPoint(x: 0.5, y: 0.5)))
        #expect(abs(m.zooms[0].focusX - 0.5) < 0.01)
    }

    @Test func zoomEnableAndEase() {
        let p = FakeProject(), m = EditorModel(project: p, player: FakePlayer())
        m.addZoomAtPlayhead(); let id = m.zooms[0].id
        m.setZoomEnabled(id: id, false); m.setZoomEase(id: id, inNs: 500_000_000, outNs: -5)
        #expect(!m.zooms[0].enabled && m.zooms[0].easeInNs == 500_000_000 && m.zooms[0].easeOutNs == 0)
    }

    @Test func autoZoomRegenerationGoesToProject() {
        let p = FakeProject(), m = EditorModel(project: p, player: FakePlayer())
        m.regenerateAutoZooms(); #expect(p.autoZoomRuns == 1)
    }
}

@MainActor @Suite struct LaneAndAutomationTests {
    private func make() -> (EditorModel, FakeProject) {
        let p = FakeProject(durationNs: 20_000_000_000)
        return (EditorModel(project: p, player: FakePlayer()), p)
    }

    @Test func cameraLayoutsAddEditRemoveAndRejectOverlap() {
        let (m, _) = make()
        m.seek(toNs: 2_000_000_000); m.addLayoutAtPlayhead(mode: "camera")
        #expect(m.layouts.count == 1 && m.layouts[0].endNs == 5_000_000_000)
        m.seek(toNs: 4_000_000_000); m.addLayoutAtPlayhead()
        #expect(m.layouts.count == 1 && m.lastError != nil)
        let id = m.layouts[0].id
        m.setLayoutMode(id: id, "overlay"); #expect(m.layouts[0].mode == "overlay")
        m.previewRange(key: id, current: TimeSpan(startNs: 2_000_000_000, endNs: 5_000_000_000), moveToStartNs: 10_000_000_000)
        m.commitRange(key: id)
        #expect(m.layouts[0].startNs == 10_000_000_000 && m.layouts[0].endNs == 13_000_000_000)
        m.selection = .layout(id); m.deleteSelection()
        #expect(m.layouts.isEmpty)
    }

    @Test func layoutNeedsACamera() {
        let (m, p) = make(); p.hasCamera = false
        m.addLayoutAtPlayhead()
        #expect(m.layouts.isEmpty && m.lastError != nil)
    }

    @Test func cursorHideRanges() {
        let (m, _) = make()
        m.seek(toNs: 1_000_000_000); m.addCursorHideAtPlayhead()
        #expect(m.cursorHides.count == 1 && m.cursorHides[0].span == TimeSpan(startNs: 1_000_000_000, endNs: 3_000_000_000))
        let key = EditorModel.cursorKey(0)
        m.previewRange(key: key, current: m.cursorHides[0].span, endNs: 6_000_000_000); m.commitRange(key: key)
        #expect(m.cursorHides[0].span.endNs == 6_000_000_000)
        m.undo(); #expect(m.cursorHides[0].span.endNs == 3_000_000_000)
        m.selection = .cursorHide(0); m.deleteSelection(); #expect(m.cursorHides.isEmpty)
    }

    @Test func silenceFlowCutsFoundSpansInOneStep() async throws {
        let (m, p) = make()
        p.silences = [TimeSpan(startNs: 1_000_000_000, endNs: 2_000_000_000), TimeSpan(startNs: 5_000_000_000, endNs: 7_000_000_000)]
        m.findSilences()
        await m.waitForSilenceAnalysis()
        #expect(m.silenceState == .found(p.silences))
        m.applySilences(speed: nil)
        #expect(m.silenceState == .idle)
    }

    @Test func typingSpeedAndTrim() {
        let (m, p) = make()
        m.speedUpTyping(); #expect(p.typingRuns == 1)
        m.seek(toNs: 5_000_000_000); m.splitAtPlayhead()
        m.trim(keepAfter: true)
        #expect(m.durationNs == 15_000_000_000)
        m.seek(toNs: 0); m.trim(keepAfter: false)
        #expect(m.lastError != nil)
    }

    @Test func multiSelectDeleteIsOneUndoStep() {
        let (m, _) = make()
        for t in [1, 5, 9] { m.seek(toNs: Int64(t) * 1_000_000_000); m.addZoomAtPlayhead() }
        let ids = m.zooms.map(\.id)
        m.selection = .zoom(ids[0]); m.extraZoomSelection = [ids[1]]
        m.deleteSelection()
        #expect(m.zooms.map(\.id) == [ids[2]])
        m.undo(); #expect(m.zooms.count == 3)
    }

    @Test func paletteFiltersByWordPrefix() {
        let (m, _) = make()
        #expect(m.filteredCommands("").count == m.paletteCommands.count)
        let titles = m.filteredCommands("add zo").map(\.title)
        #expect(titles == ["Add zoom at playhead"])
        #expect(m.filteredCommands("zzzz").isEmpty)
        #expect(m.filteredCommands("sil").first?.title == "Find silent parts")
    }
}

@MainActor @Suite struct AudioAndCropTests {
    @Test func audioRangesRoundTripThroughSettings() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        m.seek(toNs: 2_000_000_000); m.addAudioRangeAtPlayhead(track: "system_audio")
        #expect(m.audioRanges.count == 1 && m.audioRanges[0].startGainDb == -12 && m.audioRanges[0].span.endNs == 5_000_000_000)
        let id = m.audioRanges[0].id
        m.updateAudioRange(id: id, endGainDb: -200)
        #expect(m.audioRanges[0].endGainDb == -96)
        m.removeAudioRange(id: id); #expect(m.audioRanges.isEmpty)
    }

    @Test func cropInsetsClampAndRoundTrip() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        m.setCrop(left: 0.1, top: 0.2, right: 0.95, bottom: 0.0)
        let c = m.cropInsets
        #expect(abs(c.left - 0.1) < 1e-9 && abs(c.top - 0.2) < 1e-9 && abs(c.right - 0.8) < 1e-9)   // right clamped to 0.9 - left
        #expect(m.numbers("canvas.crop").count == 4)
    }
}
