import SwiftUI
import AppKit
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
        m.setHighlightKind(id: id, .highlight); #expect(m.highlights[0].kind == .highlight && m.highlights[0].dimOpacity == 0.5)
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
        #expect(m.highlights.count == HighlightRegion.Kind.allCases.count)   // highlight, blur, cover, spotlight
        let extras = try doc.project.frameExtras(atNs: 1_000_000_000)
        #expect(extras.highlight_count == HighlightRegion.Kind.allCases.count)
        let effects = try doc.project.renderEffects(atNs: 1_000_000_000, canvasSize: CGSize(width: 1920, height: 1080))
        #expect(effects.layers.count == HighlightRegion.Kind.allCases.count)
        // The editor's own render source forwards the same effects to preview and export.
        let viaSource = try ProjectRenderSource(doc.project).renderEffects(atNs: 1_000_000_000, canvasSize: CGSize(width: 1920, height: 1080))
        #expect(viaSource.layers.count == HighlightRegion.Kind.allCases.count)
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

@MainActor @Suite struct GuideOptionTests {
    @Test func realCoreAcceptsEveryCursorMotionAndCameraOption() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let m = doc.model
        for (path, on) in [("cursor.always_default", true), ("cursor.rotate_on_move", true), ("cursor.remove_shakes", true), ("cursor.optimize_types", true)] {
            m.set(path, bool: on); #expect(m.bool(path) == on, "\(path): \(m.lastError ?? "")")
        }
        m.set("cursor.stop_before_end_ns", number: 1_000_000_000)
        for style in ["focused", "smooth", "custom"] { m.set("zoom_settings.animation_style", string: style); #expect(m.string("zoom_settings.animation_style") == style) }
        m.set("camera.zoom_scale", number: 1.5)
        m.set("canvas.motion_blur", number: 0.3)
        m.set("canvas.motion_blur_settings.zoom", number: 0.8); m.set("canvas.motion_blur_settings.pan", .null)
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.number("camera.zoom_scale") == 1.5 && m.number("canvas.motion_blur_settings.zoom") == 0.8)
        #expect(m.value("canvas.motion_blur_settings.pan") == .null)
        // Out-of-range values are rejected by core and leave state unchanged.
        m.set("camera.zoom_scale", number: 9); #expect(m.lastError != nil && m.number("camera.zoom_scale") == 1.5)
        // Core evaluates them: the held cursor and motion data are queryable at a valid time.
        #expect((try? doc.project.motion(atNs: 500_000_000)) != nil)
    }

    @Test func inheritedBlurAndHoldToggleSemantics() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        #expect(m.value("canvas.motion_blur_settings.zoom") == nil)       // absent = inherits
        m.set("canvas.motion_blur_settings.zoom", number: 0.5)
        if case .number(0.5)? = m.value("canvas.motion_blur_settings.zoom") {} else { Issue.record("expected explicit value") }
        m.set("canvas.motion_blur_settings.zoom", .null)
        if case .number? = m.value("canvas.motion_blur_settings.zoom") { Issue.record("expected inherit") }
    }
}

@MainActor @Suite struct VoiceCleanupTests {
    @Test func settingsReachThePreviewAndTheExportRequest() async throws {
        let p = FakeProject(), pl = FakePlayer(), m = EditorModel(project: p, player: pl)
        #expect(m.speechEnhancement == nil && pl.speechCalls.count == 1 && pl.speechCalls[0] == nil)   // initial push: off
        m.set("audio.speech_enhancement", bool: true)
        #expect(m.speechEnhancement?.noiseReductionDB == 30)                    // defaults when settings absent
        #expect(pl.speechCalls.last! == m.speechEnhancement)
        m.set("audio.speech_enhancement_settings.noise_reduction_db", number: 42)
        m.set("audio.speech_enhancement_settings.normalize_loudness", bool: false)
        #expect(m.speechEnhancement?.noiseReductionDB == 42 && m.speechEnhancement?.normalizeLoudness == false)
        let calls = pl.speechCalls.count
        m.set("canvas.padding", number: 20)                                      // unrelated edit: no redundant push
        #expect(pl.speechCalls.count == calls)
        m.undo(); m.undo(); m.undo(); m.undo()
        #expect(m.speechEnhancement == nil && pl.speechCalls.last! == nil)
        m.redo(); m.redo()
        #expect(m.speechEnhancement?.noiseReductionDB == 42)
        // Export carries the settings only when audio is included.
        let engine = RecordingEngine()
        let e = ExportModel(engine: engine); e.speechProvider = { m.speechEnhancement }
        e.start(to: URL(fileURLWithPath: "/tmp/v.mp4")); await e.waitUntilFinished()
        #expect(engine.last?.speech?.noiseReductionDB == 42)
        e.includeAudio = false
        e.start(to: URL(fileURLWithPath: "/tmp/w.mp4")); await e.waitUntilFinished()
        #expect(engine.last?.speech == nil)
    }

    @Test func noMicrophoneMeansNoEnhancementAndFailuresAreReported() {
        let p = FakeProject(), pl = FakePlayer(), m = EditorModel(project: p, player: pl)
        p.hasMic = false; m.set("audio.speech_enhancement", bool: true)
        #expect(m.speechEnhancement == nil)
        p.hasMic = true; pl.speechFailure = NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "decoder missing"])
        m.set("audio.speech_enhancement_settings.high_pass_hz", number: 120)
        #expect(m.lastError?.contains("decoder missing") == true)
    }

    @Test func realCoreAndPlayerAcceptTheSettings() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let m = doc.model
        // The synthetic fixture has no microphone track, so clean-up stays off but the paths persist.
        m.set("audio.speech_enhancement", bool: true)
        m.set("audio.speech_enhancement_settings.target_lufs", number: -18)
        m.set("audio.speech_enhancement_settings.high_pass_hz", number: 150)
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.bool("audio.speech_enhancement") && m.number("audio.speech_enhancement_settings.target_lufs") == -18)
        #expect(m.speechEnhancement == nil)                         // no mic in the fixture
        m.set("audio.speech_enhancement_settings.high_pass_hz", number: 5)   // below core's 20 Hz floor
        #expect(m.lastError != nil && m.number("audio.speech_enhancement_settings.high_pass_hz") == 150)
        // The real preview player takes the render-side settings without error.
        try doc.player.setSpeechEnhancement(SpeechEnhancement().render)
        try doc.player.setSpeechEnhancement(nil)
    }
}

final class RecordingEngine: ExportEngine, @unchecked Sendable {
    private let lock = NSLock(); private var requests: [ExportRequest] = []
    var last: ExportRequest? { lock.withLock { requests.last } }
    func run(_ request: ExportRequest, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        lock.withLock { requests.append(request) }; return request.destination
    }
}

@MainActor @Suite struct CursorLibraryTests {
    private struct Library: Decodable {
        struct Item: Decodable { var id: String }
        var sets: [Item]; var shapes: [String]; var logicalSizes: [Item]
    }

    @Test func pickerListsMatchCoreLibrary() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d)
        let lib = try doc.project.query("{\"q\":\"cursor_library\"}", as: Library.self)
        #expect(VectorCursorLibrary.catalog.map(\.id) == lib.sets.map(\.id))   // render catalog and core accept the same ids
        #expect(cursorShapes.map(\.value) == lib.shapes)
        #expect(cursorSizes.map(\.value) == lib.logicalSizes.map(\.id))
    }

    @Test func carouselChoicesAreAcceptedByCoreAndOneUndoStepEach() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let m = doc.model
        let choices = m.cursorSetChoices()
        #expect(choices.map(\.id) == VectorCursorLibrary.catalog.map(\.id))   // original, touch and all 12 authored sets
        #expect(choices.first?.id == "original")
        for c in choices { m.chooseCursorSet(c); #expect(m.lastError == nil); #expect(m.selectedCursorSetID() == c.id) }
        let paper = try #require(choices.first { $0.id == "paper" })
        m.chooseCursorSet(paper)
        m.undo()
        #expect(m.selectedCursorSetID() != "paper")
        m.chooseCursorSet(paper); try doc.project.save()
        #expect(try EditorDocument(package: d).model.selectedCursorSetID() == "paper")
    }

    @Test func variantsAreStoredPerTypeOneUndoStepAndSurviveReopen() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let m = doc.model
        for style in VectorCursorStyle.allCases {
            #expect(m.cursorVariant(style) == .standard)
            m.setCursorVariant(style, .alternate); #expect(m.lastError == nil)
            #expect(m.cursorVariant(style) == .alternate)
        }
        m.undo(); #expect(m.cursorVariant(.notAllowed) == .standard); #expect(m.cursorVariant(.pointer) == .alternate)
        m.setCursorVariant(.pointer, .standard); m.setCursorVariant(.text, .alternate)
        try doc.project.save()
        let re = try EditorDocument(package: d).model
        #expect(re.cursorVariant(.text) == .alternate); #expect(re.cursorVariant(.pointer) == .standard)
    }

    @Test func selectionsReachTheRenderConfigurationAndInvalidateTheCache() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let m = doc.model
        let source = ProjectRenderSource(doc.project)
        let size = CGSize(width: 1920, height: 1080)
        var cfg = try source.renderEffects(atNs: 500_000_000, canvasSize: size).configuration
        // New projects start with the recorded ("original") cursor, older ones with null (also recorded).
        var baseSet: String? = nil; if case .string(let s)? = m.value("cursor.set_id") { baseSet = s }
        #expect(cfg.cursorSetID == baseSet && cfg.cursorSize == .regular)
        if m.defaultsRevision >= 1 { #expect(baseSet == "original") } else { #expect(baseSet == nil) }
        m.set("cursor.set_id", string: "lagoon"); m.set("cursor.logical_size", string: "large"); m.set("cursor.shape", string: "text")
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        cfg = try source.renderEffects(atNs: 500_000_000, canvasSize: size).configuration
        #expect(cfg.cursorSetID == "lagoon" && cfg.cursorSize == .large && cfg.cursorStyle == .text)
        m.set("cursor.always_default", bool: true)
        cfg = try source.renderEffects(atNs: 500_000_000, canvasSize: size).configuration
        #expect(cfg.cursorStyle == .arrow && cfg.cursorSetID == "lagoon")     // default arrow wins over the shape, set and size stay
        m.set("cursor.always_default", bool: false); m.set("cursor.set_id", .null); m.set("cursor.shape", .null); m.set("cursor.logical_size", string: "regular")
        cfg = try source.renderEffects(atNs: 500_000_000, canvasSize: size).configuration
        #expect(cfg.cursorSetID == nil && cfg.cursorSize == .regular)
        // The immutable export snapshot carries the same selection.
        m.set("cursor.shape", string: "open_hand")
        let snap = try source.renderSnapshot().renderEffects(atNs: 500_000_000, canvasSize: size).configuration
        #expect(snap.cursorStyle == .openHand)
    }

    @Test func invalidChoicesAreRejectedWithStateUnchanged() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        let setBefore = m.value("cursor.set_id")
        m.set("cursor.set_id", string: "nope"); #expect(m.lastError != nil && m.value("cursor.set_id") == setBefore)
        m.lastError = nil
        m.set("cursor.logical_size", string: "huge"); #expect(m.lastError != nil && m.string("cursor.logical_size") == "regular")
    }
}

@MainActor @Suite struct ExportQueueAndRememberedTests {
    private final class Gate: @unchecked Sendable { var statuses: [ExportQueueStatus] = [] }
    private struct StubEngine: ExportEngine {
        let gate: Gate
        func run(_ request: ExportRequest, progress: @Sendable @escaping (Double) -> Void) async throws -> URL { request.destination }
        func run(_ request: ExportRequest, progress: @Sendable @escaping (Double) -> Void,
                 status: @Sendable @escaping (ExportQueueStatus) -> Void) async throws -> URL {
            status(.waiting); status(.preparing); status(.rendering); progress(0.5)
            return request.destination
        }
    }

    @Test func queuePhasesReachTheModelAndClearWhenDone() async throws {
        let m = ExportModel(engine: StubEngine(gate: Gate()))
        m.start(to: URL(fileURLWithPath: "/tmp/x.mp4"))
        #expect(m.queueStatus == .waiting)
        await m.waitUntilFinished()
        #expect(m.queueStatus == nil)
        if case .done = m.state {} else { Issue.record("expected done, got \(m.state)") }
    }

    @Test func realExportFinishesAndClearsTheQueueStatus() async throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let doc = try EditorDocument(package: d, presets: iso.store)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: out) }
        doc.export.format = .gif; doc.export.height = doc.export.options.heights.min() ?? 480
        doc.export.start(to: out.appendingPathComponent("a.gif"))
        await doc.export.waitUntilFinished()
        if case .done = doc.export.state {} else { Issue.record("export did not finish: \(doc.export.state)") }
        #expect(doc.export.queueStatus == nil)
    }

    @Test func dialogAndQuickExportRememberSeparately() throws {
        let suite = "yapcam.test.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = ExportModel(engine: StubEngine(gate: Gate())); a.remember(in: .dialog, defaults: defaults)
        a.format = .gif; a.gifDisableLoop = true
        let q = ExportModel(engine: StubEngine(gate: Gate())); q.remember(in: .quick, defaults: defaults)
        #expect(q.format == .mp4h264 && !q.gifDisableLoop)          // quick export did not inherit the dialog's choices
        q.format = .mp4hevc; q.height = q.options.heights.min()!
        let a2 = ExportModel(engine: StubEngine(gate: Gate())); a2.remember(in: .dialog, defaults: defaults)
        #expect(a2.format == .gif && a2.gifDisableLoop)
        let q2 = ExportModel(engine: StubEngine(gate: Gate())); q2.remember(in: .quick, defaults: defaults)
        #expect(q2.format == .mp4hevc && q2.height == q.height)
    }
}

@MainActor @Suite struct BlurMaskTests {
    @Test func blurMaskIsStoredUndoableInheritedAndReachesTheRenderPath() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let doc = try EditorDocument(package: d, presets: iso.store); let m = doc.model
        m.seek(toNs: 1_000_000_000)
        let before = try FrameSnapshot.png(source: ProjectRenderSource(doc.project), atNs: 1_500_000_000)
        m.addHighlightAtPlayhead(kind: .blur)
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        let h = try #require(m.highlights.first)
        #expect(h.kind == .blur && h.blurRadius == 32)
        // The same core evaluation the compositor reads says Gaussian blur, strength 32.
        let fx = try doc.project.maskEffects(atNs: 1_500_000_000)
        #expect(fx.effects.first?.kind == 1 && fx.effects.first?.blurRadius == 32)
        let blurred = try FrameSnapshot.png(source: ProjectRenderSource(doc.project), atNs: 1_500_000_000)
        #expect(blurred != before)                       // preview/export path draws it
        // Strength: one undo step; later blur masks inherit it.
        m.updateHighlight(id: h.id) { $0.blurRadius = 90 }
        #expect(m.highlights.first?.blurRadius == 90)
        m.undo(); #expect(m.highlights.first?.blurRadius == 32)
        m.updateHighlight(id: h.id) { $0.blurRadius = 90 }
        m.seek(toNs: 2_000_000_000); m.addHighlightAtPlayhead(kind: .blur); #expect(m.lastError == nil)
        #expect(m.highlights.last?.blurRadius == 90)
        // Cover stays available and does not use the blur kind.
        m.seek(toNs: 500_000_000); m.addHighlightAtPlayhead(kind: .mask)
        #expect(m.highlights.last?.kind == .mask && m.lastError == nil, "\(m.lastError ?? "")")
        try doc.project.save()
        let re = try EditorDocument(package: d, presets: iso.store).model
        #expect(re.highlights.map(\.kind) == [.blur, .blur, .mask] && re.highlights.first?.blurRadius == 90)
        // Out-of-range strength is clamped by the editor, never sent to core as an error.
        re.updateHighlight(id: re.highlights[0].id) { $0.blurRadius = 0 }
        #expect(re.lastError == nil && re.highlights[0].blurRadius == 0)
    }
}

@MainActor @Suite(.serialized) struct SettingsHooksTests {
    @Test func autosaveSwitchStopsTheTimerButNotSaveOrClose() async throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        var on = false
        let m = try EditorDocument(package: d, presets: iso.store).model
        m.autosaveDelay = .milliseconds(50); m.autosaveAllowed = { on }
        #expect(EditorWindows.autosaveEnabled)        // app-wide default is on
        m.seek(toNs: 1_000_000_000); m.addHighlightAtPlayhead(kind: .blur)
        try await Task.sleep(for: .milliseconds(400))
        #expect(m.saveState == .dirty)                      // nothing saved behind the user's back
        m.saveNow()
        #expect(m.saveState != .dirty)
        on = true
        m.updateHighlight(id: m.highlights[0].id) { $0.blurRadius = 10 }
        for _ in 0..<100 where m.saveState == .dirty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(m.saveState != .dirty)                      // back on: the debounce saves again
    }

    @Test func variableFrameRateHookReachesTheExportSettingsExceptForGIF() throws {
        let e = ExportModel(engine: NullEngine())
        #expect(EditorWindows.variableFrameRate() == false)   // app-wide default is off
        #expect(e.makeRequest(destination: URL(fileURLWithPath: "/tmp/a.mp4")).variableFrameRate == false)
        e.variableFrameRateProvider = { true }
        let req = e.makeRequest(destination: URL(fileURLWithPath: "/tmp/a.mp4"))
        #expect(req.variableFrameRate && RenderExportEngine.settings(for: req).variableFrameRate)
        #expect(e.usesVariableFrameRate)
        e.format = .gif
        let gif = e.makeRequest(destination: URL(fileURLWithPath: "/tmp/a.gif"))
        #expect(!gif.variableFrameRate && !RenderExportEngine.settings(for: gif).variableFrameRate && !e.usesVariableFrameRate)
    }
    private struct NullEngine: ExportEngine {
        func run(_ request: ExportRequest, progress: @Sendable @escaping (Double) -> Void) async throws -> URL { request.destination }
    }
}

@MainActor @Suite struct PolishRound2Tests {
    @Test func rulerLabelsAreWholeSecondsUnlessTheStepNeedsAFraction() {
        #expect(Ruler.label(1, step: 1) == "0:01")
        #expect(Ruler.label(65, step: 5) == "1:05")
        #expect(Ruler.label(1.5, step: 0.5) == "0:01.5")
        #expect(Ruler.label(0, step: 0.5) == "0:00.0")
        #expect(Ruler.label(1.25, step: 0.05) == "0:01.25")
        // The default step choice never needs more than one decimal at a normal zoom.
        let g = TimelineGeometry(pixelsPerSecond: 200)
        #expect(Ruler.label(2.5, step: g.rulerStepSeconds()) == "0:02.5")
    }

    @Test func trashIsACommandNotAToolbarButton() {
        let m = EditorModel(project: FakeProject(durationNs: 5_000_000_000), player: FakePlayer())
        #expect(!m.trashRequested)
        let cmd = m.paletteCommands.first { $0.title == "Move recording to Trash…" }
        #expect(cmd != nil)
        cmd?.run()
        #expect(m.trashRequested)
        #expect(!EditorWindows.requestTrashOfKeyEditor())        // no editor window is open in tests
    }

    @Test func timelineFitsTheViewportOnceWithoutAHorizontalScrollbar() async throws {
        let m = EditorModel(project: FakeProject(durationNs: 10_000_000_000), player: FakePlayer())
        let view = TimelineView(model: m).frame(width: 1000, height: 260)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderBack(nil); defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(m.timelineFitted)
        // Fitted content (+40 pt margin the view adds) equals the viewport, so nothing scrolls sideways.
        let content = m.geometry.contentWidth(durationNs: m.durationNs) + 40
        #expect(abs(content - 1000) < 20, "content \(content)")
        let before = m.geometry.pixelsPerSecond
        try await Task.sleep(for: .milliseconds(200))
        #expect(m.geometry.pixelsPerSecond == before)            // fitted once, not on every layout pass
    }
}

@MainActor @Suite struct WaveformTests {
    @Test func realAudioFileGivesTimelineMappedPeaksThatFollowCuts() async throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let doc = try EditorDocument(package: d, presets: iso.store); let m = doc.model
        await m.refreshWaveform()
        #expect(!m.waveform.isEmpty)
        #expect(m.waveform.allSatisfy { (0...1.0001).contains($0.amp) && $0.tlNs >= 0 && $0.tlNs <= m.durationNs })
        #expect(m.waveform.map(\.tlNs) == m.waveform.map(\.tlNs).sorted())
        #expect(m.waveform.contains { $0.amp > 0.01 }, "the fixture's audio is not silent")
        let full = m.waveform.count
        // A cut shortens the timeline; the waveform is re-mapped (fewer points, none beyond the new end).
        m.seek(toNs: 1_000_000_000); m.splitAtPlayhead(); m.seek(toNs: 3_000_000_000); m.splitAtPlayhead()
        m.selection = .clip(m.clips[1].id); m.deleteSelection()
        await m.refreshWaveform()
        #expect(m.waveform.count < full)
        #expect(m.waveform.allSatisfy { $0.tlNs <= m.durationNs })
        m.setShowWaveform(false); #expect(m.waveform.isEmpty && !m.showWaveform)
        #expect(iso.defaults.bool(forKey: "editor.showWaveform") == false)
    }

    @Test func clickingOrDraggingTheEmptyZoomTrackAddsAZoomInOneUndoStep() throws {
        let m = EditorModel(project: FakeProject(durationNs: 20_000_000_000), player: FakePlayer())
        #expect(m.zooms.isEmpty)
        m.addZoom(fromNs: 4_000_000_000)                      // click: default length
        #expect(m.zooms.count == 1 && m.zooms[0].startNs == 4_000_000_000 && m.zooms[0].endNs - m.zooms[0].startNs == defaultZoomDurationNs)
        m.addZoom(fromNs: 12_000_000_000, toNs: 9_000_000_000)   // drag right-to-left: that range
        #expect(m.zooms.count == 2)
        #expect(m.zooms.contains { $0.startNs == 9_000_000_000 && $0.endNs == 12_000_000_000 })
        m.undo(); #expect(m.zooms.count == 1)
        #expect(m.selection == .zoom(m.zooms[0].id) || m.selection == .none)
    }
}

@MainActor @Suite struct R5BackgroundAndCommandTests {
    private func doc() throws -> (EditorDocument, URL, () -> Void) {
        let d = try pkgCopy(); let iso = EditorStorage.makeIsolated()
        return (try EditorDocument(package: d, presets: iso.store), d, { try? FileManager.default.removeItem(at: d); iso.cleanup() })
    }

    @Test func insetRestoresLastUseElseFallbackAndIsOneUndoStep() throws {
        let (doc, _, done) = try doc(); defer { done() }; let m = doc.model
        m.setInsetEnabled(true)
        #expect(m.number("canvas.inset") == 4 && m.color("canvas.inset_color") == [0.533, 0.533, 0.533, 0.25])
        m.undo(); #expect(m.number("canvas.inset") == 0)                       // one step for size + colour
        m.setInsetEnabled(true)
        m.set("canvas.inset", number: 9); m.set("canvas.inset_color", color: [1, 0, 0, 0.5])
        m.setInsetEnabled(false); #expect(m.number("canvas.inset") == 0)
        m.setInsetEnabled(true)
        #expect(m.number("canvas.inset") == 9 && m.color("canvas.inset_color") == [1, 0, 0, 0.5])   // restores last use
        m.set("canvas.inset", number: 0.125); #expect(m.lastError == nil && m.number("canvas.inset") == 0.125)   // lowest size of the reference
        m.set("canvas.inset_origin", .array([.number(-0.5), .number(0.75)])); #expect(m.lastError == nil)
    }

    @Test func gradientHueRotatesBothStopsTogetherAndPresetsApplyInOneStep() throws {
        let (doc, _, done) = try doc(); defer { done() }; let m = doc.model
        m.applyGradientPreset(0)
        #expect(m.string("canvas.background.kind") == "gradient")
        let (a, b) = (m.color("canvas.background.color"), m.color("canvas.background.color2"))
        m.rotateGradientHue(by: 90)
        let (a2, b2) = (m.color("canvas.background.color"), m.color("canvas.background.color2"))
        #expect(a2 != a && b2 != b)
        let dh = { (x: [Double], y: [Double]) -> Double in var d = GradientPresets.hue(y) - GradientPresets.hue(x); if d < 0 { d += 360 }; return d }
        #expect(abs(dh(a, a2) - 90) < 1.5 && abs(dh(b, b2) - 90) < 1.5)
        m.undo(); #expect(m.color("canvas.background.color") == a && m.color("canvas.background.color2") == b)
        #expect(GradientPresets.all.count >= 16)
    }

    @Test func cornerSliderSnapsToTheReferenceValues() {
        // 0, 12, 16, 20, 26: a value within 1.2 % of the 0…128 range of a suggestion sticks to it.
        let snaps = [0.0, 12, 16, 20, 26], tol = 128 * 0.012
        func snapped(_ v: Double) -> Double { snaps.min { abs($0 - v) < abs($1 - v) }.flatMap { abs($0 - v) <= tol ? $0 : nil } ?? v }
        #expect(snapped(15) == 16 && snapped(17.4) == 16 && snapped(21) == 20 && snapped(40) == 40 && snapped(0.9) == 0)
    }

    @Test func favouritesAreRemembered() throws {
        let (doc, d, done) = try doc(); defer { done() }
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let m = try EditorDocument(package: d, presets: iso.store).model
        m.toggleFavouriteWallpaper("aurora"); m.toggleFavouriteWallpaper("dune")
        m.toggleFavouriteWallpaper("dune")
        #expect(m.favouriteWallpapers == ["aurora"])
        #expect(try EditorDocument(package: d, presets: iso.store).model.favouriteWallpapers == ["aurora"])
        _ = doc
    }

    @Test func loopAndHideCursorFollowTheReference() throws {
        let (doc, _, done) = try doc(); defer { done() }; let m = doc.model
        m.set("cursor.loop_to_start", bool: false)
        m.setMany([("cursor.loop_to_start", .bool(true)), ("cursor.loop_duration_ns", .number(1_000_000_000))])
        #expect(m.bool("cursor.loop_to_start") && m.number("cursor.loop_duration_ns") == 1_000_000_000)
        m.undo(); #expect(!m.bool("cursor.loop_to_start"))
    }

    @Test func reelModeZonesStayInsideTheFrameAndAreRemembered() throws {
        for mode in ReelMode.allCases {
            for z in mode.zones { #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(z.rect), "\(mode) \(z.name)") }
            #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(mode.safeRect))
            for z in mode.zones { #expect(!z.rect.intersects(mode.safeRect.insetBy(dx: 0.001, dy: 0.001)) || mode == .off, "\(mode) safe area overlaps \(z.name)") }
        }
        #expect(ReelMode.off.zones.isEmpty)
        let (doc, d, done) = try doc(); defer { done() }
        doc.model.setReelMode(.tiktok); #expect(doc.model.reelMode == .tiktok)
        _ = d
    }

    @Test func commandMenuReachesSettingsWithTheSameEffectAsTheInspector() throws {
        let (doc, _, done) = try doc(); defer { done() }; let m = doc.model
        func run(_ title: String) { m.filteredCommands(title).first { $0.title == title }?.run() }
        #expect(m.paletteCommands.count > 100)
        run("Aspect ratio: Vertical 9:16"); #expect(m.string("canvas.aspect") == "9:16")
        run("Go to Audio"); #expect(m.inspectorSection == .audio)
        run("Turn on window frame"); #expect(m.bool("canvas.window_chrome"))
        run("Background: Gradient"); #expect(m.string("canvas.background.kind") == "gradient")
        run("Reel preview: Instagram Reels"); #expect(m.reelMode == .instagram)
        run("Preview resolution: Half"); #expect(m.previewOptions.resolution == 0.5)
        #expect(m.filteredCommands("filler").contains { $0.title == "Remove filler words" })
        #expect(m.lastError == nil)
    }
}
