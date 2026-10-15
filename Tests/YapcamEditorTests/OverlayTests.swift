import Testing
import Foundation
import CoreGraphics
import YapcamCore
import YapcamRender
@testable import YapcamEditor

private func pkgCopy() throws -> URL {
    let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("ov-\(UUID().uuidString).yapcam")
    try FileManager.default.copyItem(at: src, to: d); return d
}

@MainActor @Suite struct HighlightModelTests {
    private func make() -> EditorModel { EditorModel(project: FakeProject(durationNs: 20_000_000_000), player: FakePlayer()) }

    @Test func addEditRemoveAndKinds() {
        let m = make()
        m.seek(toNs: 2_000_000_000); m.addHighlightAtPlayhead(kind: .mask)
        #expect(m.highlights.count == 1 && m.highlights[0].kind == .mask && m.highlights[0].endNs == 5_000_000_000)
        let id = m.highlights[0].id
        #expect(m.selection == .highlight(id))
        m.setHighlightKind(id: id, .spotlight); #expect(m.highlights[0].kind == .spotlight && m.highlights[0].strokeWidth == 0)
        m.setHighlightKind(id: id, .highlight); #expect(m.highlights[0].kind == .highlight && m.highlights[0].dimOpacity == 0.4)
        m.updateHighlight(id: id) { $0.space = "canvas" }; #expect(m.highlights[0].space == "canvas")
        m.deleteSelection(); #expect(m.highlights.isEmpty && m.selection == .none)
    }

    @Test func rectDragIsOneUndoStepAndClamped() {
        let m = make(); m.addHighlightAtPlayhead(); let h = m.highlights[0]
        for i in 1...30 { m.previewHighlightRect(id: h.id, rect: [0.25 + Double(i) * 0.05, 0.25, 0.5, 0.5]) }
        #expect(m.highlights[0].rect == h.rect)                      // nothing committed mid-drag
        m.commitHighlightRect()
        #expect(m.highlights[0].rect == [0.5, 0.25, 0.5, 0.5])       // clamped inside the frame (x + w ≤ 1)
        m.undo(); #expect(m.highlights[0].rect == h.rect)
    }

    @Test func rangeDragRetimesHighlight() {
        let m = make(); m.addHighlightAtPlayhead(); let h = m.highlights[0]
        m.previewRange(key: h.id, current: h.span, moveToStartNs: 10_000_000_000); m.commitRange(key: h.id)
        #expect(m.highlights[0].startNs == 10_000_000_000 && m.highlights[0].endNs == 13_000_000_000)
    }

    @Test func cornerResizeGeometry() {
        let r = [0.2, 0.2, 0.4, 0.4]
        #expect(HighlightGeometry.apply(rect: r, delta: CGSize(width: 0.1, height: -0.1), mode: .move) == [0.30000000000000004, 0.1, 0.4, 0.4])
        let br = HighlightGeometry.apply(rect: r, delta: CGSize(width: 0.2, height: 0.1), mode: .corner(3))
        #expect(abs(br[2] - 0.6) < 1e-9 && abs(br[3] - 0.5) < 1e-9)
        let flipped = HighlightGeometry.apply(rect: r, delta: CGSize(width: -0.6, height: 0), mode: .corner(1))   // drag TR corner past the left edge
        #expect(flipped[0] < 0.2 && flipped[2] > 0)
    }

    @Test func geometryMapsSourceAndCanvasSpaces() {
        let g = FrameGeometry(canvasWidth: 1920, canvasHeight: 1080, dest: CGRect(x: 96, y: 54, width: 1728, height: 972))
        let full = g.previewRect(fromNormalized: [0, 0, 1, 1], space: "source")
        #expect(abs(full.minX - 0.05) < 1e-9 && abs(full.width - 0.9) < 1e-9)
        #expect(g.previewRect(fromNormalized: [0.1, 0.1, 0.5, 0.5], space: "canvas") == CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        let d = g.normalizedDelta(dx: 0.09, dy: 0, space: "source"); #expect(abs(d.width - 0.1) < 1e-9)
        var zoomed = g; zoomed.crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        #expect(abs(zoomed.normalizedDelta(dx: 0.09, dy: 0, space: "source").width - 0.05) < 1e-9)   // zoomed view moves less source per px
    }

    @Test func instantZoomToggleSetsEaseToZero() {
        let m = make(); m.addZoomAtPlayhead(); let id = m.zooms[0].id
        m.setZoomEase(id: id, inNs: 0, outNs: 0)
        #expect(m.zooms[0].easeInNs == 0 && m.zooms[0].easeOutNs == 0)
    }
}

@MainActor @Suite struct OverlayRealCoreTests {
    @Test func coreAcceptsAllRegionKindsAndRendersThem() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let m = doc.model
        m.seek(toNs: 500_000_000)
        for kind in HighlightRegion.Kind.allCases { m.addHighlightAtPlayhead(kind: kind) }
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.highlights.count == 3)
        let extras = try doc.project.frameExtras(atNs: 1_000_000_000)
        #expect(extras.highlight_count == 3)
        let effects = try doc.project.renderEffects(atNs: 1_000_000_000, canvasSize: CGSize(width: 1920, height: 1080))
        #expect(effects.layers.count == 3)
        // The editor's own render source forwards the same effects to preview and export.
        let viaSource = try ProjectRenderSource(doc.project).renderEffects(atNs: 1_000_000_000, canvasSize: CGSize(width: 1920, height: 1080))
        #expect(viaSource.layers.count == 3)
        // After the region ends there is nothing to draw.
        #expect(try doc.project.frameExtras(atNs: 4_500_000_000).highlight_count == 0)
    }

    @Test func tooManyOverlappingRegionsAreRejectedWithoutChange() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        m.seek(toNs: 500_000_000)
        for _ in 0..<32 { m.addHighlightAtPlayhead() }
        #expect(m.highlights.count == 32 && m.lastError == nil)
        m.addHighlightAtPlayhead()
        #expect(m.highlights.count == 32 && m.lastError != nil)
    }

    @Test func introOutroAndNewEffectPathsAreAccepted() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let m = doc.model
        m.set("canvas.animation.entrance", string: "fade"); m.set("canvas.animation.exit", string: "fade")
        m.set("canvas.animation.entrance_duration_ns", number: 1_000_000_000)
        m.set("canvas.animation.exit_duration_ns", number: 800_000_000)
        m.set("cursor.motion_blur", number: 0.4); m.set("cursor.spotlight_radius", number: 120); m.set("cursor.style", string: "pointer")
        m.set("canvas.window_chrome", bool: true); m.set("canvas.background.noise", number: 0.2)
        m.set("camera.shadow_radius", number: 20)
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(try doc.project.frameExtras(atNs: 0).fade_opacity == 1)
        #expect(try doc.project.frameExtras(atNs: 2_000_000_000).fade_opacity == 0)
        let e = try doc.project.frameExtras(atNs: 2_000_000_000)
        #expect(e.cursor_style == 1 && e.window_chrome == 1 && e.cursor_spotlight_radius == 120)
        m.set("canvas.animation.entrance_duration_ns", number: 0)
        #expect(m.lastError != nil)    // core rejects non-positive durations; state unchanged
        #expect(m.number("canvas.animation.entrance_duration_ns") == 1_000_000_000)
    }

    @Test func instantZoomReachesCore() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        m.addZoomAtPlayhead(); m.setZoomEase(id: m.zooms[0].id, inNs: 0, outNs: 0)
        #expect(m.zooms[0].easeInNs == 0 && m.lastError == nil)
    }
}

@MainActor @Suite struct WallpaperTests {
    @Test func applyingWallpaperGoesThroughTheProjectAsOneStep() async throws {
        let p = FakeProject(), m = EditorModel(project: p, player: FakePlayer())
        #expect(m.wallpapers.map(\.id) == ["quiet-dawn", "boreal-glow"])
        m.applyWallpaper(id: "boreal-glow"); #expect(m.wallpaperBusy == "boreal-glow")
        await m.waitForWallpaper()
        #expect(p.appliedWallpapers == ["boreal-glow"] && m.wallpaperBusy == nil && m.string("canvas.background.kind") == "image")
        m.undo(); #expect(m.string("canvas.background.kind") == "solid")
        m.applyWallpaper(id: "nope"); await m.waitForWallpaper()
        #expect(m.lastError != nil && m.wallpaperBusy == nil)
    }

    @Test func realLibraryAppliesGradientAndImageWallpapers() async throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        #expect(m.wallpapers.count == 12)
        m.applyWallpaper(id: "quiet-dawn"); await m.waitForWallpaper()
        #expect(m.string("canvas.background.kind") == "gradient" && m.lastError == nil, "\(m.lastError ?? "")")
        m.applyWallpaper(id: "boreal-glow"); await m.waitForWallpaper()
        #expect(m.string("canvas.background.kind") == "image" && m.lastError == nil, "\(m.lastError ?? "")")
        let thumb = await m.project.wallpaperThumbnail(id: "sediment")
        #expect(thumb?.width == 192 && thumb?.height == 108)
        m.undo(); #expect(m.string("canvas.background.kind") == "gradient")
    }
}
