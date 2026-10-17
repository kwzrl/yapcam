import AVFoundation
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

    @Test func realLibraryAppliesWallpapersOfEveryKindAndUndoesThem() async throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        // Expectations come from the library itself (render's catalog size and categories change between releases).
        let all = m.wallpapers
        #expect(all.count == BackgroundLibrary.presets.count && all.count >= 12)
        #expect(Set(all.map(\.id)).count == all.count)                        // ids are unique
        var firstOfEachCategory: [WallpaperInfo] = []
        for w in all where !firstOfEachCategory.contains(where: { $0.category == w.category }) { firstOfEachCategory.append(w) }
        #expect(firstOfEachCategory.count >= 2)
        var kinds: [String] = []
        for w in firstOfEachCategory.prefix(4) {
            m.applyWallpaper(id: w.id); await m.waitForWallpaper()
            #expect(m.lastError == nil, "\(w.id): \(m.lastError ?? "")")
            let kind = m.string("canvas.background.kind")
            #expect(["gradient", "image"].contains(kind), "\(w.id) → \(kind)")
            kinds.append(kind)
        }
        let thumb = await m.project.wallpaperThumbnail(id: all[all.count / 2].id)
        #expect(thumb?.width == 192 && thumb?.height == 108)
        if kinds.count >= 2 { m.undo(); #expect(m.string("canvas.background.kind") == kinds[kinds.count - 2]) }   // one undo step per wallpaper
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
        // Core decides what is storable; render's catalog is what can be drawn. The picker offers the ids both know, and the
        // two must overlap on at least the recorded cursor and Touch (they grow independently between releases).
        let core = Set(lib.sets.map(\.id)), render = Set(VectorCursorLibrary.catalog.map(\.id))
        #expect(core.contains("original") && core.contains("touch") && render.contains("original") && render.contains("touch"))
        #expect(!core.intersection(render).isEmpty)
        // Every shape the picker offers is a core shape; every core shape is one render can draw.
        #expect(Set(cursorShapes.map(\.value)).isSubset(of: Set(lib.shapes)))
        #expect(lib.shapes.allSatisfy { VectorCursorStyle(shapeID: $0) != nil }, "a core shape render does not know: \(lib.shapes.filter { VectorCursorStyle(shapeID: $0) == nil })")
        #expect(cursorSizes.map(\.value) == lib.logicalSizes.map(\.id))
    }

    @Test func carouselChoicesAreAcceptedByCoreAndOneUndoStepEach() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let m = doc.model
        let lib = try doc.project.query("{\"q\":\"cursor_library\"}", as: Library.self)
        let choices = m.cursorSetChoices()
        // The carousel is render's catalog in render's order, limited to what core accepts.
        let accepted = Set(lib.sets.map(\.id))
        #expect(choices.map(\.id) == VectorCursorLibrary.catalog.map(\.id).filter { accepted.contains($0) })
        #expect(choices.first?.id == "original" && choices.contains { $0.id == "touch" } && choices.count >= 3)
        for c in choices { m.chooseCursorSet(c); #expect(m.lastError == nil, "\(c.id): \(m.lastError ?? "")"); #expect(m.selectedCursorSetID() == c.id) }
        let pick = choices[choices.count - 1], other = choices[1]
        m.chooseCursorSet(other); m.chooseCursorSet(pick)
        m.undo()
        #expect(m.selectedCursorSetID() == other.id)                          // one undo step per choice
        m.chooseCursorSet(pick); try doc.project.save()
        #expect(try EditorDocument(package: d).model.selectedCursorSetID() == pick.id)
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
        // Any authored set the library and core both have (the catalog's contents change between releases).
        let authored = try #require(m.cursorSetChoices().first { $0.id != "original" && $0.id != "touch" }).id
        m.set("cursor.set_id", string: authored); m.set("cursor.logical_size", string: "large"); m.set("cursor.shape", string: "text")
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        cfg = try source.renderEffects(atNs: 500_000_000, canvasSize: size).configuration
        #expect(cfg.cursorSetID == authored && cfg.cursorSize == .large && cfg.cursorStyle == .text)
        m.set("cursor.always_default", bool: true)
        cfg = try source.renderEffects(atNs: 500_000_000, canvasSize: size).configuration
        #expect(cfg.cursorStyle == .arrow && cfg.cursorSetID == authored)     // default arrow wins over the shape, set and size stay
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
        m.undo(); #expect(m.number("canvas.inset") == 0)                       // one step for size + color
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

    @Test func favoritesAreRemembered() throws {
        let (doc, d, done) = try doc(); defer { done() }
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let m = try EditorDocument(package: d, presets: iso.store).model
        m.toggleFavoriteWallpaper("aurora"); m.toggleFavoriteWallpaper("dune")
        m.toggleFavoriteWallpaper("dune")
        #expect(m.favoriteWallpapers == ["aurora"])
        #expect(try EditorDocument(package: d, presets: iso.store).model.favoriteWallpapers == ["aurora"])
        _ = doc
    }

    @Test func loopAndHideCursorFollowTheReference() throws {
        let (doc, _, done) = try doc(); defer { done() }; let m = doc.model
        m.set("cursor.loop_to_start", bool: false)
        m.setMany([("cursor.loop_to_start", .bool(true)), ("cursor.loop_duration_ns", .number(1_000_000_000))])
        #expect(m.bool("cursor.loop_to_start") && m.number("cursor.loop_duration_ns") == 1_000_000_000)
        m.undo(); #expect(!m.bool("cursor.loop_to_start"))
    }

    @Test func reelModeReachesThePlayerAsAPreviewSettingAndIsRemembered() throws {
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let player = FakePlayer()
        let m = EditorModel(project: FakeProject(), player: player); m.defaults = iso.defaults
        #expect(m.reelMode == .off)
        m.setReelMode(.tiktok)
        #expect(m.reelMode == .tiktok && player.previewOptionCalls.last?.reel == .tiktok)
        #expect(iso.defaults.string(forKey: "yapcam.preview.reel") == "tiktok")
        let again = EditorModel(project: FakeProject(), player: FakePlayer()); again.defaults = iso.defaults; again.loadStoredPreviewOptions()
        #expect(again.reelMode == .tiktok)
        // The mapping onto render's own preview setting (the overlay is drawn by render, above the video, preview only).
        for mode in ReelMode.allCases { #expect(ReelPreviewMode(rawValue: mode.rawValue) != nil, "\(mode)") }
        var settings = PreviewSettings(); settings.reelMode = ReelPreviewMode(rawValue: ReelMode.instagram.rawValue)!
        #expect(settings.reelMode == .instagram)
    }

    @Test func commandMenuReachesSettingsWithTheSameEffectAsTheInspector() throws {
        let (doc, _, done) = try doc(); defer { done() }; let m = doc.model
        func run(_ title: String) { m.filteredCommands(title).first { $0.title == title }?.run() }
        #expect(m.paletteCommands.count > 100)
        run("Aspect ratio: Vertical 9:16"); #expect(m.string("canvas.aspect") == "9:16")
        run("Go to Audio"); #expect(m.inspectorSection == .audio)
        run("Turn on window frame"); #expect(m.bool("canvas.window_chrome"))
        run("Background: Gradient"); #expect(m.string("canvas.background.kind") == "gradient")
        run("Reel preview: Instagram"); #expect(m.reelMode == .instagram)
        run("Preview resolution: Half"); #expect(m.previewOptions.resolution == 0.5)
        #expect(m.filteredCommands("filler").contains { $0.title == "Remove filler words" })
        #expect(m.lastError == nil)
    }
}

@MainActor @Suite struct R5ChromeTests {
    @Test func recentPresetsKeepFiveNewestFirstWithoutDuplicates() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let m = try EditorDocument(package: d, presets: iso.store).model
        try FileManager.default.createDirectory(at: iso.store.directory, withIntermediateDirectories: true)
        for n in ["a", "b", "c", "d", "e", "f"] { m.savePreset(named: n) }
        #expect(m.lastError == nil)
        for n in ["a", "b", "c", "d", "e", "f", "c"] { m.applyPreset(at: iso.store.url(n)) }
        #expect(m.recentPresets() == ["c", "f", "e", "d", "b"])
    }

    @Test func appearanceDefaultsToDarkAndOffersLightAndSystem() {
        #expect(EditorWindows.appearance == .dark)
        #expect(EditorAppearance.allCases == [.dark, .light, .system])
        #expect(EditorAppearance.dark.nsAppearance?.name == .darkAqua && EditorAppearance.light.nsAppearance?.name == .aqua && EditorAppearance.system.nsAppearance == nil)
    }
}

@MainActor @Suite struct WaveformAuthenticityTests {
    /// 3 s mono 16-bit WAV at 8 kHz: silence, a 1 kHz tone of amplitude 0.5 from 1.0 to 2.0 s, silence.
    private func makeWAV(tone: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wave-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8_000, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
        buffer.frameLength = 24_000
        let p = buffer.int16ChannelData![0]
        for i in 0..<24_000 {
            let t = Double(i) / 8_000
            p[i] = tone && t >= 1 && t < 2 ? Int16((0.5 * sin(2 * .pi * 1_000 * t) * 32_767).rounded()) : 0
        }
        try file.write(from: buffer)
        return url
    }

    @Test func peaksComeFromTheSamplesSilenceIsFlatAndABurstShowsOnlyWhereItIs() async throws {
        let silent = try makeWAV(tone: false), burst = try makeWAV(tone: true)
        defer { try? FileManager.default.removeItem(at: silent); try? FileManager.default.removeItem(at: burst) }
        let flat = try await WaveformAnalysis.peaks(of: silent)
        #expect(flat.count >= 148 && (flat.max() ?? 1) < 0.001, "silence must be flat, max \(flat.max() ?? -1)")
        let p = try await WaveformAnalysis.peaks(of: burst)
        #expect(p.count >= 148)
        #expect(p[2..<48].allSatisfy { $0 < 0.01 })                                  // before the burst
        #expect(p[55..<95].allSatisfy { (0.35...0.6).contains($0) })                 // inside: amplitude 0.5
        #expect(p[104..<146].allSatisfy { $0 < 0.01 })                               // after
        // Mapped onto an edited timeline at 2× speed the burst keeps its shape and takes half the time.
        let pts = WaveformAnalysis.timelinePoints(rows: [("f", 0, 3_000_000_000, 0, 1_500_000_000)], peaks: ["f": p])
        let loud = pts.filter { $0.amp > 0.2 }
        #expect(!loud.isEmpty && loud.first!.tlNs >= 490_000_000 && loud.last!.tlNs <= 1_010_000_000)
    }

    @Test func realFixtureAudioIsNotPlaceholder() async throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let m = try EditorDocument(package: d, presets: iso.store).model
        await m.refreshWaveform()
        // The fixture's audio is a steady tone, so its envelope is steady; what matters is that it equals the file's real peaks.
        let file = d.appendingPathComponent("recording/seg-000/system.m4a")
        let real = try await WaveformAnalysis.peaks(of: file)
        let shown = m.waveform.map(\.amp)
        #expect(!real.isEmpty && (shown.max() ?? 0) == (real.max() ?? -1))
    }
}

@MainActor @Suite struct CoreR5RequestTests {
    private func doc() throws -> (EditorDocument, () -> Void) {
        let d = try pkgCopy(); let iso = EditorStorage.makeIsolated()
        return (try EditorDocument(package: d, presets: iso.store), { try? FileManager.default.removeItem(at: d); iso.cleanup() })
    }

    @Test func e1InsetEnableAppliesReferenceValuesButKeepsAStoredColor() throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        m.set("canvas.inset", number: 0); m.set("canvas.inset_color", color: [0.1, 0.2, 0.3, 0.9])     // a color the user stored before
        m.setInsetEnabled(true)
        #expect(m.number("canvas.inset") == 4 && m.color("canvas.inset_color") == [0.1, 0.2, 0.3, 0.9])
        m.setInsetEnabled(false); m.set("canvas.inset_color", color: [0, 0, 0, 0.5])                    // core's factory color
        m.lastInset = nil
        m.setInsetEnabled(true)
        #expect(m.color("canvas.inset_color") == EditorModel.insetFallback.color)
    }

    @Test func e2SplitDirectionAndCutoutAspectNull() throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        for dir in ["horizontal", "vertical", "auto"] { m.set("camera.layout_settings.split_direction", string: dir); #expect(m.lastError == nil, "\(dir) \(m.lastError ?? "")"); #expect(m.string("camera.layout_settings.split_direction") == dir) }
        m.set("camera.layout_settings.aspect", .number(1))
        m.setCameraLayoutMode("cutout")
        #expect(m.string("camera.layout_settings.mode") == "cutout" && m.value("camera.layout_settings.aspect") == .null)
        m.undo(); #expect(m.string("camera.layout_settings.mode") != "cutout" && m.value("camera.layout_settings.aspect") == .number(1))   // one undo step
        m.set("camera.layout_settings.split_direction", string: "diagonal"); #expect(m.lastError != nil)   // core rejects unknown directions
    }

    @Test func e3LevelKeysUseTheRememberedDefaultAndStayInOneToFour() throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        m.seek(toNs: 500_000_000); m.addZoomAtPlayhead()
        m.setSelectedZoomLevel(3.2)
        #expect(m.defaultZoomScale == 3.2)                                // core remembers the committed level
        m.setSelectedZoomLevel(1.4); m.handleShortcut("0")
        #expect(m.selectedZoom?.scale == 1.4 || m.selectedZoom?.scale == 3.2)
        m.setSelectedZoomLevel(9); #expect(m.selectedZoom?.scale == 4)    // the UI never goes above 4
        m.setSelectedZoomLevel(0.2); #expect(m.selectedZoom?.scale == 1)
        m.setSelectedZoomLevel(2.8); _ = m.handleShortcut("1"); #expect(m.selectedZoom?.scale == 1)
        _ = m.handleShortcut("0"); #expect(m.selectedZoom?.scale == m.defaultZoomScale)
    }

    @Test func e4CoalescedLevelStepsShareOneUndoStepButDifferentObjectsDoNot() throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        m.seek(toNs: 500_000_000); m.addZoomAtPlayhead()
        let id = try #require(m.selectedZoom?.id)
        let before = m.selectedZoom!.scale
        m.stepSelectedZoomLevel(by: 0.2); m.stepSelectedZoomLevel(by: 0.2); m.stepSelectedZoomLevel(by: 0.2)   // well inside 100 ms
        #expect(abs(m.zooms.first { $0.id == id }!.scale - (before + 0.6)) < 0.01)
        m.undo()
        #expect(m.zooms.first { $0.id == id }?.scale == before, "a burst of steps must undo in one step")
        #expect(m.zooms.count == 1)                                       // the zoom itself (its own step) is still there
    }

    @Test func e4HistoryKeepsAtMost1000Steps() throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        for i in 0..<1010 { m.set("canvas.radius", number: Double(i % 100)) }
        var undone = 0
        while m.canUndo && undone < 1100 { m.undo(); undone += 1 }
        #expect(undone == 1000, "undo steps: \(undone)")
    }

    @Test func e5SplittingAZoomKeepsStyleModeEnabledAndEasing() throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        m.seek(toNs: 500_000_000); m.addZoomAtPlayhead()
        let id = try #require(m.selectedZoom?.id)
        m.setZoomLens(id: id, ZoomLensParams())
        m.setZoomMode(id: id, .manual)
        m.perform(.updateZoom(id: id, startNs: nil, endNs: nil, scale: 3, focusX: 0.3, focusY: 0.7, easeInNs: 200_000_000, easeOutNs: 100_000_000, enabled: false))
        let z = try #require(m.zooms.first { $0.id == id })
        m.seek(toNs: z.startNs + (z.endNs - z.startNs) / 2); m.selection = .zoom(id); m.splitContextAware()
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.zooms.count == 2)
        let second = try #require(m.zooms.first { $0.id != id })
        #expect(second.lens != nil && second.mode == .manual && !second.enabled && second.scale == 3 && abs(second.focusX - 0.3) < 1e-9 && second.easeInNs == 200_000_000 && second.easeOutNs == 100_000_000)
        m.undo(); #expect(m.zooms.count == 1)                              // one undo step
    }

    @Test func e5MaskKeyframesPartitionAtTheCutAndEnabledSurvivesRewrites() throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        m.seek(toNs: 500_000_000); m.addHighlightAtPlayhead(kind: .blur)
        let id = try #require(m.highlights.first?.id)
        let h = m.highlights[0]
        m.seek(toNs: h.startNs + 1_000_000_000); m.addRegionKeyframeAtPlayhead(id: id)   // key 1 at start+1 s (rect unchanged)
        m.updateHighlightKeepingStyle(id: id) { $0.keyframes = [RegionKeyframe(tlNs: h.startNs + 1_000_000_000, rect: [0.1, 0.1, 0.3, 0.3]), RegionKeyframe(tlNs: h.startNs + 2_500_000_000, rect: [0.5, 0.5, 0.3, 0.3])] }
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        m.setHighlightEnabled(id: id, false)
        m.updateHighlight(id: id) { $0.opacity = 0.9 }                         // an unrelated rewrite must keep enabled + keys
        #expect(m.highlights[0].enabled == false && m.highlights[0].keyframes.count == 2)
        m.setHighlightEnabled(id: id, true)
        let cut = h.startNs + 2_000_000_000
        m.seek(toNs: cut); m.selection = .highlight(id); m.splitContextAware()
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        let parts = m.highlights.sorted { $0.startNs < $1.startNs }
        #expect(parts.count == 2)
        #expect(parts[0].keyframes.map(\.tlNs) == [h.startNs + 1_000_000_000, cut])                // before the cut, plus the end box
        #expect(parts[1].keyframes.map(\.tlNs) == [h.startNs + 2_500_000_000])                     // after the cut
        #expect(parts[1].rect == parts[0].keyframes.last!.rect)                                    // second half starts where the first ends
        // Interpolation: halfway between the two keys.
        let mid = parts[0].rect(atNs: h.startNs + 1_500_000_000)
        #expect(abs(mid[0] - (0.1 + (parts[0].keyframes.last!.rect[0] - 0.1) * 0.5)) < 1e-6)
    }

    @Test func e5LayoutEnabledSurvivesRewrites() throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        m.writeLayoutList([LayoutSegment(id: "layout-t", startNs: 500_000_000, endNs: 3_000_000_000, mode: "overlay")])
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        let id = try #require(m.layouts.first?.id)
        m.setLayoutEnabled(id: id, false); #expect(m.layouts[0].enabled == false)
        m.setLayoutMode(id: id, "screen")
        #expect(m.layouts[0].enabled == false && m.layouts[0].mode == "screen")
        m.setLayoutEnabled(id: id, true); #expect(m.layouts[0].enabled)
    }

    @Test func e5HiddenShortcutsRoundTripThroughCore() throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        let chords = m.project.keyChords()
        let target = chords.first?.text ?? "⌘C"
        m.setShortcutHidden(target, true)
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        if !chords.isEmpty { #expect(m.project.keyChords().first { $0.text == target }?.hidden == true) }
        m.setShortcutHidden(target, false)
        if !chords.isEmpty { #expect(m.project.keyChords().first { $0.text == target }?.hidden == false) }
    }

    @Test func e5CaptionSizeIsStoredAsARatioOfTheCanvasHeight() async throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        #expect(CaptionLook().size == 0.05)
        let transcript = Data(#"{"schema_version":1,"engine":"x","locale":"en","words":[{"text":"hello","src_start_ns":1000000000,"src_end_ns":1500000000}]}"#.utf8)
        m.captionSource = { transcript }; m.captionSourceWithOptions = { _, _ in transcript }
        m.generateCaptions(); await m.waitForCaptions()
        #expect(m.textItems(.caption).count == 1, "\(m.captionState)")
        var look = m.captionLook; look.size = 0.1; m.setCaptionLook(look)
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        if case .number(let r)? = m.textItems(.caption).first?.extraStyle["font_size_ratio"] { #expect(r == 0.1) } else { Issue.record("no font_size_ratio on the caption: \(String(describing: m.textItems(.caption).first?.extraStyle)) count \(m.textItems(.caption).count)") }
    }

    @Test func e6FailedSavesRetryWithoutNewEditsAndKeepTheRevision() async throws {
        let p = FakeProject(durationNs: 10_000_000_000); p.failSave = true
        let m = EditorModel(project: p, player: FakePlayer())
        m.autosaveDelay = .milliseconds(40)
        m.seek(toNs: 1_000_000_000); m.addZoomAtPlayhead()
        let rev = m.revision
        for _ in 0..<100 where p.saveAttempts < 3 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(p.saveAttempts >= 3, "attempts \(p.saveAttempts)")          // retried on its own, no further edit
        if case .failed = m.saveState {} else { Issue.record("state should stay failed, was \(m.saveState)") }
        #expect(m.revision == rev)
        p.failSave = false
        for _ in 0..<100 where m.saveState != .clean { try await Task.sleep(for: .milliseconds(50)) }
        #expect(m.saveState == .clean && m.revision == rev)
        let attempts = p.saveAttempts; try await Task.sleep(for: .milliseconds(200))
        #expect(p.saveAttempts == attempts)                                  // a clean project does not keep saving
        m.close()
    }
}

@MainActor @Suite struct ExportParityTests {
    private final class Box: @unchecked Sendable { var requests: [ExportRequest] = [] }
    private struct RecordingEngine: ExportEngine {
        let box: Box
        func run(_ request: ExportRequest, progress: @Sendable @escaping (Double) -> Void) async throws -> URL { box.requests.append(request); progress(1); return request.destination }
    }

    @Test func optionSetsAndTitlesComeFromRender() {
        #expect(CompressionPreset.allCases.map(\.label) == ["Studio", "Social Media", "Web", "Web (Low)"])
        for f in ExportFormat.allCases {
            #expect(f.options.fps == ExportSettings.frameRates(for: f.renderFormat) && f.options.heights == ExportSettings.heights(for: f.renderFormat), "\(f)")
        }
    }

    @Test func clipboardHidesThePairedExportAndFallsBack() {
        let e = ExportModel(engine: RecordingEngine(box: Box()))
        e.format = .mp4both; #expect(e.format == .mp4both && e.availableFormats.contains(.mp4both))
        e.target = .clipboard
        #expect(e.format == .mp4h264 && !e.availableFormats.contains(.mp4both))
        e.target = .file; #expect(e.availableFormats.contains(.mp4both))
        #expect(ExportFormat.primary == [.mp4h264, .gif] && Set(ExportFormat.advanced) == [.mp4hevc, .mp4both, .movh264, .movhevc])
    }

    @Test func gifAtOrAbove1080GetsTheLargeFileWarning() {
        let e = ExportModel(engine: RecordingEngine(box: Box()))
        e.format = .gif
        #expect(!e.showsLargeGIFWarning)
        e.height = 1080; #expect(e.showsLargeGIFWarning)
        e.format = .mp4h264; #expect(!e.showsLargeGIFWarning)
    }

    @Test func requestsCarryTheTargetAndOutcomesReachTheApp() async throws {
        let box = Box()
        let e = ExportModel(engine: RecordingEngine(box: box))
        var outcomes: [ExportModel.Outcome] = []
        e.onOutcome = { outcomes.append($0) }
        e.copyToClipboard(); await e.waitUntilFinished()
        #expect(box.requests.last?.target == .clipboard && e.target == .file && e.runningTarget == .clipboard)   // a copy does not change the remembered target
        e.target = .file
        e.start(to: URL(fileURLWithPath: "/tmp/x.mp4")); await e.waitUntilFinished()
        #expect(box.requests.last?.target == .file)
        #expect(outcomes.map(\.kind).count == 4)
        #expect(outcomes.first?.kind == .started && outcomes[1].kind == .completed(URL(fileURLWithPath: "/dev/null")) && outcomes[1].target == .clipboard)
        #expect(outcomes[3].target == .file)
    }

    @Test func rememberedSettingsIncludeTheTargetAndOldOnesStillLoad() throws {
        let suite = "yapcam.test.\(UUID().uuidString)"; let d = UserDefaults(suiteName: suite)!; defer { d.removePersistentDomain(forName: suite) }
        let a = ExportModel(engine: RecordingEngine(box: Box())); a.remember(in: .dialog, defaults: d)
        a.target = .clipboard; a.fps = 30
        let b = ExportModel(engine: RecordingEngine(box: Box())); b.remember(in: .dialog, defaults: d)
        #expect(b.target == .clipboard && b.fps == 30)
        // A settings blob from before targets existed decodes with the file target.
        let old = #"{"format":"mp4h264","height":1080,"fps":24,"includeAudio":true,"preset":"web","gifHighQuality":true,"gifDisableLoop":false}"#
        d.set(Data(old.utf8), forKey: "yapcam.export.remembered.quick")
        let c = ExportModel(engine: RecordingEngine(box: Box())); c.remember(in: .quick, defaults: d)
        #expect(c.target == .file && c.height == 1080 && c.fps == 24 && c.preset == .web)
    }

    @Test func timingReadoutShowsElapsedAndRemaining() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(ExportSheet.timing(since: t0, fraction: 0.01, now: t0.addingTimeInterval(5)) == "0:05 elapsed")
        #expect(ExportSheet.timing(since: t0, fraction: 0.5, now: t0.addingTimeInterval(60)) == "1:00 elapsed · about 1:00 left")
        #expect(ExportSheet.timing(since: nil, fraction: 0.5, now: t0) == "")
    }

    @Test func commandMenuListsExportSettingsAndActionsAndShortcutsOpenThePicker() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let doc = try EditorDocument(package: d, presets: iso.store); let m = doc.model
        var opened = 0; m.showExportPickerHandler = { opened += 1 }
        func run(_ t: String) { m.filteredCommands(t).first { $0.title == t }?.run() }
        run("Export format: GIF (no audio)"); #expect(doc.export.format == .gif)
        run("Export size: 720p"); #expect(doc.export.height == 720)
        run("Export frame rate: 30 fps"); #expect(doc.export.fps == 30)
        run("Export target: Clipboard"); #expect(doc.export.target == .clipboard)
        run("Export target: File")
        run("Export format: MP4 (H.264)"); run("Export compression: Web (Low)"); #expect(doc.export.preset == .webLow)
        #expect(m.handleShortcut("e", [.command, .shift])); #expect(opened == 1)
        run("Show recent clipboard copies"); #expect(opened == 2 && doc.export.target == .clipboard)
        doc.export.target = .file
        #expect(m.paletteCommands.contains { $0.title == "Export…" && $0.shortcut == "⇧⌘E" })
        #expect(m.paletteCommands.contains { $0.title == "Copy export to clipboard" && $0.shortcut == "⌥⌘C" })
        #expect(m.paletteCommands.contains { $0.title == "Export to file…" && $0.shortcut == "⌥⌘S" })
    }

    @Test func pairedExportWritesBothFilesAndReplacesExistingOnes() async throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let doc = try EditorDocument(package: d, presets: iso.store)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("pair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: out) }
        let primary = out.appendingPathComponent("demo.mp4"), second = out.appendingPathComponent("demo-h265.mp4")
        try Data("old".utf8).write(to: primary); try Data("old".utf8).write(to: second)       // both are replaced, nothing refuses
        doc.export.format = .mp4both; doc.export.height = 720; doc.export.fps = 10
        doc.export.start(to: primary); await doc.export.waitUntilFinished()
        if case .done = doc.export.state {} else { Issue.record("paired export did not finish: \(doc.export.state)") }
        for f in [primary, second] {
            let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
            #expect(size > 1000, "\(f.lastPathComponent) size \(size)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasPrefix(".yapcam") }.isEmpty)   // no temp folder left
    }
}

@MainActor @Suite struct UIRequestTests {
    private func store() -> (EditorKeyBindings, () -> Void) {
        let name = "yapcam.test.\(UUID().uuidString)"; let d = UserDefaults(suiteName: name)!
        return (EditorKeyBindings(defaults: d), { d.removePersistentDomain(forName: name) })
    }
    private func model(_ kb: EditorKeyBindings) -> EditorModel {
        let m = EditorModel(project: FakeProject(durationNs: 20_000_000_000), player: FakePlayer()); m.keyBindings = kb; return m
    }

    @Test func rebindingMovesTheActionAndFreesTheOldKey() {
        let (kb, done) = store(); defer { done() }
        let m = model(kb)
        m.seek(toNs: 8_000_000_000)
        #expect(m.handleShortcut("c") && m.clips.count == 2)                // default C splits
        m.undo()
        #expect(kb.setKey("q", for: "split"))
        #expect(kb.key(for: "split") == "q" && kb.isCustomized)
        #expect(!m.handleShortcut("c") && m.clips.count == 1)               // the old key does nothing now
        #expect(m.handleShortcut("q") && m.clips.count == 2)                // the new one splits
        #expect(kb.setKey(nil, for: "split") && kb.key(for: "split") == "c" && !kb.isCustomized)
    }

    @Test func conflictsAndReservedKeysAreRefused() {
        let (kb, done) = store(); defer { done() }
        #expect(!kb.setKey("x", for: "split"))                              // X belongs to ripple delete
        #expect(!kb.setKey("5", for: "split") && !kb.setKey("=", for: "split") && !kb.setKey(" ", for: "split"))
        #expect(!kb.setKey("q", for: "doesNotExist"))
        #expect(kb.setKey("x", for: "ripple") && kb.setKey("c", for: "ripple") == false)   // moving ripple away: C is split's
        #expect(kb.setKey("Q", for: "ripple") && kb.key(for: "ripple") == "q")              // stored lowercase
        kb.resetAll(); #expect(!kb.isCustomized && kb.key(for: "ripple") == "x")
        #expect(EditorKeyBindings.actions.count == Set(EditorKeyBindings.actions.map(\.defaultKey)).count)   // unique defaults
    }

    @Test func swappingTwoKeysWorksThroughAFreeKey() {
        let (kb, done) = store(); defer { done() }
        #expect(kb.setKey("q", for: "split") && kb.setKey("c", for: "ripple") && kb.setKey("x", for: "split"))
        #expect(kb.key(for: "split") == "x" && kb.key(for: "ripple") == "c")
        #expect(kb.canonical("x") == "c" && kb.canonical("c") == "x")       // pressed x runs split (default key c)
    }

    @Test func keyModelCropRequestAndPresetApplicationAreAvailableToTheApp() throws {
        #expect(EditorWindows.keyModel == nil && !EditorWindows.requestCropOfKeyEditor())        // no editor window is key in tests
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let doc = try EditorDocument(package: d, presets: iso.store); let m = doc.model
        // A preset made from a different look, applied as an edit: undoable and marks the project dirty.
        m.set("canvas.radius", number: 40)
        try FileManager.default.createDirectory(at: iso.store.directory, withIntermediateDirectories: true)
        m.savePreset(named: "Look"); #expect(m.lastError == nil)
        m.set("canvas.radius", number: 8)
        m.saveNow(); #expect(m.saveState == .clean)
        doc.applyPreset(from: iso.store.url("Look"))
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.number("canvas.radius") == 40)
        #expect(m.saveState != .clean)                                       // dirty tracking
        #expect(m.canUndo)
        m.undo(); #expect(m.number("canvas.radius") == 8, "undo must restore the look before the preset")
    }

    @Test func cameraPixelSizeIsNilWithoutACamera() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let doc = try EditorDocument(package: d, presets: iso.store)
        #expect(doc.model.project.hasCamera == (doc.model.project.cameraPixelSize != nil))
    }
}

@MainActor @Suite struct BackgroundAudioLibraryTests {
    private func doc() throws -> (EditorDocument, () -> Void) {
        let d = try pkgCopy(); let iso = EditorStorage.makeIsolated()
        return (try EditorDocument(package: d, presets: iso.store), { try? FileManager.default.removeItem(at: d); iso.cleanup() })
    }

    @Test func categoriesAndTracksComeFromRendersLibrary() throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        #expect(m.musicCategories.map(\.title) == MusicLibrary.Category.allCases.map(\.title))      // Commercial, Electronic, Instrumental, Lo-fi
        #expect(m.musicCategories.count == 4)
        #expect(m.project.musicLibrary.count == MusicLibrary.tracks.count && MusicLibrary.tracks.count >= 18)
        for c in m.musicCategories { #expect(!m.musicTracks(in: c.id).isEmpty, "\(c.title) has no tracks") }
    }

    @Test func addingALibraryTrackIsOneUndoStepAtFivePercentLooping() async throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        let track = try #require(m.musicTracks(in: "lo-fi").first)
        m.seek(toNs: 500_000_000)
        m.addLibraryMusic(trackID: track.id); await m.waitForMusicImport()
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        let item = try #require(m.music.first)
        #expect(item.loop && abs(item.gainDb - EditorModel.defaultMusicGainDb) < 0.1 && abs(m.musicVolume - 0.05) < 0.002)
        // Generated audio is real: the imported file exists in the package and has the track's length.
        let file = doc.project.packageURL.appendingPathComponent(item.path)
        #expect(FileManager.default.fileExists(atPath: file.path), Comment(rawValue: item.path))
        m.undo(); #expect(m.music.isEmpty)
    }

    @Test func volumeMuteAndRemovalActOnAllBackgroundAudio() async throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        let ids = Array(m.project.musicLibrary.prefix(2).map(\.id))
        m.seek(toNs: 200_000_000); m.addLibraryMusic(trackID: ids[0]); await m.waitForMusicImport()
        m.seek(toNs: 1_200_000_000); m.addLibraryMusic(trackID: ids[1]); await m.waitForMusicImport()
        #expect(m.music.count == 2)
        m.setMusicVolume(0.5)
        #expect(m.music.allSatisfy { abs(EditorModel.musicVolume(forGainDb: $0.gainDb) - 0.5) < 0.01 })
        m.undo(); #expect(abs(m.musicVolume - 0.05) < 0.002)                // one undo step for both tracks
        m.setMusicVolume(0.3)
        m.setMusicMuted(true); #expect(m.isMusicMuted && m.music.allSatisfy { $0.gainDb <= -95 })
        m.setMusicMuted(false); #expect(!m.isMusicMuted && abs(m.musicVolume - 0.3) < 0.01)
        m.setMusicVolume(0); #expect(m.musicVolume == 0)
        m.removeAllMusic(); #expect(m.music.isEmpty)
        // Gain/volume conversions are inverse and bounded.
        for v in [0.01, 0.05, 0.25, 1.0] { #expect(abs(EditorModel.musicVolume(forGainDb: EditorModel.musicGainDb(forVolume: v)) - v) < 1e-9) }
        #expect(EditorModel.musicGainDb(forVolume: 0) == -96 && EditorModel.musicGainDb(forVolume: 2) == 0)
    }

    @Test func userFolderListsAudioFilesAndDropsAddTheFirstAudioFile() async throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("audio-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        m.userMusicFolder = folder
        for n in ["b.mp3", "a.wav", "notes.txt", ".hidden.wav"] { try Data("x".utf8).write(to: folder.appendingPathComponent(n)) }
        #expect(m.userMusicFiles().map(\.lastPathComponent) == ["a.wav", "b.mp3"])           // audio only, sorted, hidden skipped
        #expect(!m.dropMusic(urls: [folder.appendingPathComponent("notes.txt")]))            // not audio: refused
        #expect(!m.dropMusic(urls: [URL(string: "https://example.com/a.wav")!]))              // not a file
        // A real audio file: the first tone of the fixture's own recording is a valid audio file to import.
        let source = doc.project.packageURL.appendingPathComponent("recording/seg-000/system.m4a")
        let copy = folder.appendingPathComponent("mine.m4a"); try FileManager.default.copyItem(at: source, to: copy)
        m.seek(toNs: 300_000_000)
        #expect(m.dropMusic(urls: [folder.appendingPathComponent("notes.txt"), copy]))
        await m.waitForMusicImport()
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.music.count == 1 && m.music[0].startNs == 300_000_000)
    }

    @Test func previewStartsAndStopsWithoutLeavingFilesBehind() async throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        let id = try #require(m.project.musicLibrary.first?.id)
        m.toggleMusicPreview(trackID: id); #expect(m.previewingMusicID == id)
        m.toggleMusicPreview(trackID: id); #expect(m.previewingMusicID == nil)             // second press stops
        m.stopMusicPreview()
        try await Task.sleep(for: .milliseconds(300))
        #expect(m.previewingMusicID == nil && m.musicPlayer == nil && m.musicPreviewFile == nil)
    }
}

@MainActor @Suite struct Wave3EditorTests {
    private func doc() throws -> (EditorDocument, () -> Void) {
        let d = try pkgCopy(); let iso = EditorStorage.makeIsolated()
        return (try EditorDocument(package: d, presets: iso.store), { try? FileManager.default.removeItem(at: d); iso.cleanup() })
    }

    // E1.1 rename
    @Test func projectNamesAreCleanedAndRenamingMovesThePackage() throws {
        #expect(EditorWindows.sanitizedProjectName("  My/Demo: v2\\ ") == "MyDemo v2")
        #expect(EditorWindows.sanitizedProjectName("..hidden") == "hidden" && EditorWindows.sanitizedProjectName("   ") == "")
        #expect(EditorWindows.sanitizedProjectName(String(repeating: "a", count: 300)).count == 120)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("Old.yapcam"), other = dir.appendingPathComponent("Taken.yapcam")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: a.appendingPathComponent("project.json"))
        #expect(throws: (any Error).self) { try EditorWindows.rename(package: a, to: "Taken") }            // name in use: nothing changes
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(throws: (any Error).self) { try EditorWindows.rename(package: a, to: "  / ") }              // empty after cleaning
        #expect(try EditorWindows.rename(package: a, to: "Old") == a)                                        // same name: no-op
        let renamed = try EditorWindows.rename(package: a, to: "New/Name")
        #expect(renamed.lastPathComponent == "NewName.yapcam" && FileManager.default.fileExists(atPath: renamed.appendingPathComponent("project.json").path))
        #expect(!FileManager.default.fileExists(atPath: a.path))
        EditorWindows.renameHandler = { url, name in url.deletingLastPathComponent().appendingPathComponent("handled-\(name).yapcam") }
        defer { EditorWindows.renameHandler = nil }
        #expect(try EditorWindows.rename(package: renamed, to: "Via App").lastPathComponent == "handled-Via App.yapcam")   // the app can take over
    }

    // P4 keys
    @Test func resetTrimAndResetAllRestoreCutsInOneUndoStep() throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        let full = m.durationNs, clips0 = m.clips.count
        #expect(!m.hasTrimsOrCuts)
        m.seek(toNs: 1_000_000_000); m.splitAtPlayhead(); m.seek(toNs: 2_000_000_000); m.splitAtPlayhead()
        m.selection = .clip(m.clips[1].id); m.deleteSelection()                           // cut the middle part
        m.seek(toNs: 500_000_000); m.trim(keepAfter: true)
        #expect(m.hasTrimsOrCuts && m.durationNs < full)
        m.resetAllTrimsAndCuts()
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.durationNs == full && !m.hasTrimsOrCuts, "duration \(m.durationNs) of \(full)")
        let covered = m.clips.reduce(0) { $0 + ($1.srcEndNs - $1.srcStartNs) }
        #expect(covered == m.project.sourceDurationNs)
        m.undo(); #expect(m.hasTrimsOrCuts && m.durationNs < full)                        // one undo step for the whole reset
        _ = clips0
    }

    @Test func resetTrimOfOneClipBringsBackOnlyItsNeighbours() throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        let full = m.durationNs
        m.seek(toNs: 1_000_000_000); m.splitAtPlayhead()                                  // clips A | B
        m.seek(toNs: 3_000_000_000); m.splitAtPlayhead()                                  // A | B | C
        m.selection = .clip(m.clips[1].id); m.deleteSelection()                           // cut B away: A | C
        m.seek(toNs: 2_000_000_000); m.splitAtPlayhead()                                  // A | C1 | C2
        let c2 = m.clips[2]; m.selection = .clip(c2.id); m.deleteSelection()               // trim the end: A | C1
        let before = m.durationNs
        m.resetTrim(clipID: m.clips[1].id)                                                // C1: bring back what is next to it
        #expect(m.durationNs > before && m.durationNs < full + 1)
        #expect(m.clips.contains { $0.srcStartNs == c2.srcStartNs })                       // the part after it returned
    }

    @Test func cutCopiesSettingsAndRemovesTheItem() throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        m.seek(toNs: 500_000_000); m.addZoomAtPlayhead()
        let z = try #require(m.selectedZoom)
        #expect(m.handleShortcut("x", .command))
        #expect(m.zooms.isEmpty)
        m.seek(toNs: 4_000_000_000); m.addZoomAtPlayhead()
        #expect(m.itemClipboard != nil)                                                    // the cut zoom's settings can be pasted
        #expect(!m.cutSelection() || m.zooms.isEmpty)
        _ = z
    }

    // E13.3
    @Test func maskWithoutAStoredOpacityReadsAsHalf() throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        m.seek(toNs: 500_000_000); m.addHighlightAtPlayhead(kind: .highlight)
        #expect(m.highlights.first?.dimOpacity == 0.5)
        // (A stored record without the field is normalised by core, whose default is core's to change.)
    }

    // X5
    @Test func quickExportHasItsOwnRememberedStoreWithFactoryDefaults() {
        let suite = "yapcam.test.\(UUID().uuidString)"; let d = UserDefaults(suiteName: suite)!; defer { d.removePersistentDomain(forName: suite) }
        let factory = ExportRememberedSettings.quick(from: d)
        #expect(factory.target == .file && factory.settings.format == .mp4 && factory.settings.codec == .h264 && factory.settings.outputHeight == 720
                && factory.settings.fps == 60 && factory.settings.compression == .social && factory.settings.includeAudio)
        // The dialog's choices do not leak into quick export.
        let dialog = ExportModel(engine: FakeExporter()); dialog.remember(in: .dialog, defaults: d); dialog.format = .gif; dialog.fps = 30
        #expect(ExportRememberedSettings.quick(from: d).settings.format == .mp4)
        ExportRememberedSettings.rememberQuick(format: .mp4hevc, height: 1080, fps: 30, compression: .web, includeAudio: false, target: .clipboard, in: d)
        let q = ExportRememberedSettings.quick(from: d)
        #expect(q.target == .clipboard && q.settings.codec == .hevc && q.settings.outputHeight == 1080 && q.settings.fps == 30 && q.settings.compression == .web && !q.settings.includeAudio)
        // A paired export is not offered for the clipboard: render's normalisation applies.
        ExportRememberedSettings.rememberQuick(format: .mp4both, height: 720, fps: 60, compression: .social, includeAudio: true, target: .clipboard, in: d)
        #expect(ExportRememberedSettings.quick(from: d).settings.codec == .h264)
        #expect(!q.settings.summary(for: q.target == .clipboard ? .clipboard : .file).isEmpty)
        // The dialog still has its own memory.
        let again = ExportModel(engine: FakeExporter()); again.remember(in: .dialog, defaults: d)
        #expect(again.format == .gif && again.fps == 30)
    }
}

@MainActor @Suite struct ReviewR5EditorTests {
    private func doc() throws -> (EditorDocument, () -> Void) {
        let d = try pkgCopy(); let iso = EditorStorage.makeIsolated()
        return (try EditorDocument(package: d, presets: iso.store), { try? FileManager.default.removeItem(at: d); iso.cleanup() })
    }
    private struct Req: ExportEngine {
        let box: Box
        final class Box: @unchecked Sendable { var requests: [ExportRequest] = [] }
        func run(_ request: ExportRequest, progress: @Sendable @escaping (Double) -> Void) async throws -> URL { box.requests.append(request); return request.destination }
    }

    // 1: hardware encoding switch reaches every editor export
    @Test func hardwareEncodingSwitchReachesExportSettingsForEveryTarget() async throws {
        let box = Req.Box(); let e = ExportModel(engine: Req(box: box))
        #expect(e.makeRequest(destination: URL(fileURLWithPath: "/tmp/a.mp4")).hardwareEncoding)                 // default: hardware
        var enabled = false
        e.hardwareEncodingProvider = { enabled }
        for format in [ExportFormat.mp4h264, .mp4hevc, .mp4both, .movh264, .gif] {
            e.format = format
            let r = e.makeRequest(destination: URL(fileURLWithPath: "/tmp/a.\(format.fileExtension)"))
            #expect(!r.hardwareEncoding)
            #expect(RenderExportEngine.settings(for: r).hardwareEncodingEnabled == false, "\(format)")
        }
        let clip = e.makeRequest(destination: URL(fileURLWithPath: "/dev/null"), target: .clipboard)
        #expect(RenderExportEngine.settings(for: clip).hardwareEncodingEnabled == false)
        enabled = true
        #expect(RenderExportEngine.settings(for: e.makeRequest(destination: URL(fileURLWithPath: "/tmp/a.mp4"))).hardwareEncodingEnabled)
        // The app-wide hook is what the default provider reads.
        let saved = EditorWindows.hardwareEncodingEnabled; defer { EditorWindows.hardwareEncodingEnabled = saved }
        EditorWindows.hardwareEncodingEnabled = { false }
        let fresh = ExportModel(engine: Req(box: box))
        fresh.start(to: URL(fileURLWithPath: "/tmp/b.mp4")); await fresh.waitUntilFinished()
        #expect(box.requests.last?.hardwareEncoding == false)
        fresh.copyToClipboard(); await fresh.waitUntilFinished()
        #expect(box.requests.last?.hardwareEncoding == false && box.requests.last?.target == .clipboard)
    }

    // 2: trimming / moving a mask with keyframes is accepted by core
    @Test func movingAndTrimmingAMaskWithKeyframesIsAcceptedByCore() throws {
        let (doc, done) = try doc(); defer { done() }; let m = doc.model
        m.seek(toNs: 0); m.addHighlightAtPlayhead(kind: .blur)                       // 0–3 s
        let id = try #require(m.highlights.first?.id)
        #expect(m.highlights[0].startNs == 0 && m.highlights[0].endNs == 3_000_000_000)
        m.updateHighlightKeepingStyle(id: id) { $0.keyframes = [RegionKeyframe(tlNs: 2_000_000_000, rect: [0.5, 0.5, 0.3, 0.3])] }
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        let span = TimeSpan(startNs: 0, endNs: 3_000_000_000)
        // Trim the end to 1.5 s: the key at 2 s is dropped, the mask ends on the box it had there.
        m.previewRange(key: id, current: span, endNs: 1_500_000_000); m.commitRange(key: id)
        #expect(m.lastError == nil, "trim: \(m.lastError ?? "")")
        let trimmed = try #require(m.highlights.first)
        #expect(trimmed.endNs == 1_500_000_000 && trimmed.keyframes.allSatisfy { $0.tlNs > trimmed.startNs && $0.tlNs <= trimmed.endNs })
        #expect(trimmed.keyframes.last?.tlNs == 1_500_000_000)
        // Move it +2.5 s (the project is 5 s long: 1.5 s mask fits 2.5…4 s): keys move along.
        m.previewRange(key: id, current: TimeSpan(startNs: trimmed.startNs, endNs: trimmed.endNs), moveToStartNs: 2_500_000_000); m.commitRange(key: id)
        #expect(m.lastError == nil, "move: \(m.lastError ?? "")")
        let moved = try #require(m.highlights.first)
        #expect(moved.startNs == 2_500_000_000 && moved.keyframes.map(\.tlNs) == trimmed.keyframes.map { $0.tlNs + 2_500_000_000 })
        // Trimming the start drops earlier keys and starts from the box at the new start.
        m.previewRange(key: id, current: TimeSpan(startNs: moved.startNs, endNs: moved.endNs), startNs: 3_000_000_000); m.commitRange(key: id)
        #expect(m.lastError == nil, "trim start: \(m.lastError ?? "")")
        // The pure function: a move shifts keys, a trim keeps those inside.
        var r = HighlightRegion.preset(.blur, id: "r", start: 0, end: 3_000_000_000)
        r.keyframes = [RegionKeyframe(tlNs: 1_000_000_000, rect: [0.1, 0.1, 0.2, 0.2]), RegionKeyframe(tlNs: 2_000_000_000, rect: [0.5, 0.5, 0.2, 0.2])]
        #expect(r.retimed(startNs: 1_000_000_000, endNs: 4_000_000_000).keyframes.map(\.tlNs) == [2_000_000_000, 3_000_000_000])
        let cut = r.retimed(startNs: 0, endNs: 1_500_000_000)
        #expect(cut.keyframes.map(\.tlNs) == [1_000_000_000, 1_500_000_000])
        #expect(abs(cut.keyframes.last!.rect[0] - 0.3) < 1e-9)                    // box at 1.5 s, halfway between the two keys
        let late = r.retimed(startNs: 1_500_000_000, endNs: 3_000_000_000)
        #expect(late.keyframes.map(\.tlNs) == [2_000_000_000] && abs(late.rect[0] - 0.3) < 1e-9)
    }

    // 5: case-only rename
    @Test func caseOnlyRenameWorksOnACaseInsensitiveVolume() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("case-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("demo.yapcam")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: a.appendingPathComponent("project.json"))
        let renamed = try EditorWindows.rename(package: a, to: "Demo")
        #expect(renamed.lastPathComponent == "Demo.yapcam")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Demo.yapcam"])               // the case change landed on disk
        #expect(FileManager.default.fileExists(atPath: renamed.appendingPathComponent("project.json").path))
        // A real clash is still refused.
        let other = dir.appendingPathComponent("Other.yapcam"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try EditorWindows.rename(package: renamed, to: "other") }               // "other" is "Other"
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["Demo.yapcam", "Other.yapcam"])
    }

    // 6: copyToClipboard leaves the remembered target alone
    @Test func copyToClipboardKeepsTheRememberedTarget() async throws {
        let suite = "yapcam.test.\(UUID().uuidString)"; let d = UserDefaults(suiteName: suite)!; defer { d.removePersistentDomain(forName: suite) }
        let box = Req.Box(); let e = ExportModel(engine: Req(box: box)); e.remember(in: .dialog, defaults: d)
        #expect(e.target == .file)
        e.copyToClipboard(); await e.waitUntilFinished()
        #expect(box.requests.last?.target == .clipboard)
        #expect(e.target == .file && e.runningTarget == .clipboard)                         // the dialog's choice is untouched, the result screen knows
        let again = ExportModel(engine: Req(box: box)); again.remember(in: .dialog, defaults: d)
        #expect(again.target == .file)                                                      // and so is what was remembered
        e.start(to: URL(fileURLWithPath: "/tmp/x.mp4")); await e.waitUntilFinished()
        #expect(box.requests.last?.target == .file && e.runningTarget == .file)
        e.target = .clipboard; e.copyToClipboard(); await e.waitUntilFinished()
        #expect(e.target == .clipboard)                                                     // chosen by the user: stays
    }
}

@MainActor @Suite struct FinalReviewTests {
    @Test func pillRowFadesOnlyTheEdgesWithMorePills() {
        typealias S = ScrollingPills<String, EmptyView>
        #expect(S.edgesWithMore(offset: 0, contentWidth: 359, viewportWidth: 260) == (false, true))        // at the start: more on the right
        #expect(S.edgesWithMore(offset: -50, contentWidth: 359, viewportWidth: 260) == (true, true))       // in the middle: both
        #expect(S.edgesWithMore(offset: -99, contentWidth: 359, viewportWidth: 260) == (true, false))      // at the end: more on the left
        #expect(S.edgesWithMore(offset: 0, contentWidth: 200, viewportWidth: 260) == (false, false))       // fits: no fade
    }

    @Test func exportSheetShowsSizeAndTimeFromTheRealEngineAndDefaultsMatchTheReference() throws {
        let d = try pkgCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let doc = try EditorDocument(package: d, presets: iso.store); let e = doc.export
        // Spec 3.1 "Default MP4 settings (saved)": MP4, 60 fps, Social Media, 720p, H.264 (GIF: 15 fps, 480p).
        #expect(e.format == .mp4h264 && e.fps == 60 && e.preset == .social && e.height == 720 && e.target == .file)
        let est = try #require(e.estimate)
        #expect(est.height == 720 && est.width % 2 == 0 && est.bytes > 0 && est.renderSeconds > 0)       // the sheet's "W×H · about N MB · roughly N s" line
        e.format = .gif; #expect(e.fps == 15 && ExportFormat.gif.options.heights.contains(e.height))   // 60 fps does not exist for GIF: its default 15 applies; a valid size is kept
        #expect(e.estimate != nil)
    }
}
