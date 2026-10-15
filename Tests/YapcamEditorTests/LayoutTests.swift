import Testing
import Foundation
@testable import YapcamEditor

@MainActor @Suite struct EditorLayoutTests {
    private func model(_ dur: Int64 = 20_000_000_000) -> EditorModel { EditorModel(project: FakeProject(durationNs: dur), player: FakePlayer()) }

    @Test func emptyProjectShowsOnlyClipAndZoomTracks() {
        let m = model()
        #expect(m.visibleLanes.isEmpty)
        let l = TimelineLayout(lanes: m.visibleLanes)
        #expect(l.lanesTop == l.zoomTop + TimelineLayout.zoomTrackHeight + TimelineLayout.gap)
        #expect(l.totalHeight < 150)                               // compact: ruler + clip + zoom only
    }

    @Test func lanesAppearOnlyWhenTheyHaveContentAndStackWithoutGaps() {
        let m = model(); m.seek(toNs: 1_000_000_000)
        m.addText(.caption, text: "c"); m.addHighlightAtPlayhead(); m.addBuiltInMusic(builtInMusic[0])
        #expect(m.visibleLanes == [.highlight, .caption, .music])
        let l = TimelineLayout(lanes: m.visibleLanes)
        #expect(l.top(of: .highlight) == l.lanesTop)
        #expect(l.top(of: .caption) == l.lanesTop + TimelineLayout.laneHeight + TimelineLayout.gap)
        #expect(l.top(of: .camera) == nil && l.top(of: .text) == nil && l.top(of: .cursor) == nil)
        #expect(l.totalHeight > TimelineLayout(lanes: []).totalHeight)
        m.selection = .highlight(m.highlights[0].id); m.deleteSelection()
        #expect(m.visibleLanes == [.caption, .music])              // an emptied lane disappears again
    }

    @Test func cameraLaneFollowsLayoutsNotTheCameraTrack() {
        let p = FakeProject(durationNs: 20_000_000_000); p.hasCamera = true
        let m = EditorModel(project: p, player: FakePlayer())
        #expect(!m.visibleLanes.contains(.camera))                 // a camera track alone does not add an empty row
        m.addLayoutAtPlayhead()
        #expect(m.visibleLanes == [.camera])
    }

    @Test func hitRegionsFollowTheCompactLayout() {
        let l = TimelineLayout(lanes: [.caption])
        #expect(l.clipTop < l.zoomTop && l.zoomTop < l.lanesTop && l.captionTop == l.lanesTop)
        #expect(l.captionTop + TimelineLayout.laneHeight < l.totalHeight)
    }

    @Test func cutToolSplitsWhereClicked() {
        let m = model(); m.cutToolActive = true
        m.seek(toNs: 7_000_000_000); m.splitAtPlayhead()
        #expect(m.clips.count == 2 && m.cutToolActive)
    }

    @Test func previewZoomClampsAndResets() {
        let m = model()
        m.zoomPreview(by: 0.5); #expect(m.previewZoom == 1)
        for _ in 0..<10 { m.zoomPreview(by: 2) }; #expect(m.previewZoom == 4)
        m.previewPan = CGSize(width: 10, height: 5); m.resetPreviewZoom()
        #expect(m.previewZoom == 1 && m.previewPan == .zero)
        m.zoomPreview(by: 2); m.previewPan = CGSize(width: 3, height: 3); m.zoomPreview(by: 0.1)
        #expect(m.previewPan == .zero)                              // back at fit: no stale pan
    }
}

@MainActor @Suite struct BackgroundPanelModelTests {
    @Test func wallpaperSelectionIsTrackedAndClearedByKindChange() async {
        let p = FakeProject(), m = EditorModel(project: p, player: FakePlayer())
        m.applyWallpaper(id: "boreal-glow"); await m.waitForWallpaper()
        #expect(m.selectedWallpaperID == "boreal-glow")
        m.set("canvas.background.kind", string: "solid"); #expect(m.selectedWallpaperID == nil)
        m.applyRandomWallpaper(); await m.waitForWallpaper()
        #expect(m.selectedWallpaperID != nil)
        let first = m.selectedWallpaperID
        m.applyRandomWallpaper(); await m.waitForWallpaper()
        #expect(m.selectedWallpaperID != first)                     // "pick random" never repeats the current one
    }

    @Test func importedImageBecomesTheBackground() {
        let p = FakeProject(), m = EditorModel(project: p, player: FakePlayer())
        m.importBackgroundImage(URL(fileURLWithPath: "/tmp/pic.png"))
        #expect(p.importedBackgrounds.count == 1 && m.string("canvas.background.kind") == "image" && m.selectedWallpaperID == nil)
        m.undo(); #expect(m.string("canvas.background.kind") == "solid")
    }

    @Test func hexParsingAndFormatting() {
        #expect(HexField.parse("#1F2937") == [Double(0x1F) / 255, Double(0x29) / 255, Double(0x37) / 255, 1])
        #expect(HexField.parse("ff00aa")?.count == 4 && HexField.parse("zzz") == nil && HexField.parse("#12345") == nil)
        #expect(HexField.format([1, 0, 0.5, 1]) == "#FF0080")
    }

    @Test func presetsRoundTripThroughTheProject() throws {
        try withIsolatedPresets {
        let p = FakeProject(), m = EditorModel(project: p, player: FakePlayer())
        let name = "test-\(UUID().uuidString.prefix(6))"
        m.savePreset(named: "  \(name)/x ")
        #expect(p.exportedPresets.count == 1 && p.exportedPresets[0].lastPathComponent == "\(name)-x.yapcampreset")
        defer { try? FileManager.default.removeItem(at: p.exportedPresets[0]) }
        #expect(EditorPresets.names().contains("\(name)-x"))
        m.applyPreset(at: p.exportedPresets[0]); #expect(m.number("canvas.padding") == 99 && m.canUndo)
        m.savePreset(named: "   "); #expect(m.lastError != nil)
    }
    }
}
