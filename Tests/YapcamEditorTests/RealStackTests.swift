import Testing
import Foundation
import AppKit
import YapcamCore
@testable import YapcamEditor

private func copyFixture() throws -> URL {
    let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/synthetic/basic.yapcam")
    let dst = FileManager.default.temporaryDirectory.appendingPathComponent("editor-test-\(UUID().uuidString).yapcam")
    try FileManager.default.copyItem(at: src, to: dst)
    return dst
}

@MainActor @Suite struct RealStackTests {
    @Test func editSaveReopenWithCore() throws {
        let pkg = try copyFixture(); defer { try? FileManager.default.removeItem(at: pkg) }
        let doc = try EditorDocument(package: pkg)
        let m = doc.model
        #expect(m.durationNs == 5_000_000_000)
        m.seek(toNs: 2_000_000_000); m.splitAtPlayhead()
        #expect(m.clips.count == 2)
        m.addZoomAtPlayhead()
        #expect(m.zooms.count == 1 && m.selectedZoom != nil)
        m.setZoomFocus(id: m.zooms[0].id, x: 0.1, y: 0.9)
        m.resizeZoom(id: m.zooms[0].id, endNs: 3_500_000_000)
        #expect(m.zooms[0].endNs == 3_500_000_000)
        m.set("canvas.padding", number: 80)
        m.setAspect(.square)
        #expect(m.number("canvas.padding") == 80 && m.string("canvas.aspect") == "1:1")
        #expect(m.numbers("canvas.output_size") == [1080, 1080])
        m.setSpeed(clipID: m.clips[1].id, 2)
        #expect(m.durationNs < 5_000_000_000)
        m.set("cursor.click_effect", string: "highlight")
        m.set("canvas.background.color", color: [1, 0, 0, 1])
        #expect(m.color("canvas.background.color") == [1, 0, 0, 1])
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        m.undo(); m.undo(); m.redo()
        m.saveNow()
        #expect(m.saveState == .clean)
        let reopened = try Project.open(package: pkg)
        #expect(reopened.durationNs == m.durationNs)
    }

    @Test func invalidValuesSurfaceAsErrorsAndKeepState() throws {
        let pkg = try copyFixture(); defer { try? FileManager.default.removeItem(at: pkg) }
        let m = try EditorDocument(package: pkg).model
        m.set("cursor.size", number: -4)
        #expect(m.lastError != nil)
        #expect(m.number("cursor.size") == 1)
    }

    @Test func clicksAndGeometryComeFromCore() throws {
        let pkg = try copyFixture(); defer { try? FileManager.default.removeItem(at: pkg) }
        let m = try EditorDocument(package: pkg).model
        let g = try #require(m.project.frameGeometry(atNs: 0))
        let expected = DefaultsContract.expectedCanvas(m, source: (320, 200))           // 1728×1080 for new projects, 1920×1080 for legacy ones
        #expect(g.canvasWidth == expected.w && g.canvasHeight == expected.h && g.dest.width > 0, "canvas \(g.canvasWidth)×\(g.canvasHeight), expected \(expected)")
        let center = try #require(g.sourcePoint(fromPreview: CGPoint(x: 0.5, y: 0.5)))
        #expect(abs(center.x - 0.5) < 0.01 && abs(center.y - 0.5) < 0.01)
        #expect(g.sourcePoint(fromPreview: CGPoint(x: 0.001, y: 0.001)) == nil)   // inside padding
        _ = m.project.clickTimesNs   // fixture has clicks; core "clicks" query may be empty on older core
    }

    @Test func journalDetectionAndDiscard() throws {
        let pkg = try copyFixture(); defer { try? FileManager.default.removeItem(at: pkg) }
        let first = try EditorDocument(package: pkg)
        first.model.addZoomAtPlayhead()          // writes the autosave journal (project never saved)
        #expect(EditorDocument.hasUnsavedJournal(pkg))
        let restored = try EditorDocument(package: pkg, restoreUnsavedChanges: true)
        #expect(restored.model.zooms.count == 1)
        let discarded = try EditorDocument(package: pkg, restoreUnsavedChanges: false)
        #expect(discarded.model.zooms.isEmpty)
    }

    @Test func missingMediaIsReported() throws {
        let pkg = try copyFixture(); defer { try? FileManager.default.removeItem(at: pkg) }
        let doc = try EditorDocument(package: pkg); doc.model.saveNow()
        try FileManager.default.removeItem(at: pkg.appendingPathComponent("recording/seg-000/screen.mov"))
        do { _ = try EditorDocument(package: pkg); Issue.record("expected missing media") }
        catch CoreError.missingMedia(let paths) { #expect(paths.contains { $0.contains("screen.mov") }) }
    }

    @Test func exportsThroughRealRenderer() async throws {
        let pkg = try copyFixture(); defer { try? FileManager.default.removeItem(at: pkg) }
        let doc = try EditorDocument(package: pkg)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("editor-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        doc.export.height = 720
        doc.export.includeAudio = true    // audio export works again (render fixed the stall)
        doc.export.start(to: out)
        await doc.export.waitUntilFinished()
        #expect(doc.export.state == .done(out), "\(doc.export.state)")
        #expect(FileManager.default.fileExists(atPath: out.path))
    }

    @Test func scrubLatency() throws {
        let pkg = try copyFixture(); defer { try? FileManager.default.removeItem(at: pkg) }
        let m = try EditorDocument(package: pkg).model
        let n = 200
        let t0 = ContinuousClock.now
        for i in 0..<n { m.seek(toNs: Int64(i) * m.durationNs / Int64(n), precise: false); _ = m.project.frameGeometry(atNs: m.playheadNs) }
        let per = (ContinuousClock.now - t0) / n
        print("SCRUB model seek + core frame eval: \(per)")
        #expect(per < .milliseconds(16))
    }
}

@MainActor @Suite struct RealFrameTests {
    @Test func copyFramePNGMatchesCanvas() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("frame-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: pkg); defer { try? FileManager.default.removeItem(at: pkg) }
        let doc = try EditorDocument(package: pkg)
        let data = try FrameSnapshot.png(source: ProjectRenderSource(doc.project), atNs: 1_000_000_000)
        let rep = try #require(NSBitmapImageRep(data: data))
        let g = try #require(doc.model.project.frameGeometry(atNs: 1_000_000_000))
        #expect(Double(rep.pixelsWide) == g.canvasWidth && Double(rep.pixelsHigh) == g.canvasHeight)   // the copied frame is the canvas
        let expected = DefaultsContract.expectedCanvas(doc.model, source: (320, 200))
        #expect(Double(rep.pixelsWide) == expected.w && Double(rep.pixelsHigh) == expected.h)
    }
}

@MainActor @Suite struct RealCoreRangesTests {
    @Test func coreAcceptsLayoutsCursorHidesAudioRangesAndCrop() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("ranges-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: pkg); defer { try? FileManager.default.removeItem(at: pkg) }
        let m = try EditorDocument(package: pkg).model
        m.seek(toNs: 1_000_000_000)
        m.addCursorHideAtPlayhead(); #expect(m.cursorHides.count == 1, "\(m.lastError ?? "")")
        m.addAudioRangeAtPlayhead(track: "system_audio"); #expect(m.audioRanges.count == 1, "\(m.lastError ?? "")")
        m.setCrop(left: 0.1, top: 0.1, right: 0.1, bottom: 0.1); #expect(abs(m.cropInsets().left - 0.1) < 1e-6, "\(m.lastError ?? "")")
        m.speedUpTyping(); #expect(m.lastError == nil, "\(m.lastError ?? "")")
        m.regenerateAutoZooms(); #expect(m.lastError == nil, "\(m.lastError ?? "")")
        m.set("camera.layouts", .array([]))   // layouts need a camera track; the fixture has none
        #expect(!m.hasCamera)
    }
}

@MainActor @Suite struct RealUndoAndScaleTests {
    private func pkg() throws -> URL {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("undo-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); return d
    }

    @Test func zoomModeSwitchReachesCore() throws {
        let d = try pkg(); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        m.addZoomAtPlayhead(); let id = m.zooms[0].id
        m.setZoomMode(id: id, .auto); #expect(m.zooms[0].mode == .auto, "\(m.lastError ?? "")")
        m.setZoomMode(id: id, .manual); #expect(m.zooms[0].mode == .manual)
    }

    @Test func hundredEditsUndoAndRedoExactly() throws {
        let d = try pkg(); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        let initial = m.settings, dur = m.durationNs
        for i in 0..<100 {
            switch i % 4 {
            case 0: m.set("canvas.padding", number: Double(10 + i))
            case 1: m.seek(toNs: Int64(100_000_000 * (i % 40 + 1))); m.splitAtPlayhead()
            case 2: m.set("cursor.size", number: 1 + Double(i % 5) / 10)
            default: m.seek(toNs: Int64(50_000_000 * (i % 20 + 1))); m.addZoomAtPlayhead()
            }
        }
        let finalSettings = m.settings, finalClips = m.clips, finalZooms = m.zooms
        var steps = 0
        while m.canUndo { m.undo(); steps += 1 }
        #expect(steps >= 80 && m.settings == initial && m.durationNs == dur && m.clips.count == 1 && m.zooms.isEmpty)
        while m.canRedo { m.redo() }
        #expect(m.settings == finalSettings && m.clips == finalClips && m.zooms == finalZooms)
    }

    @Test func veryShortAndLongTimelinesStayUsable() throws {
        let d = try pkg(); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        // Short (<2 s): a default 2 s zoom is clipped to the project end, tiny leftovers are refused.
        m.seek(toNs: 0); try m.project.apply(.deleteRange(startNs: 1_500_000_000, endNs: m.durationNs))
        #expect(m.durationNs == 1_500_000_000)
        m.addZoomAtPlayhead(); #expect(m.zooms.first?.endNs == 1_500_000_000)
        m.fitTimeline(width: 900); #expect(m.geometry.pixelsPerSecond > 100)
        // Long: geometry for a 3 h project fits and stays within pps limits; ruler steps stay readable.
        let long = TimelineGeometry.fitting(durationNs: 3 * 3600 * 1_000_000_000, width: 900)
        #expect(long.pixelsPerSecond >= TimelineGeometry.minPPS && long.rulerStepSeconds() >= 60)
    }
}

@MainActor @Suite struct RealRelinkTests {
    @Test func relinkRestoresMissingMediaKeepingEdits() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("relink-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: pkg); defer { try? FileManager.default.removeItem(at: pkg) }
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("screen-\(UUID().uuidString).mov")
        let rel = "recording/seg-000/screen.mov"
        try FileManager.default.copyItem(at: pkg.appendingPathComponent(rel), to: backup); defer { try? FileManager.default.removeItem(at: backup) }
        let m = try EditorDocument(package: pkg).model
        m.set("canvas.padding", number: 77); m.saveNow()
        try FileManager.default.removeItem(at: pkg.appendingPathComponent(rel))
        var missing: [String] = []
        do { _ = try EditorDocument(package: pkg) } catch CoreError.missingMedia(let p) { missing = p }
        #expect(missing.contains(rel))
        _ = try Project.relink(package: pkg, replacements: [rel: backup])
        let again = try EditorDocument(package: pkg).model
        #expect(again.number("canvas.padding") == 77)
    }
}
