import Testing
import Foundation
@testable import YapcamEditor

@MainActor
private func makeModel(duration: Int64 = 10_000_000_000) -> (EditorModel, FakeProject, FakePlayer) {
    let p = FakeProject(durationNs: duration), pl = FakePlayer()
    let m = EditorModel(project: p, player: pl)
    m.autosaveDelay = .milliseconds(30)
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
        try await Task.sleep(for: .milliseconds(150))
        #expect(p.saveCount == 1 && m.saveState == .clean)
        m.seek(toNs: 5_000_000_000); m.splitAtPlayhead()
        m.saveNow()
        #expect(p.saveCount == 2)
        try await Task.sleep(for: .milliseconds(100))
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
        try await Task.sleep(for: .milliseconds(400))
        #expect(m.state == .done(url))
    }
    @Test func failureAndCancel() async throws {
        let f = ExportModel(engine: FakeExporter(failure: NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "encoder died"])))
        f.start(to: URL(fileURLWithPath: "/tmp/y.mp4"))
        try await Task.sleep(for: .milliseconds(400))
        #expect(f.state == .failed("encoder died"))
        let c = ExportModel(engine: FakeExporter())
        c.start(to: URL(fileURLWithPath: "/tmp/z.mp4")); c.cancel()
        try await Task.sleep(for: .milliseconds(300))
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
