import Testing
import Foundation
import CoreGraphics
import AppKit
import YapcamCore
@testable import YapcamEditor

private func fixtureCopy() throws -> URL {
    let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("rf-\(UUID().uuidString).yapcam")
    try FileManager.default.copyItem(at: src, to: d); return d
}

/// Finding 3: export must never destroy the existing destination.
@Suite struct AtomicExportTests {
    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ae-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }
    struct Boom: Error {}

    @Test func failureKeepsExistingFileAndLeavesNoTemp() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let dest = d.appendingPathComponent("out.mp4"); try Data("old".utf8).write(to: dest)
        await #expect(throws: Boom.self) {
            _ = try await AtomicExport.run(to: dest) { temp in try Data("partial".utf8).write(to: temp); throw Boom() }
        }
        #expect(try Data(contentsOf: dest) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.path) == ["out.mp4"])
    }

    @Test func cancellationKeepsExistingFile() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let dest = d.appendingPathComponent("out.mp4"); try Data("old".utf8).write(to: dest)
        let task = Task {
            try await AtomicExport.run(to: dest) { temp in
                try Data("new".utf8).write(to: temp)
                try await Task.sleep(for: .seconds(30)); return temp
            }
        }
        try await Task.sleep(for: .milliseconds(50)); task.cancel()
        _ = try? await task.value
        #expect(try Data(contentsOf: dest) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.path) == ["out.mp4"])
    }

    @Test func successReplacesAtomically() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let dest = d.appendingPathComponent("out.mp4"); try Data("old".utf8).write(to: dest)
        let url = try await AtomicExport.run(to: dest) { temp in try Data("new".utf8).write(to: temp); return temp }
        #expect(url == dest)
        #expect(try Data(contentsOf: dest) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.path) == ["out.mp4"])
        let fresh = d.appendingPathComponent("fresh.mp4")
        _ = try await AtomicExport.run(to: fresh) { temp in try Data("x".utf8).write(to: temp); return temp }
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }
}

@MainActor @Suite struct ReviewFixModelTests {
    /// Finding 15
    @Test func scrubbingDoesNotSnapToItsOwnPlayhead() {
        let m = EditorModel(project: FakeProject(durationNs: 60_000_000_000), player: FakePlayer())
        m.geometry = TimelineGeometry(pixelsPerSecond: 2)
        m.seek(toNs: 20_000_000_000)
        let target = Int64(23_000_000_000)                       // 6 px away: inside the 8 px threshold
        #expect(m.snapped(target, includePlayhead: false) == target)
        #expect(m.snapGuideNs == nil)
        #expect(m.snapped(target) == 20_000_000_000)             // zoom/lane drags still snap to the playhead
    }

    /// Finding 9
    @Test func silenceResultsAreDiscardedAfterAnyEdit() async throws {
        let p = FakeProject(durationNs: 20_000_000_000)
        p.silences = [TimeSpan(startNs: 8_000_000_000, endNs: 9_000_000_000)]
        let m = EditorModel(project: p, player: FakePlayer())
        m.findSilences()
        for _ in 0..<1000 where m.silenceState == .analyzing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(m.silenceState == .found(p.silences))
        m.seek(toNs: 2_000_000_000); m.trim(keepAfter: true)     // timeline shifted by 2 s
        #expect(m.silenceState == .idle)
        let duration = m.durationNs
        m.applySilences(speed: nil)                              // must not cut stale ranges
        #expect(m.durationNs == duration)
    }

    @Test func silenceAnalysisFinishingAfterAnEditIsIgnored() async throws {
        let p = FakeProject(durationNs: 20_000_000_000)
        p.silences = [TimeSpan(startNs: 8_000_000_000, endNs: 9_000_000_000)]; p.silenceDelay = .milliseconds(150)
        let m = EditorModel(project: p, player: FakePlayer())
        m.findSilences()
        m.seek(toNs: 2_000_000_000); m.trim(keepAfter: true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(m.silenceState == .idle)
    }

    /// Finding 13
    @Test func focusDragIsOneUndoStep() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        m.addZoomAtPlayhead()
        let before = (m.zooms[0].focusX, m.zooms[0].focusY)
        for i in 1...40 { m.previewFocus(fromPreview: CGPoint(x: 0.2 + Double(i) * 0.01, y: 0.4 + Double(i) * 0.005)) }
        #expect((m.zooms[0].focusX, m.zooms[0].focusY) == before)     // nothing committed mid-drag
        m.commitFocusPreview()
        #expect(m.zooms[0].focusX != before.0)
        m.undo()
        #expect(m.zooms.count == 1 && (m.zooms[0].focusX, m.zooms[0].focusY) == before)   // one undo restores the original focus
    }

    /// Finding 14
    @Test func recoveredStateIsMarkedUnsavedAndSavedOnClose() {
        let p = FakeProject(), m = EditorModel(project: p, player: FakePlayer())
        #expect(m.saveState == .clean)
        m.markRecoveredUnsaved()
        #expect(m.saveState == .dirty)
        m.saveNow()
        #expect(p.saveCount == 1 && m.saveState == .clean)
    }
}

@MainActor @Suite struct ReviewFixRealCoreTests {
    /// Finding 5
    @Test func journalOnlyPackageRestoresItsEditsInsteadOfCreating() throws {
        let d = try fixtureCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let first = try EditorDocument(package: d)
        first.model.set("canvas.padding", number: 91); first.model.addZoomAtPlayhead()   // writes only the journal
        // Surviving state is the journal only (project files lost/never written).
        for f in ["project.json", "project.json.prev"] { try? FileManager.default.removeItem(at: d.appendingPathComponent(f)) }
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("autosave/project.json").path))
        let restored = try EditorDocument(package: d, restoreUnsavedChanges: true)
        #expect(restored.model.number("canvas.padding") == 91 && restored.model.zooms.count == 1)
    }

    /// Finding 14 (end to end)
    @Test func restoredEditsPersistOnCloseAndPromptDoesNotReturn() throws {
        let d = try fixtureCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let first = try EditorDocument(package: d)
        first.model.set("canvas.padding", number: 66)
        let restored = try EditorDocument(package: d, restoreUnsavedChanges: true)
        #expect(restored.model.saveState == .dirty)
        restored.model.saveNow()                                  // what window close does
        #expect(!EditorDocument.hasUnsavedJournal(d))
        let reopened = try EditorDocument(package: d)
        #expect(reopened.model.number("canvas.padding") == 66)
    }

    /// Finding 11
    @Test func clickTimesFollowTimelineEditsUndoAndRedo() throws {
        let d = try fixtureCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        let before = m.project.clickTimesNs
        try #require(before.count >= 1)
        m.seek(toNs: 0)
        try m.project.apply(.deleteRange(startNs: 0, endNs: 1_000_000_000))
        let after = m.project.clickTimesNs
        #expect(after != before && after.allSatisfy { $0 >= 0 && $0 <= m.durationNs })
        try m.project.undo(); #expect(m.project.clickTimesNs == before)
        try m.project.redo(); #expect(m.project.clickTimesNs == after)
    }

    /// Finding 12
    @Test func imageBackgroundResolvesThroughTheRenderSource() throws {
        let d = try fixtureCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d)
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        try doc.project.importBackgroundImage(png)
        let source = ProjectRenderSource(doc.project)
        let url = try source.renderBackgroundAsset(index: 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let data = try FrameSnapshot.png(source: source, atNs: 1_000_000_000)    // compositor resolves the asset
        #expect(!data.isEmpty)
    }

    /// Finding 4
    @Test func relinkWithTheSameFileAsSourceNeverDeletesIt() throws {
        let d = try fixtureCopy(); defer { try? FileManager.default.removeItem(at: d) }
        let rel = "recording/seg-000/screen.mov"
        let m = try EditorDocument(package: d).model
        m.set("canvas.padding", number: 55); m.saveNow()
        let file = d.appendingPathComponent(rel)
        let original = try Data(contentsOf: file)
        // Make the existing file "changed" so core reports it as missing/changed.
        let h = try FileHandle(forWritingTo: file); try h.seekToEnd(); try h.write(contentsOf: Data([0])); try h.close()
        var reported: [String] = []
        do { _ = try EditorDocument(package: d) } catch CoreError.missingMedia(let p) { reported = p }
        #expect(reported.contains(rel))
        // User picks the very same file in "Locate…".
        _ = try? Project.relink(package: d, replacements: [rel: file])
        #expect(FileManager.default.fileExists(atPath: file.path), "selected source must survive relink")
        #expect(try Data(contentsOf: file).count >= original.count)
    }
}
