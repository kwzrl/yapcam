import Foundation
import Testing
import YapcamCore

private func withFixture<T>(_ body: (URL) throws -> T) throws -> T {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let source = root.appendingPathComponent("Fixtures/synthetic/basic.yapcam")
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-core-swift-\(UUID().uuidString).yapcam")
    try FileManager.default.copyItem(at: source, to: dest)
    defer { try? FileManager.default.removeItem(at: dest) }
    return try body(dest)
}
private final class ConcurrentEditCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var editing = true
    private var framesDuringEdits = 0
    private var failures: [String] = []
    func frame() { lock.lock(); defer { lock.unlock() }; if editing { framesDuringEdits += 1 } }
    func failed(_ error: Error) { lock.lock(); defer { lock.unlock() }; failures.append(error.localizedDescription) }
    func finished() { lock.lock(); defer { lock.unlock() }; editing = false }
    var result: (Int, [String]) { lock.lock(); defer { lock.unlock() }; return (framesDuringEdits, failures) }
}
@Test func croppedZoomFirstFramesRemainValidAcrossABI() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        try p.apply(.set(path: "canvas.crop", value: .array([.number(0.1), .number(0.1), .number(0.7), .number(0.7)])))
        for mode in ["manual", "auto"] {
            for start: Int64 in [0, 1_000_000_000] {
                let change = try p.apply(.addZoom(ZoomSpec(startNs: start, endNs: start + 1_000_000_000, mode: mode)))
                for t in [start, start + 1, start + 150_000_000] {
                    let frame = try p.frame(atNs: t)
                    #expect(frame.screen_crop.x.isFinite && frame.screen_crop.y.isFinite)
                    #expect(frame.screen_crop.x >= 0.1 && frame.screen_crop.y >= 0.1)
                    #expect(frame.screen_crop.x + frame.screen_crop.w <= 0.8 + 1e-15)
                    #expect(try p.frameExtras(atNs: t).tl_ns == t)
                }
                try p.apply(.removeZoom(id: change.createdIDs[0]))
            }
        }
    }
}
@Test func framesRemainValidWhileDurableEditsAndHistoryRunConcurrently() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        try p.apply(.batch([
            .set(path: "canvas.crop", value: .array([.number(0.1), .number(0.1), .number(0.7), .number(0.7)])),
            .addZoom(ZoomSpec(startNs: 1_000_000_000, endNs: 2_000_000_000))
        ]))
        let check = ConcurrentEditCheck()
        let started = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        done.enter()
        DispatchQueue(label: "core-durable-edit-regression").async {
            defer { check.finished(); done.leave() }
            started.signal()
            do {
                for n in 0..<24 { try p.apply(.set(path: "canvas.padding", value: .number(Double(30 + n)))) }
                for _ in 0..<12 { try p.undo() }
                for _ in 0..<12 { try p.redo() }
                try p.save()
            } catch { check.failed(error) }
        }
        // Join before the fixture is removed, even if a reader fails.
        defer { done.wait() }
        started.wait()
        for _ in 0..<1000 {
            let frame = try p.frame(atNs: 1_000_000_000)
            #expect(frame.screen_crop.x.isFinite && frame.screen_crop.y.isFinite)
            #expect(frame.screen_crop.x >= 0.1 && frame.screen_crop.y >= 0.1)
            #expect(try p.frameExtras(atNs: 1_000_000_000).tl_ns == frame.tl_ns)
            check.frame()
        }
        done.wait()
        #expect(check.result.0 > 0 && check.result.1.isEmpty)
        #expect(abs(try p.frame(atNs: 0).screen_dest.y - 53) < 1e-9)
        let reopened = try Project.open(package: package)
        #expect(try reopened.toJSON() == p.toJSON())
    }
}
@Test func supplementalEffectsPersistAndMatchSnapshots() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        let defaults = try p.renderOptions()
        #expect(defaults.cursorStyle == .recorded && defaults.cameraShadowRadius == 0)
        let highlight: JSONValue = .object([
            "id": .string("focus"), "tl_start_ns": .integer(1_000_000_000),
            "tl_end_ns": .integer(3_000_000_000),
            "rect": .array([.number(0.25), .number(0.25), .number(0.5), .number(0.5)])
        ])
        try p.apply(.batch([
            .set(path: "canvas.highlights", value: .array([highlight])),
            .set(path: "canvas.animation.entrance", value: .string("fade")),
            .set(path: "cursor.style", value: .string("touch")),
            .set(path: "cursor.motion_blur", value: .number(0.4)),
            .set(path: "camera.shadow_radius", value: .number(20))
        ]))
        let options = try p.renderOptions()
        #expect(options.cursorStyle == .touch && options.cursorMotionBlur == 0.4)
        #expect(options.cameraShadowRadius == 20)
        let fade = try p.renderLayers(atNs: 0)
        #expect(fade.count == 1 && fade[0].opacity == 1 && fade[0].kind == "highlight")
        let extras = try p.frameExtras(atNs: 0)
        #expect(extras.fade_opacity == 1 && extras.highlight_count == 0)
        #expect(extras.cursor_style == 2 && extras.cursor_motion_blur == 0.4)
        #expect(extras.camera_shadow_radius == 20 && extras.reserved == 0)
        let f = try p.frame(atNs: 1_500_000_000)
        let layers = try p.renderLayers(atNs: 1_500_000_000)
        #expect(layers.count == 1 && layers[0].id == "focus")
        #expect(layers[0].rect[0] == f.screen_dest.x + f.screen_dest.w * 0.25)
        let focus = try p.frameExtras(atNs: 1_500_000_000)
        #expect(focus.highlight_count == 1)
        #expect(focus.highlights.0.rect.x == layers[0].rect[0])
        #expect(focus.highlights.0.rect.w == layers[0].rect[2])
        let snapshot = try p.snapshot()
        try p.apply(.deleteRange(startNs: 0, endNs: 1_000_000_000))
        #expect(try p.renderLayers(atNs: 2_000_000_000).isEmpty)
        #expect(try snapshot.renderLayers(atNs: 2_000_000_000).count == 1)
        try p.undo()
        #expect(try p.renderLayers(atNs: 1_500_000_000) == layers)
        try p.save()
        let reopened = try Project.open(package: package)
        #expect(try reopened.renderOptions() == options)
        #expect(try reopened.renderLayers(atNs: 1_500_000_000) == layers)
    }
}
@Test func clickQueryUsesEditedTimelineNanoseconds() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        #expect(try p.clicks().map(\.tlNs) == [1_700_000_000, 3_500_000_000])
        try p.apply(.split(atNs: 2_000_000_000))
        let clips = try p.query("{\"q\":\"clips\"}", as: [ClipInfo].self)
        try p.apply(.setSpeed(clipID: clips[0].id, speed: 2))
        #expect(try p.clicks().map(\.tlNs) == [850_000_000, 2_500_000_000])
        let snapshot = try p.snapshot()
        try p.apply(.deleteRange(startNs: 800_000_000, endNs: 1_000_000_000))
        let clicks = try p.clicks()
        #expect(clicks.count == 1 && clicks[0].tlNs == 2_300_000_000)
        #expect(clicks[0].srcNs == 3_500_000_000 && clicks[0].segment == 1)
        #expect(try snapshot.clicks().count == 2)
        try p.undo()
        #expect(try p.clicks() == snapshot.clicks())
        #expect(yc_frame_extras_at(nil, 0, nil) == YC_ERR_INVALID_ARGUMENT)
    }
}
@Test func longTimelineEditsPreserveEffectsAndNoopHistoryThroughABI() throws {
    try withFixture { package in
        let length: Int64 = (1 << 53) + 37
        let sessionURL = package.appendingPathComponent("recording/session.json")
        var session = try JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL)) as! [String: Any]
        var segments = session["segments"] as! [[String: Any]]
        segments[0]["duration_ns"] = length * 2
        session["segments"] = [segments[0]]
        try JSONSerialization.data(withJSONObject: session).write(to: sessionURL)
        let p = try Project.create(package: package)
        try p.apply(.split(atNs: length))
        let highlight: JSONValue = .object([
            "id": .string("long-highlight"), "tl_start_ns": .integer(length + 9),
            "tl_end_ns": .integer(length + 61)
        ])
        try p.apply(.set(path: "canvas.highlights", value: .array([highlight])))
        let isolated = try p.snapshot()
        let before = try isolated.toJSON()
        let clips = try isolated.query("{\"q\":\"clips\"}", as: [ClipInfo].self)
        let noop = try isolated.apply(.setSpeed(clipID: clips[1].id, speed: 1))
        #expect(noop.changed.isEmpty && !isolated.canUndo)
        #expect(try isolated.toJSON() == before)
        try isolated.apply(.setSpeed(clipID: clips[1].id, speed: 2))
        let fast = try isolated.toJSON()
        let noopFast = try isolated.apply(.setSpeed(clipID: clips[1].id, speed: 2))
        #expect(noopFast.changed.isEmpty)
        #expect(try isolated.toJSON() == fast)
        try isolated.apply(.deleteRange(startNs: length + 7, endNs: length + 18))
        let state = try JSONSerialization.jsonObject(with: isolated.toJSON()) as! [String: Any]
        let canvas = state["canvas"] as! [String: Any]
        let highlights = canvas["highlights"] as! [[String: Any]]
        #expect((highlights[0]["tl_start_ns"] as? NSNumber)?.int64Value == length + 5)
        #expect((highlights[0]["tl_end_ns"] as? NSNumber)?.int64Value == length + 20)
        let cut = try isolated.query("{\"q\":\"clips\"}", as: [ClipInfo].self)
        #expect(cut[1].srcEndNs == length + 14 && cut[2].srcStartNs == length + 36)
        try isolated.undo(); #expect(try isolated.toJSON() == fast)
        try isolated.undo(); #expect(try isolated.toJSON() == before && !isolated.canUndo)
    }
}
@Test func cuttingWholeRoundedDurationLeavesNoTinyTail() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        try p.apply(.split(atNs: 35))
        try p.apply(.deleteRange(startNs: 35, endNs: p.durationNs))
        let clips = try p.query("{\"q\":\"clips\"}", as: [ClipInfo].self)
        try p.apply(.setSpeed(clipID: clips[0].id, speed: 32))
        #expect(p.durationNs == 1)
        try p.apply(.deleteRange(startNs: 0, endNs: p.durationNs))
        #expect(p.durationNs == 0)
        #expect(try p.query("{\"q\":\"clips\"}", as: [ClipInfo].self).isEmpty)
        try p.undo()
        #expect(p.durationNs == 1)
    }
}
@Test func smallSpeedChangesRemainVisibleInFrameAndDuration() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        let clips = try p.query("{\"q\":\"clips\"}", as: [ClipInfo].self)
        try p.apply(.setSpeed(clipID: clips[0].id, speed: 1.000000001))
        #expect(p.durationNs == 4_999_999_995)
        #expect(try p.frame(atNs: 1_000_000_000).screen.src_ns == 1_000_000_001)
        try p.undo()
        #expect(p.durationNs == 5_000_000_000)
    }
}
@Test func silenceFileRangesMapThroughEditedTimeline() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        try p.apply(.split(atNs: 2_000_000_000))
        let clips = try p.query("{\"q\":\"clips\"}", as: [ClipInfo].self)
        try p.apply(.setSpeed(clipID: clips[0].id, speed: 2))
        let local = [SilenceRange(startNs: 500_000_000, endNs: 2_500_000_000)]
        let mapped = try p.mapAudioRanges(local, track: "system_audio", mediaPath: "recording/seg-000/system.m4a")
        #expect(mapped == [SilenceRange(startNs: 250_000_000, endNs: 1_500_000_000)])
        let snapshot = try p.snapshot()
        try p.apply(.deleteRange(startNs: 600_000_000, endNs: 1_200_000_000))
        #expect(try p.mapAudioRanges(local, track: "system_audio", mediaPath: "recording/seg-000/system.m4a") == [SilenceRange(startNs: 250_000_000, endNs: 900_000_000)])
        #expect(try snapshot.mapAudioRanges(local, track: "system_audio", mediaPath: "recording/seg-000/system.m4a") == mapped)
        #expect(try p.mapAudioRanges([], track: "system_audio", mediaPath: "recording/seg-000/system.m4a").isEmpty)
        #expect(throws: CoreError.self) { try p.mapAudioRanges(local, track: "screen", mediaPath: "recording/seg-000/screen.mov") }
        let before = p.durationNs
        let silence = try p.mapAudioRanges(local, track: "system_audio", mediaPath: "recording/seg-000/system.m4a")
        try p.apply(.processSilence(ranges: silence, speed: nil))
        #expect(p.durationNs == before - 650_000_000)
        try p.undo(); #expect(p.durationNs == before)
    }
}
@Test func projectLifecycleAndCFrameLayout() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        #expect(MemoryLayout<YcFrame>.size == 328)
        #expect(p.durationNs == 5_000_000_000)
        #expect(p.session.segments.count == 2)
        #expect(p.session.source.displayID == 1)
        let f = try p.frame(atNs: 3_200_000_000)
        #expect(f.canvas_w == 1920 && f.canvas_h == 1080)
        #expect(f.screen.segment == 1 && f.screen.file_ns == 200_000_000)
        #expect(f.screen_crop.w == 1)
        #expect(f.click_progress == -1)
        #expect(f.camera.present == 0)
        #expect(f.mic_gain == 1 && f.system_gain == 1)
        try p.save()
        let reopened = try Project.open(package: package)
        #expect(reopened.durationNs == p.durationNs)
        let clips = try p.query("{\"q\":\"clips\"}", as: [ClipInfo].self)
        #expect(clips[0].tlEndNs == 5_000_000_000)
        let state = try JSONSerialization.jsonObject(with: p.toJSON()) as! [String: Any]
        #expect(state["schema_version"] as? Int == 1)
    }
}
@Test func editsSnapshotAndUndoRoundtrip() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        let snapshot = try p.snapshot()
        let changes = try p.apply(.batch([.split(atNs: 2_000_000_000), .set(path: "canvas.padding", value: .number(90))]))
        #expect(changes.createdIDs.count == 1)
        #expect(p.canUndo && !p.canRedo)
        #expect(try p.frame(atNs: 0).screen_dest.x >= 90)
        let clips = try p.query("{\"q\":\"clips\"}", as: [ClipInfo].self)
        try p.apply(.setSpeed(clipID: clips[0].id, speed: 2))
        #expect(p.durationNs == 4_000_000_000)
        #expect(snapshot.durationNs == 5_000_000_000)
        try p.undo(); #expect(p.durationNs == 5_000_000_000)
        try p.undo(); #expect(!p.canUndo && p.canRedo)
        try p.redo(); #expect(p.canUndo)
        let zoom = try p.apply(.addZoom(ZoomSpec(startNs: 0, endNs: 1_000_000_000, scale: 2, easeInNs: 0, easeOutNs: 0)))
        #expect(try p.frame(atNs: 500_000_000).screen_crop.w == 0.5)
        try p.apply(.updateZoom(id: zoom.createdIDs[0], patch: ["scale": .number(3)]))
        #expect(abs(try p.frame(atNs: 500_000_000).screen_crop.w - 1/3.0) < 0.00001)
        try p.apply(.removeZoom(id: zoom.createdIDs[0]))
        try p.apply(.deleteRange(startNs: 0, endNs: 1_000_000_000))
        #expect(p.durationNs == 4_000_000_000)
    }
}
@Test func errorsRecoveryAndNullABIArguments() throws {
    try withFixture { package in
        let p = try Project.create(package: package); try p.save()
        try p.apply(.set(path: "canvas.padding", value: .number(100))); try p.save()
        try Data("broken".utf8).write(to: package.appendingPathComponent("project.json"))
        let recovered = try Project.open(package: package)
        #expect(try recovered.frame(atNs: 0).screen_dest.x != p.frame(atNs: 0).screen_dest.x)
        try Data("{\"schema_version\":42}".utf8).write(to: package.appendingPathComponent("project.json"))
        do { _ = try Project.open(package: package); Issue.record("Newer version was accepted") }
        catch CoreError.unsupportedVersion(let v) { #expect(v == 42) }
        try p.save()
        try FileManager.default.removeItem(at: package.appendingPathComponent("recording/seg-000/screen.mov"))
        do { _ = try Project.open(package: package); Issue.record("Missing media accepted") }
        catch CoreError.missingMedia(let paths) { #expect(paths.contains("recording/seg-000/screen.mov")) }
        #expect(yc_project_create(nil, nil) == YC_ERR_INVALID_ARGUMENT)
        #expect(yc_frame_at(nil, 0, nil) == YC_ERR_INVALID_ARGUMENT)
        #expect(yc_can_undo(nil) == 0)
    }
}
@Test func commandTimesPreserveInt64Precision() throws {
    let t: Int64 = 9_007_199_254_740_993
    let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EditCommand.split(atNs: t))) as! [String: Any]
    #expect((value["at_tl_ns"] as? NSNumber)?.int64Value == t)
}
@Test func concurrentReadersAndIndependentSnapshot() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        DispatchQueue.concurrentPerform(iterations: 1000) { n in
            do {
                let f = try p.frame(atNs: Int64(n)*4_000_000)
                #expect(f.screen.present == 1)
            } catch { Issue.record("Concurrent frame: \(error)") }
        }
    }
}

@Test func autosavePresetFilesAndAutoZooms() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        try p.apply(.set(path: "notes", value: .string("local speaker notes")))
        let restored = try Project.open(package: package)
        let state = try JSONSerialization.jsonObject(with: restored.toJSON()) as! [String: Any]
        #expect(state["notes"] as? String == "local speaker notes")
        let snapshot = try p.snapshot()
        try snapshot.apply(.set(path: "notes", value: .string("snapshot notes")))
        let again = try Project.open(package: package)
        let againState = try JSONSerialization.jsonObject(with: again.toJSON()) as! [String: Any]
        #expect(againState["notes"] as? String == "local speaker notes")
        try p.apply(.set(path: "canvas.padding", value: .number(75)))
        let preset = package.appendingPathComponent("test-preset.json")
        try p.exportPreset(to: preset)
        try p.apply(.set(path: "canvas.padding", value: .number(123)))
        try p.importPreset(from: preset)
        let imported = try JSONSerialization.jsonObject(with: p.toJSON()) as! [String: Any]
        #expect((imported["canvas"] as? [String: Any])?["padding"] as? Double == 75)
        try p.apply(.autoZooms)
        let zooms = try p.query("{\"q\":\"zooms\"}", as: [JSONValue].self)
        #expect(zooms.count == 2)
        try p.save()
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("autosave/project.json").path))
    }
}
@Test func videoImportUsesLocalOwnedCopy() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let source = root.appendingPathComponent("Fixtures/synthetic/basic.yapcam/recording/seg-000/screen.mov")
    let package = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-import-\(UUID().uuidString).yapcam")
    defer { try? FileManager.default.removeItem(at: package) }
    let p = try await Project.importVideo(source, package: package)
    #expect(p.durationNs == 3_000_000_000)
    #expect(p.session.tracks.screen.pixelSize == [320, 200])
    #expect(try p.frame(atNs: 0).cursor_visible == 0)
    #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("recording/seg-000/screen.mov").path))
    #expect(try Project.open(package: package).durationNs == p.durationNs)
    do { _ = try await Project.importVideo(source, package: package); Issue.record("Existing package overwritten") }
    catch CoreError.status(let status, _) { #expect(status == 1) }
}
@Test func audioSilenceDetectionAndTransactionalEdits() async throws {
    // Own generated PCM: 0.3 s quiet, 0.4 s sine, 0.3 s quiet. No real recordings.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-silence-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
    data.append(Data("RIFF".utf8)); append(UInt32(36 + 48_000*2)); data.append(Data("WAVEfmt ".utf8))
    append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(48_000)); append(UInt32(96_000)); append(UInt16(2)); append(UInt16(16))
    data.append(Data("data".utf8)); append(UInt32(48_000*2))
    for n in 0..<48_000 { let value = (14_400..<33_600).contains(n) ? Int16(sin(Double(n)*2 * .pi*440/48_000)*8_000) : 0; append(value) }
    try data.write(to: url)
    let silence = try await AudioAnalysis.silence(in: url, thresholdDB: -35, minimumNs: 200_000_000)
    #expect(silence.count == 2)
    #expect(silence[0].startNs == 0)
    #expect(abs(silence[0].endNs - 300_000_000) < 30_000_000)
    #expect(abs(silence[1].startNs - 700_000_000) < 30_000_000)
    try withFixture { package in
        let p = try Project.create(package: package)
        try p.apply(.processSilence(ranges: silence, speed: 2))
        #expect(p.durationNs < 5_000_000_000)
        try p.undo(); #expect(p.durationNs == 5_000_000_000)
    }
}

@Test func aacAudioAnalysisHasNoFalseSilence() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let source = root.appendingPathComponent("Fixtures/synthetic/basic.yapcam/recording/seg-000/system.m4a")
    do {
        let rows = try await AudioAnalysis.silence(in: source)
        #expect(rows.isEmpty)
    } catch CoreError.status(let code, let message) {
        // Restricted macOS execution can deny the AudioComponent decoder service.
        // A precise unavailable error is required; this does not verify AAC decode.
        #expect(code == 6 && message.contains("decoder unavailable"))
    }
}

@Test func relinkPreservesEditsAndRejectsEscapingPaths() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        try p.apply(.deleteRange(startNs: 0, endNs: 1_000_000_000))
        try p.apply(.set(path: "canvas.padding", value: .number(95))); try p.save()
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam/recording/seg-000/screen.mov")
        try FileManager.default.removeItem(at: package.appendingPathComponent("recording/seg-000/screen.mov"))
        let repaired = try Project.relink(package: package, replacements: ["recording/seg-000/screen.mov": source])
        #expect(repaired.durationNs == 4_000_000_000)
        #expect(try repaired.frame(atNs: 0).screen.src_ns == 1_000_000_000)
        #expect(!repaired.canUndo)
        let state = try JSONSerialization.jsonObject(with: repaired.toJSON()) as! [String: Any]
        #expect((state["canvas"] as? [String: Any])?["padding"] as? Double == 95)
        do { _ = try Project.relink(package: package, replacements: ["../outside.mov": source]); Issue.record("Escaping relink allowed") }
        catch CoreError.status(let code, _) { #expect(code == 1) }
    }
}

@Test func backgroundImageAndPortablePresetStayLocal() throws {
    try withFixture { first in
        try withFixture { second in
            let p = try Project.create(package: first)
            let other = try Project.create(package: second)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let image = root.appendingPathComponent("Fixtures/synthetic/basic.yapcam/recording/seg-000/cursors/1.png")
            let changes = try p.importBackgroundImage(image)
            #expect(changes.createdIDs.first?.hasPrefix("asset-") == true)
            #expect(try p.frame(atNs: 0).background_kind == 2)
            let preset = first.appendingPathComponent("image-preset.json")
            try p.exportPreset(to: preset)
            try other.importPreset(from: preset)
            #expect(try other.frame(atNs: 0).background_kind == 2)
            try other.save()
            #expect(try Project.open(package: second).frame(atNs: 0).background_kind == 2)
            try other.undo()
            #expect(try other.frame(atNs: 0).background_kind == 0)
            let noOp = try other.apply(.set(path: "canvas.padding", value: .number(48)))
            #expect(noOp.changed.isEmpty)
        }
    }
}

@Test func speakerNotesPersistWithUnicodeAndUndo() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        let notes = "Opening 👋\n第二行 — café"
        #expect(try p.apply(.set(path: "notes", value: .string(notes))).changed == ["notes"])
        #expect(try p.apply(.set(path: "notes", value: .string(notes))).changed.isEmpty)
        #expect(throws: CoreError.self) { try p.apply(.set(path: "notes", value: .number(12))) }
        try p.undo()
        let empty = try JSONSerialization.jsonObject(with: p.toJSON()) as! [String: Any]
        #expect(empty["notes"] as? String == "")
        try p.redo()
        try p.save()
        let reopened = try Project.open(package: package)
        let saved = try JSONSerialization.jsonObject(with: reopened.toJSON()) as! [String: Any]
        #expect(saved["notes"] as? String == notes)
    }
}

@Test func textReactionCaptionCommandsDecodeAndRetimeThroughABI() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        for (kind, text) in [(TextEffectKind.annotation, "Label 👋"), (.reaction, "🎉"), (.caption, "Caption")] {
            let change = try p.apply(.addText(kind, TextEffectRecord(startNs: 1_000_000_000, endNs: 3_000_000_000, text: text)))
            #expect(change.createdIDs.count == 1)
            let id = change.createdIDs[0]
            #expect(try p.textEffects(kind)[0].style.fontSize == 36)
            try p.apply(.updateText(kind, id: id, patch: ["text": .string("Edited")]))
            #expect(try p.textEffects(kind)[0].text == "Edited")
            try p.undo()
            #expect(try p.textEffects(kind)[0].text == text)
            try p.redo()
            try p.apply(.removeText(kind, id: id))
            #expect(try p.textEffects(kind).isEmpty)
            try p.undo()
        }
        let layers = try p.effects(atNs: 2_000_000_000).layers
        #expect(layers.filter { $0.kind == "text" }.count == 3)
        #expect(layers.first { $0.kind == "text" }?.fontSize == 36)
        struct Clip: Decodable { var id: String }
        let id = try p.query("{\"q\":\"clips\"}", as: [Clip].self)[0].id
        try p.apply(.setSpeed(clipID: id, speed: 2))
        #expect(try p.textEffects(.caption)[0].tlStartNs == 500_000_000)
        let snapshot = try p.snapshot()
        #expect(try p.effects(atNs: 750_000_000) == snapshot.effects(atNs: 750_000_000))
        try p.save()
        #expect(try Project.open(package: package).textEffects(.caption) == p.textEffects(.caption))
        try p.apply(.deleteRange(startNs: 500_000_000, endNs: 1_500_000_000))
        #expect(try p.textEffects(.caption).isEmpty)
        let large: Int64 = 9_007_199_254_740_993
        try p.apply(.addText(.annotation, TextEffectRecord(startNs: large, endNs: large + 101, text: "Exact")))
        #expect(try p.textEffects(.annotation).last?.tlStartNs == large)
    }
}

@Test func captureTranscriptJSONImportsAsEditedCaptionSegments() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        try p.apply(.deleteRange(startNs: 1_000_000_000, endNs: 2_000_000_000))
        let data = Data("""
        {"schema_version":1,"engine":"apple_speech_on_device","locale":"en-US","words":[
          {"text":"hello","src_start_ns":500000000,"src_end_ns":1500000000,"confidence":0.9,"segment_index":0,"track":"mic"},
          {"text":"world","src_start_ns":2000000000,"src_end_ns":3000000000,"confidence":1,"segment_index":0,"track":"mic"}]}
        """.utf8)
        let change = try p.importTranscript(data, style: TextStyle(fontSize: 42))
        #expect(change.createdIDs.count == 2)
        let captions = try p.textEffects(.caption)
        #expect(captions.map(\.tlStartNs) == [500_000_000, 1_000_000_000])
        #expect(captions.map(\.tlEndNs) == [1_000_000_000, 2_000_000_000])
        #expect(captions.allSatisfy { $0.style.fontSize == 42 })
        try p.importTranscript(data, replace: false)
        #expect(try p.textEffects(.caption).count == 4)
        try p.undo()
        #expect(try p.textEffects(.caption) == captions)
        #expect(throws: CoreError.self) { try p.importTranscript(Data("{\"schema_version\":2,\"words\":[]}".utf8)) }
        #expect(try p.textEffects(.caption) == captions)
    }
}

@Test func musicClickSoundAndPerLayoutCameraEffectsDecodeAcrossABI() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        let track = MusicTrack(startNs: 0, endNs: 5_000_000_000, source: "calm", gainDb: 0, fadeInNs: 1_000_000_000, fadeOutNs: 1_000_000_000, ducking: MusicDucking(enabled: true, gainDb: -20, attackNs: 0, releaseNs: 0, ranges: [TimelineActivityRange(startNs: 1_000_000_000, endNs: 2_000_000_000)]))
        let id = try p.apply(.addMusic(track)).createdIDs[0]
        #expect(try p.musicTracks()[0].ducking.gainDb == -20)
        #expect(abs(try p.effects(atNs: 500_000_000).audio[0].gainAt! - 0.5) < 1e-6)
        #expect(abs(try p.effects(atNs: 1_500_000_000).audio[0].gainAt! - 0.1) < 1e-6)
        try p.apply(.updateMusic(id: id, patch: ["gain_db": .number(-6)]))
        try p.apply(.set(path: "audio.click_sound.enabled", value: .bool(true)))
        #expect(try p.audioOverlays().filter { $0.source == "soft" }.count == p.clicks().count)
        let layout: JSONValue = .object(["id": .string("vision"), "mode": .string("overlay"), "tl_start_ns": .integer(1_000_000_000), "tl_end_ns": .integer(2_000_000_000), "camera_background_removal": .bool(true), "camera_face_framing": .bool(true), "camera_shadow_radius": .number(30)])
        try p.apply(.set(path: "camera.layouts", value: .array([layout])))
        let extras = try p.frameExtras(atNs: 1_500_000_000)
        let options = try p.effects(atNs: 1_500_000_000).renderOptions
        #expect(extras.camera_background_removal == 1 && options.cameraBackgroundRemoval)
        #expect(extras.camera_face_framing == 1 && options.cameraFaceFraming)
        #expect(try !p.renderOptions(atNs: 2_000_000_000).cameraFaceFraming)
        let normal = try p.frame(atNs: 0).screen_dest
        try p.apply(.set(path: "canvas.animation.entrance", value: .string("zoom")))
        #expect(abs(try p.frame(atNs: 0).screen_dest.w - normal.w * 0.85) < 1e-6)
        #expect(try p.frame(atNs: 400_000_000).screen_dest.w == normal.w)
        try p.apply(.removeMusic(id: id))
        #expect(try p.musicTracks().isEmpty)
        try p.undo()
        #expect(try p.musicTracks().count == 1)
    }
}

@Test func keyOverlaySetPathsUseCapturedKeyMetadata() throws {
    try withFixture { package in
        let events = package.appendingPathComponent("recording/seg-000/events.jsonl")
        var data = try Data(contentsOf: events)
        data.append(Data("\n{\"t\":1200000000,\"type\":\"key\",\"key\":\"k\",\"modifiers\":[\"cmd\",\"shift\"]}\n".utf8))
        try data.write(to: events)
        let p = try Project.create(package: package)
        try p.apply(.set(path: "cursor.key_overlay.enabled", value: .bool(true)))
        let layers = try p.renderLayers(atNs: 1_300_000_000)
        #expect(layers.last?.text == "⇧⌘k")
        #expect(try p.renderLayers(atNs: 2_200_000_000).isEmpty)
        try p.apply(.deleteRange(startNs: 1_000_000_000, endNs: 2_000_000_000))
        #expect(try p.renderLayers(atNs: 1_300_000_000).isEmpty)
    }
}
