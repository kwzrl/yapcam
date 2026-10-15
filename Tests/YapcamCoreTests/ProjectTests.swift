import Foundation
import Testing
import YapcamCore

private func withFixture<T>(_ body: (URL) throws -> T) throws -> T {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let source = root.appendingPathComponent("Fixtures/synthetic/basic.yapcam")
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-core-swift-\(UUID().uuidString).yapcam")
    defer { try? FileManager.default.removeItem(at: dest) }
    try FileManager.default.copyItem(at: source, to: dest)
    return try body(dest)
}
@Test func missingSourceDisplayNamesOpenForEveryKindAndDecodeInSwift() throws {
    for kind in ["display", "window", "area"] {
        for explicitNull in [false, true] {
            try withFixture { package in
                let url = package.appendingPathComponent("recording/session.json")
                var fields = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                var source = fields["source"] as! [String: Any]
                source["kind"] = kind; source["display_id"] = 42
                source["window_title"] = "Legacy Window"
                source.removeValue(forKey: "display_name")
                if explicitNull { source["display_name"] = NSNull() }
                fields["source"] = source
                let original = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
                try original.write(to: url)
                let expected = kind == "window" ? "Legacy Window" : "Display 42"
                let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                #expect(try decoder.decode(SessionInfo.self, from: original).source.displayName == expected)
                let p = try Project.create(package: package)
                #expect(p.session.source.displayName == expected)
                #expect(try p.frame(atNs: 0).screen.present == 1)
                #expect(try p.snapshot().session.source.displayName == expected)
                try p.save()
                #expect(try Project.open(package: package).session.source.displayName == expected)
                #expect(try Data(contentsOf: url) == original)
            }
        }
    }
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
private func expectClosed(_ operation: () throws -> Void) {
    do { try operation(); Issue.record("Closed project accepted a mutation") }
    catch CoreError.status(let code, let message) { #expect(code == 6 && message == "Project is closed") }
    catch { Issue.record("Unexpected close error: \(error)") }
}
@Test func projectCloseRejectsStaleWritesAndPreservesIndependentSnapshots() throws {
    try withFixture { package in
        let stale = try Project.create(package: package)
        try stale.apply(.set(path: "notes", value: .string("old document")))
        try stale.save()
        let snapshot = try stale.snapshot()
        let before = try stale.toJSON()
        stale.close(); stale.close()
        let reopened = try Project.open(package: package)
        try reopened.apply(.set(path: "notes", value: .string("new document")))
        try reopened.save()
        let primary = try Data(contentsOf: package.appendingPathComponent("project.json"))
        let previous = try Data(contentsOf: package.appendingPathComponent("project.json.prev"))
        expectClosed { try stale.apply(.set(path: "notes", value: .string("late callback"))) }
        expectClosed { try stale.undo() }
        expectClosed { try stale.redo() }
        expectClosed { try stale.save() }
        #expect(try stale.toJSON() == before)
        #expect(try stale.frame(atNs: 0).tl_ns == 0)
        #expect(try stale.snapshot().toJSON() == before)
        try snapshot.apply(.set(path: "notes", value: .string("export snapshot")))
        #expect(try snapshot.toJSON() != before)
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("autosave/project.json").path))
        #expect(try Data(contentsOf: package.appendingPathComponent("project.json")) == primary)
        #expect(try Data(contentsOf: package.appendingPathComponent("project.json.prev")) == previous)
        #expect(try Project.open(package: package).toJSON() == reopened.toJSON())
    }
}
@Test func projectCloseJoinsConcurrentDurableWritersBeforeReopen() throws {
    try withFixture { package in
        let stale = try Project.create(package: package)
        try stale.save()
        let started = DispatchSemaphore(value: 0)
        let resumed = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let check = ConcurrentEditCheck()
        finished.enter()
        DispatchQueue(label: "core-close-regression").async {
            defer { finished.leave() }
            started.signal()
            for n in 0..<24 {
                do { try stale.apply(.set(path: "notes", value: .string("racing \(n)"))) }
                catch CoreError.status(6, "Project is closed") { }
                catch { check.failed(error) }
            }
            resumed.wait()
            for _ in 0..<8 {
                for operation in [{ _ = try stale.apply(.set(path: "notes", value: .string("late"))) }, { try stale.save() }, { try stale.undo() }, { try stale.redo() }] {
                    do { try operation(); check.failed(CoreError.status(99, "Late write accepted")) }
                    catch CoreError.status(6, "Project is closed") { }
                    catch { check.failed(error) }
                }
            }
        }
        // Always release/join the worker before removing its fixture, including errors.
        defer { resumed.signal(); finished.wait() }
        started.wait()
        stale.close()
        let reopened = try Project.open(package: package)
        try reopened.apply(.set(path: "notes", value: .string("reopened")))
        try reopened.save()
        let primary = try Data(contentsOf: package.appendingPathComponent("project.json"))
        resumed.signal(); finished.wait()
        #expect(check.result.1.isEmpty)
        #expect(try Data(contentsOf: package.appendingPathComponent("project.json")) == primary)
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("autosave/project.json").path))
        #expect(try Project.open(package: package).toJSON() == reopened.toJSON())
    }
}
@Test func projectChangeObserverCanCloseWithoutReenteringMutationGate() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        let token = NotificationCenter.default.addObserver(forName: Project.didChange, object: p, queue: nil) { _ in p.close() }
        defer { NotificationCenter.default.removeObserver(token) }
        try p.apply(.set(path: "notes", value: .string("observer closes")))
        expectClosed { try p.apply(.set(path: "notes", value: .string("too late"))) }
        expectClosed { try p.save() }
        #expect(try p.frame(atNs: 0).tl_ns == 0)
    }
}
@Test func editorAspectPresetsProduceTheirDeclaredOutputDimensions() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        let original = try p.frame(atNs: 0)
        let cases: [(String, Int64, Int64)] = [
            ("4:3", 1440, 1080), ("1:1", 1080, 1080),
            ("9:16", 1080, 1920), ("21:9", 2520, 1080), ("custom", 1234, 777)
        ]
        for (aspect, width, height) in cases {
            try p.apply(.batch([
                .set(path: "canvas.aspect", value: .string(aspect)),
                .set(path: "canvas.output_size", value: .array([.integer(width), .integer(height)]))
            ]))
            for time: Int64 in [0, 2_500_000_000, 4_999_999_999] {
                let frame = try p.frame(atNs: time)
                #expect(frame.canvas_w == width && frame.canvas_h == height)
            }
            try p.save()
            let frame = try Project.open(package: package).frame(atNs: 0)
            #expect(frame.canvas_w == width && frame.canvas_h == height)
            try p.undo()
            let restored = try p.frame(atNs: 0)
            #expect(restored.canvas_w == original.canvas_w && restored.canvas_h == original.canvas_h)
        }
    }
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
        #expect(f.canvas_w == 1728 && f.canvas_h == 1080)
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
        #expect(zooms.count == 1)
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
            let noOp = try other.apply(.set(path: "canvas.padding_ratio", value: .number(0.1)))
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
        let data = try Data(contentsOf: events)
        var rows = try String(decoding: data, as: UTF8.self).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        rows.append(["t": 1_200_000_000, "type": "key", "key": "k", "modifiers": ["cmd", "shift"]])
        rows.sort { ($0["t"] as! NSNumber).int64Value < ($1["t"] as! NSNumber).int64Value }
        let lines = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        try Data(lines.utf8).write(to: events)
        let p = try Project.create(package: package)
        try p.apply(.set(path: "cursor.key_overlay.enabled", value: .bool(true)))
        let layers = try p.renderLayers(atNs: 1_300_000_000)
        #expect(layers.last?.text == "⇧⌘k")
        #expect(try p.renderLayers(atNs: 2_200_000_000).isEmpty)
        try p.apply(.deleteRange(startNs: 1_000_000_000, endNs: 2_000_000_000))
        #expect(try p.renderLayers(atNs: 1_300_000_000).isEmpty)
    }
}

@Test func musicImportOwnsAudioCopyAndRollsBackFailedEdit() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let package = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-music-test-\(UUID().uuidString).yapcam")
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-music-source-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: package) }
    try FileManager.default.copyItem(at: root.appendingPathComponent("Fixtures/synthetic/basic.yapcam"), to: package)
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
    data.append(Data("RIFF".utf8)); append(UInt32(36 + 8_000*2)); data.append(Data("WAVEfmt ".utf8))
    append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(8_000)); append(UInt32(16_000)); append(UInt16(2)); append(UInt16(16))
    data.append(Data("data".utf8)); append(UInt32(8_000*2))
    for n in 0..<8_000 { append(Int16(sin(Double(n)*2 * .pi*440/8_000)*2_000)) }
    try data.write(to: file)
    let p = try Project.create(package: package)
    let change = try await p.importMusic(file, endNs: 5_000_000_000)
    #expect(change.createdIDs.count == 2)
    let track = try p.musicTracks()[0]
    #expect(track.fileDurationNs == 1_000_000_000)
    #expect(track.path.hasPrefix("assets/music-"))
    #expect(try Data(contentsOf: package.appendingPathComponent(track.path)) == data)
    #expect(try Data(contentsOf: file) == data)
    try p.undo()
    #expect(try p.musicTracks().isEmpty)
    try p.redo()
    #expect(try p.musicTracks()[0].path == track.path)
    do { try await p.importMusic(file, startNs: 1_000_000_000, endNs: 0); Issue.record("Invalid music range was accepted") }
    catch CoreError.status { }
    let files = try FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("assets").path)
    #expect(files.count == 1)
    #expect(try p.musicTracks().count == 1)
    try p.save()
    #expect(try Project.open(package: package).musicTracks() == p.musicTracks())
    let primary = try Data(contentsOf: package.appendingPathComponent("project.json"))
    p.close()
    do { try await p.importMusic(file); Issue.record("Closed music import accepted") }
    catch CoreError.status(let code, let message) { #expect(code == 6 && message == "Project is closed") }
    #expect(try FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("assets").path).count == 1)
    #expect(try Data(contentsOf: package.appendingPathComponent("project.json")) == primary)
    #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("autosave/project.json").path))
}

private func withGuideCursorFixture<T>(_ body: (URL) throws -> T) throws -> T {
    try withFixture { package in
        let events = """
        {"t":0,"type":"cursor","id":5}
        {"t":0,"type":"move","x":100,"y":100}
        {"t":100000000,"type":"move","x":100.25,"y":100}
        {"t":200000000,"type":"move","x":99.75,"y":100}
        {"t":300000000,"type":"move","x":100.2,"y":100}
        {"t":400000000,"type":"move","x":200,"y":100}
        {"t":500000000,"type":"move","x":200,"y":100}
        {"t":550000000,"type":"cursor","id":6}
        {"t":570000000,"type":"cursor","id":5}
        {"t":600000000,"type":"cursor","id":7}
        {"t":700000000,"type":"cursor","id":7}
        """
        try Data(events.utf8).write(to: package.appendingPathComponent("recording/seg-000/events.jsonl"))
        return try body(package)
    }
}

@Test func guideCursorOptionsAndMotionABIAreDeterministic() throws {
    try withGuideCursorFixture { package in
        let p = try Project.create(package: package)
        try p.apply(.set(path: "cursor.smoothing", value: .number(0)))
        let first = try p.frame(atNs: 0)
        #expect(first.cursor_id == 5)
        try p.apply(.batch([
            .set(path: "cursor.remove_shakes", value: .bool(true)),
            .set(path: "cursor.optimize_types", value: .bool(true)),
            .set(path: "cursor.rotate_on_move", value: .bool(true)),
            .set(path: "cursor.motion_blur", value: .number(0.7))
        ]))
        #expect(try p.frame(atNs: 100_000_000).cursor_x == first.cursor_x)
        #expect(try p.frame(atNs: 300_000_000).cursor_x == first.cursor_x)
        #expect(try p.frame(atNs: 560_000_000).cursor_id == 5)
        #expect(try p.frame(atNs: 680_000_000).cursor_id == 7)
        let motion = try p.frameMotion(atNs: 350_000_000)
        #expect(abs(motion.cursor_rotation_rad - Float.pi / 12) < 1e-6)
        #expect(motion.cursor_motion_blur == 0.7)
        let typed = try p.motion(atNs: 350_000_000)
        #expect(abs(typed.cursorRotationRad - Double(motion.cursor_rotation_rad)) < 1e-7)
        #expect(try p.effects(atNs: 350_000_000).renderOptions.cursorRotationRad == typed.cursorRotationRad)
        #expect(try p.frameMotion(atNs: 500_000_000).cursor_rotation_rad == 0)
        let snap = try p.snapshot()
        for t: Int64 in [700_000_000, 0, 350_000_000, 500_000_000] {
            #expect(try p.motion(atNs: t) == snap.motion(atNs: t))
        }
        try p.apply(.set(path: "cursor.always_default", value: .bool(true)))
        #expect(try p.frame(atNs: 700_000_000).cursor_id == 0)
        #expect(try p.frameExtras(atNs: 700_000_000).cursor_style == 1)
        #expect(try p.renderOptions().cursorStyle == .pointer)
        try p.undo()
        #expect(try p.frame(atNs: 700_000_000).cursor_id == 7)
        #expect(throws: CoreError.self) { try p.frameMotion(atNs: -1) }
        #expect(throws: CoreError.self) { try p.frameMotion(atNs: 5_000_000_001) }
        #expect(MemoryLayout<YcFrameMotion>.size == 24)
        #expect(MemoryLayout<YcFrameMotion>.alignment == 8)
        #expect(MemoryLayout<YcFrame>.size == 328 && MemoryLayout<YcFrameExtras>.size == 2600)
        #expect(yc_frame_motion_at(nil, 0, nil) == YC_ERR_INVALID_ARGUMENT)
        try p.save()
        #expect(try Project.open(package: package).motion(atNs: 350_000_000) == p.motion(atNs: 350_000_000))
    }
}

@Test func cursorTailHoldRecomputesOnCutsAndSupportsLongInt64Settings() throws {
    try withGuideCursorFixture { package in
        let p = try Project.create(package: package)
        try p.apply(.set(path: "cursor.smoothing", value: .number(0)))
        try p.apply(.set(path: "cursor.stop_before_end_ns", value: .integer(4_700_000_000)))
        let stop = try p.frame(atNs: 300_000_000)
        for t: Int64 in [5_000_000_000, 700_000_000, 400_000_000] {
            #expect(try p.frame(atNs: t).cursor_x == stop.cursor_x)
            #expect(try p.frameMotion(atNs: t).cursor_rotation_rad == 0)
        }
        try p.apply(.deleteRange(startNs: 1_000_000_000, endNs: 2_000_000_000))
        #expect(try p.frame(atNs: 3_000_000_000).cursor_x == p.frame(atNs: 0).cursor_x)
        try p.undo()
        #expect(try p.frame(atNs: 700_000_000).cursor_x == stop.cursor_x)
        try p.apply(.set(path: "cursor.stop_before_end_ns", value: .integer(9_007_199_254_740_993)))
        #expect(try p.frame(atNs: 700_000_000).cursor_x == p.frame(atNs: 0).cursor_x)
        #expect(throws: CoreError.self) { try p.apply(.set(path: "cursor.stop_before_end_ns", value: .integer(-1))) }
    }
}

@Test func screenMotionPresetsPerKindBlurAndOriginalMusicLibrary() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        try p.apply(.addZoom(ZoomSpec(startNs: 0, endNs: 2_000_000_000, easeInNs: 500_000_000, easeOutNs: 500_000_000)))
        try p.apply(.set(path: "zoom_settings.animation_style", value: .string("focused")))
        let focused = try p.frame(atNs: 200_000_000).screen_crop.w
        try p.apply(.set(path: "zoom_settings.animation_style", value: .string("smooth")))
        #expect(try p.frame(atNs: 200_000_000).screen_crop.w != focused)
        try p.apply(.batch([
            .set(path: "canvas.motion_blur_settings.zoom", value: .number(0.6)),
            .set(path: "canvas.motion_blur_settings.pan", value: .number(0)),
            .set(path: "camera.zoom_scale", value: .number(1.5))
        ]))
        #expect(try p.frameMotion(atNs: 200_000_000).zoom_motion_blur == 0.6)
        #expect(try p.frame(atNs: 200_000_000).motion_blur == 0.6)
        #expect(try p.frameMotion(atNs: 1_000_000_000).zoom_motion_blur == 0)
        #expect(throws: CoreError.self) { try p.apply(.set(path: "camera.zoom_scale", value: .number(5))) }
        #expect(throws: CoreError.self) { try p.apply(.set(path: "zoom_settings.animation_style", value: .string("missing"))) }
        let library = try p.musicLibrary()
        #expect(library.map(\.id) == ["calm", "bright"])
        #expect(library.allSatisfy { $0.durationNs == 8_000_000_000 })
        try p.save()
        #expect(try Project.open(package: package).frameMotion(atNs: 200_000_000).zoom_motion_blur == 0.6)
    }
}

@Test func prereleaseProjectMigrationKeepsMediaClocksAndAddsGuideDefaults() throws {
    try withFixture { package in
        let original = try Project.create(package: package)
        var legacy = try JSONSerialization.jsonObject(with: original.toJSON()) as! [String: Any]
        let media = legacy["media"] as! [[String: Any]]
        let clips = legacy["timeline"] as! [String: Any]
        legacy["schema_version"] = 0
        for field in ["cursor", "camera", "canvas", "zoom_settings", "audio", "notes", "autosave"] { legacy.removeValue(forKey: field) }
        try JSONSerialization.data(withJSONObject: legacy).write(to: package.appendingPathComponent("project.json"))
        let migrated = try Project.open(package: package)
        #expect(migrated.durationNs == original.durationNs)
        #expect(try migrated.frame(atNs: 700_000_000).screen.src_ns == original.frame(atNs: 700_000_000).screen.src_ns)
        #expect(try migrated.renderOptions().cursorStyle == .recorded)
        #expect(try migrated.frameMotion(atNs: 700_000_000).cursor_rotation_rad == 0)
        let json = try JSONSerialization.jsonObject(with: migrated.toJSON()) as! [String: Any]
        #expect(json["schema_version"] as? Int == 1)
        #expect(NSDictionary(dictionary: json["timeline"] as! [String: Any]) == NSDictionary(dictionary: clips))
        #expect(NSArray(array: json["media"] as! [[String: Any]]) == NSArray(array: media))
        #expect((json["camera"] as? [String: Any])?["zoom_scale"] as? Double == 1)
        #expect((json["cursor"] as? [String: Any])?["always_default"] as? Bool == false)
        try migrated.save()
        #expect(try Project.open(package: package).toJSON() == migrated.toJSON())
    }
}


@Test func fixedArrowStyleUsesAdditiveExtrasCodeAndDefaultOverride() throws {
    try withGuideCursorFixture { package in
        let p = try Project.create(package: package)
        let originalID = try p.frame(atNs: 0).cursor_id
        try p.apply(.set(path: "cursor.style", value: .string("arrow")))
        #expect(try p.frame(atNs: 0).cursor_id == originalID)
        for t: Int64 in [0, 700_000_000, 5_000_000_000] {
            #expect(try p.frameExtras(atNs: t).cursor_style == 3)
            #expect(try p.renderOptions(atNs: t).cursorStyle == .arrow)
            #expect(try p.effects(atNs: t).renderOptions.cursorStyle == .arrow)
        }
        #expect(try p.renderOptions().cursorStyle == .arrow)
        let frozen = try p.snapshot()
        try p.apply(.set(path: "cursor.always_default", value: .bool(true)))
        #expect(try p.frameExtras(atNs: 0).cursor_style == 1)
        #expect(try p.renderOptions().cursorStyle == .pointer)
        #expect(try p.frame(atNs: 0).cursor_id == 0)
        #expect(try frozen.renderOptions().cursorStyle == .arrow)
        try p.undo()
        try p.save()
        #expect(try Project.open(package: package).renderOptions().cursorStyle == .arrow)
        try p.undo()
        #expect(try p.renderOptions().cursorStyle == .recorded)
        try p.redo()
        #expect(try p.frameExtras(atNs: 0).cursor_style == 3)
        #expect(throws: CoreError.self) { try p.apply(.set(path: "cursor.style", value: .string("unknown"))) }
        #expect(try p.renderOptions().cursorStyle == .arrow)
        #expect(MemoryLayout<YcFrameExtras>.size == 2600 && yc_abi_version() == 3)
    }
}

@Test func indexedKeyOverlayRemapsAcrossFFIHistoryAndKeepsSnapshots() throws {
    try withFixture { package in
        let events = package.appendingPathComponent("recording/seg-000/events.jsonl")
        let keys = [
            #"{"t":1200000000,"type":"key","key":"k","modifiers":["cmd","shift"]}"#,
            #"{"t":1250000000,"type":"key","key":"x","modifiers":["shift"]}"#
        ]
        try Data((keys.joined(separator: "\n") + "\n").utf8).write(to: events)
        try Data().write(to: package.appendingPathComponent("recording/seg-001/events.jsonl"))
        let p = try Project.create(package: package)
        try p.apply(.batch([
            .set(path: "cursor.key_overlay.enabled", value: .bool(true)),
            .set(path: "cursor.key_overlay.duration_ns", value: .integer(500_000_000))
        ]))
        #expect(try p.renderLayers(atNs: 1_300_000_000).last?.text == "⇧⌘k")
        #expect(try p.renderLayers(atNs: 1_700_000_000).isEmpty)
        let frozen = try p.snapshot()
        try p.apply(.set(path: "cursor.key_overlay.shortcuts_only", value: .bool(false)))
        #expect(try p.renderLayers(atNs: 1_300_000_000).last?.text == "⇧x")
        #expect(try frozen.renderLayers(atNs: 1_300_000_000).last?.text == "⇧⌘k")
        try p.undo()
        let clips = try p.query("{\"q\":\"clips\"}", as: [ClipInfo].self)
        try p.apply(.setSpeed(clipID: clips[0].id, speed: 2))
        let mapped = try p.query("{\"q\":\"key_events\"}", as: [[String: JSONValue]].self)
        #expect(mapped.map { $0["tl_ns"]?.integerValue } == [600_000_000, 625_000_000])
        #expect(try p.renderLayers(atNs: 650_000_000).last?.text == "⇧⌘k")
        try p.apply(.deleteRange(startNs: 500_000_000, endNs: 700_000_000))
        #expect(try p.renderLayers(atNs: 650_000_000).isEmpty)
        try p.undo()
        #expect(try p.renderLayers(atNs: 650_000_000).last?.text == "⇧⌘k")
        try p.undo()
        #expect(try p.renderLayers(atNs: 1_300_000_000).last?.text == "⇧⌘k")
        try p.redo(); try p.redo(); try p.save()
        #expect(try Project.open(package: package).renderLayers(atNs: 650_000_000).isEmpty)
        #expect(try frozen.renderLayers(atNs: 1_300_000_000).last?.text == "⇧⌘k")
    }
}

@Test func authoredCursorPaletteShapeAndSizeDecodeAndPreserveLegacyFrames() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        let catalog = try p.cursorLibrary()
        #expect(catalog.sets.count == 12 && catalog.shapes.count == 10 && catalog.logicalSizes.count == 4)
        #expect(catalog.sets.first?.id == "classic" && catalog.sets.last?.id == "signal")
        #expect(catalog.shapes == CoreRenderOptions.CursorShape.allCases)
        #expect(catalog.logicalSizes.map(\.scale) == [0.75, 1, 1.5, 2])
        let original = try p.frame(atNs: 0)
        #expect(try p.renderOptions().cursorSetId == "classic" && p.renderOptions().cursorShape == nil)
        #expect(try p.renderOptions().cursorLogicalSize == .regular)
        for shape in catalog.shapes {
            try p.apply(.set(path: "cursor.shape", value: .string(shape.rawValue)))
            #expect(try p.renderOptions().cursorShape == shape)
        }
        try p.apply(.batch([
            .set(path: "cursor.set_id", value: .string("signal")),
            .set(path: "cursor.shape", value: .string("pointing_hand")),
            .set(path: "cursor.logical_size", value: .string("extra_large"))
        ]))
        #expect(try p.renderOptions().cursorSetId == "signal")
        #expect(try p.renderOptions().cursorLogicalSize == .extraLarge)
        #expect(try p.frame(atNs: 0).cursor_scale == original.cursor_scale)
        #expect(try p.frameExtras(atNs: 0).cursor_style == 0)
        let frozen = try p.snapshot()
        try p.apply(.set(path: "cursor.always_default", value: .bool(true)))
        for t: Int64 in [0, 2_500_000_000, 5_000_000_000] {
            #expect(try p.renderOptions(atNs: t).cursorShape == .arrow)
            #expect(try p.effects(atNs: t).renderOptions.cursorStyle == .pointer)
            #expect(try p.renderOptions(atNs: t).cursorSetId == "signal")
            #expect(try p.frameExtras(atNs: t).cursor_style == 1)
        }
        #expect(try frozen.renderOptions().cursorShape == .pointingHand)
        try p.undo(); try p.save()
        #expect(try Project.open(package: package).renderOptions() == p.renderOptions())
        #expect(throws: CoreError.self) { try p.apply(.set(path: "cursor.logical_size", value: .string("extraLarge"))) }
        #expect(throws: CoreError.self) { try p.apply(.set(path: "cursor.set_id", value: .string("unknown"))) }
        try p.apply(.batch([.set(path: "cursor.set_id", value: .null), .set(path: "cursor.shape", value: .null)]))
        #expect(try p.renderOptions().cursorSetId == nil && p.renderOptions().cursorShape == nil)
        try p.undo()
        #expect(try p.renderOptions().cursorShape == .pointingHand)
        #expect(yc_abi_version() == 3 && MemoryLayout<YcFrameExtras>.size == 2600)
    }
}

@Test func alignedNewProjectDefaultsPreserveFrozenOlderAppearance() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        let options = try p.renderOptions()
        #expect(options.paddingRatio == 0.1 && options.cursorSizePoints == 48)
        #expect(options.cursorSetId == "classic")
        #expect(options.screenShadow?.style == "directional")
        #expect(abs((options.screenShadow?.offsetX ?? 0) - 25 / sqrt(2)) < 0.000001)
        let frame = try p.frame(atNs: 0)
        #expect(frame.screen_corner_radius == 16 && frame.shadow_radius == 160)
        #expect(frame.canvas_w == 1728 && frame.canvas_h == 1080)
        try p.apply(.set(path: "canvas.padding", value: .number(12)))
        #expect(try p.renderOptions().paddingRatio == nil)
        try p.undo(); try p.save()
        #expect(try Project.open(package: package).renderOptions() == options)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for name in ["v0-prerelease", "v1-minimal"] {
            let fixture = root.appendingPathComponent("Fixtures/schema/\(name).json")
            try Data(contentsOf: fixture).write(to: package.appendingPathComponent("project.json"))
            let old = try Project.open(package: package)
            #expect(try old.renderOptions().paddingRatio == nil)
            #expect(try old.renderOptions().cursorSizePoints == nil)
            #expect(try old.renderOptions().cursorSetId == nil)
            #expect(try old.renderOptions().screenShadow?.style == "classic")
            let legacy = try old.frame(atNs: 0)
            #expect(legacy.canvas_w == 1920 && legacy.screen_corner_radius == 18)
            #expect(legacy.shadow_radius == 24 && legacy.shadow_offset_y == 8)
            try old.save()
            #expect(try Project.open(package: package).renderOptions() == old.renderOptions())
        }
    }
}

@Test func typingSuggestionCommandsUseSourceIDsAndRememberSpeed() throws {
    try withFixture { package in
        let lines = (0...5).map { "{\"t\":\(100_000_000 + $0 * 300_000_000),\"type\":\"key\",\"key\":\"a\"}" }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: package.appendingPathComponent("recording/seg-000/events.jsonl"))
        let p = try Project.create(package: package)
        let rows = try p.typingSuggestions()
        #expect(rows.count == 1 && rows[0].keyCount == 6 && rows[0].speed == 3)
        let id = try #require(rows.first?.id)
        let original = p.durationNs
        try p.apply(.dismissTypingSuggestion(id: id))
        #expect(try p.typingSuggestions().isEmpty)
        try p.save()
        #expect(try Project.open(package: package).typingSuggestions().isEmpty)
        try p.undo(); #expect(try p.typingSuggestions() == rows)
        try p.redo(); try p.apply(.restoreTypingSuggestions)
        let snapshot = try p.snapshot()
        try p.apply(.applyTypingSuggestion(id: id, speed: 2))
        #expect(p.durationNs == original - 750_000_000)
        #expect(try p.typingSuggestions()[0].speed == 2)
        #expect(try p.typingSuggestions()[0].ranges[0].tlEndNs == 850_000_000)
        #expect(try snapshot.typingSuggestions() == rows)
        #expect(try p.apply(.autoSpeedTyping()).changed.isEmpty)
        try p.undo(); #expect(p.durationNs == original)
        try p.redo(); try p.save()
        #expect(try Project.open(package: package).typingSuggestions() == p.typingSuggestions())
        #expect(throws: CoreError.self) { try p.apply(.applyTypingSuggestion(id: id, speed: 9)) }
        #expect(throws: CoreError.self) { try p.apply(.dismissTypingSuggestion(id: "unknown")) }
    }
}

@Test func microphonePresetsExposeOfflinePlanAndStereoPreference() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        #expect(try p.speechEnhancementPlan().micPreset == .voice)
        #expect(try p.speechEnhancementPlan().stereoMic == false)
        #expect(try !p.speechEnhancementPlan().enabled)
        try p.setMicrophonePreset(.noiseReduction)
        #expect(try p.speechEnhancementPlan().enabled)
        #expect(try p.speechEnhancementPlan().settings.compressorRatio == 1)
        try p.setMicrophonePreset(.podcast)
        try p.apply(.set(path: "audio.stereo_mic", value: .bool(true)))
        let plan = try p.speechEnhancementPlan()
        #expect(plan.micPreset == .podcast && plan.stereoMic == true)
        #expect(plan.settings.compressorRatio == 4 && plan.settings.normalizeLoudness)
        try p.save()
        #expect(try Project.open(package: package).speechEnhancementPlan() == plan)
        try p.undo(); #expect(try p.speechEnhancementPlan().stereoMic == false)
        try p.redo(); try p.setMicrophonePreset(.voice)
        #expect(try !p.speechEnhancementPlan().enabled)
        #expect(throws: CoreError.self) { try p.apply(.set(path: "audio.mic_preset", value: .string("unavailable"))) }
    }
}

@Test func explicitLegacyDefaultsRemainUnchangedOnOpenAndSave() throws {
    try withFixture { package in
        let fields: [String: Any] = [
            "schema_version": 1, "id": "legacy-explicit-settings", "created_at": "", "modified_at": "",
            "recording": "recording/session.json", "timeline": ["clips": [["id": "c", "src_start_ns": 0, "src_end_ns": 5_000_000_000 as Int64, "speed": 1]]],
            "canvas": ["aspect": "4:3", "output_size": [1440, 900], "padding": 31, "radius": 11,
                       "shadow": ["radius": 13, "opacity": 0.2, "offset_y": -4], "motion_blur": 0.4],
            "cursor": ["set_id": NSNull(), "size": 1.7, "smoothing": 0.25, "motion_blur": 0.2],
            "zoom_settings": ["spring": ["tension": 310, "friction": 31, "mass": 2, "allow_overshoot": false]]
        ]
        let url = package.appendingPathComponent("project.json")
        let original = try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
        try original.write(to: url)
        let p = try Project.open(package: package)
        #expect(try Data(contentsOf: url) == original)
        let state = try p.query("{\"q\":\"project\"}", as: [String: JSONValue].self)
        #expect(state["defaults_revision"]?.integerValue == 0)
        let decoded = try JSONSerialization.jsonObject(with: p.toJSON()) as! [String: Any]
        let canvas = decoded["canvas"] as! [String: Any], cursor = decoded["cursor"] as! [String: Any]
        let zoom = decoded["zoom_settings"] as! [String: Any], spring = zoom["spring"] as! [String: Any]
        #expect(canvas["padding"] as? Double == 31 && canvas["motion_blur"] as? Double == 0.4)
        #expect(cursor["size"] as? Double == 1.7 && cursor["smoothing"] as? Double == 0.25)
        #expect(cursor["motion_blur"] as? Double == 0.2 && cursor["physics_version"] as? Int == 0)
        #expect(spring["tension"] as? Double == 310 && spring["friction"] as? Double == 31 && spring["mass"] as? Double == 2)
        #expect(zoom["physics_version"] as? Int == 0)
        let options = try p.renderOptions(), frame = try p.frame(atNs: 0)
        #expect(options.cursorSetId == nil && options.paddingRatio == nil && options.cursorSizePoints == nil)
        #expect(options.screenShadow?.style == "classic")
        #expect(frame.canvas_w == 1200 && frame.canvas_h == 900 && frame.screen_corner_radius == 11)
        #expect(frame.shadow_radius == 13 && frame.shadow_offset_y == -4)
        try p.save()
        let reopened = try Project.open(package: package)
        #expect(try reopened.renderOptions() == options)
        let saved = try reopened.query("{\"q\":\"project\"}", as: [String: JSONValue].self)
        for group in ["canvas", "cursor", "zoom_settings"] { #expect(saved[group] == state[group]) }
        #expect(try reopened.frame(atNs: 0).cursor_scale == frame.cursor_scale)
    }
}

@Test func checkedTimelineMinimumsAndClipSettingsUseAdditiveCommands() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        let before = try p.toJSON()
        #expect(throws: CoreError.self) { try p.apply(.timelineEdit(.split(atNs: 99_999_999))) }
        #expect(try p.toJSON() == before && !p.canUndo)
        try p.apply(.timelineEdit(.split(atNs: 100_000_000)))
        let clips = try p.query("{\"q\":\"clips\"}", as: [ClipInfo].self)
        try p.apply(.setClipSettings(clipID: clips[0].id, patch: ["system_gain": .number(0), "hide_cursor": .bool(true)]))
        #expect(try p.frame(atNs: 0).system_gain == 0 && p.frame(atNs: 0).cursor_visible == 0)
        #expect(try p.frame(atNs: 200_000_000).system_gain == 1)
        try p.apply(.insertTimelineItem(.zoom))
        #expect(try p.query("{\"q\":\"zooms\"}", as: [[String: JSONValue]].self).last?["tl_end_ns"]?.integerValue == 3_000_000_000)
        try p.apply(.insertTimelineItem(.mask))
        try p.save()
        let reopened = try Project.open(package: package)
        #expect(try reopened.query("{\"q\":\"clips\"}", as: [ClipInfo].self)[0].settings?.systemGain == 0)
        #expect(throws: CoreError.self) { try p.apply(.insertTimelineItem(.layout, durationNs: 499_999_999)) }
    }
}

@Test func coalescedInteractiveEditsKeepOneUndoStateThroughABI() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        try p.apply(.set(path: "autosave", value: .bool(false)))
        let initial = try p.historyState().undoSteps
        for value: Double in [30, 31, 32] {
            try p.apply(.coalescedEdit(key: "padding-drag", command: .set(path: "canvas.padding", value: .number(value))))
        }
        #expect(try p.historyState().undoSteps == initial + 1)
        #expect(try p.historyState().limit == 1000 && p.historyState().coalesceMs == 100)
        try p.undo(); #expect(try p.renderOptions().paddingRatio == 0.1)
        try p.redo(); #expect(try p.renderOptions().paddingRatio == nil)
        let limits = try p.timelineConstraints()
        #expect(limits.clipMinNs == 100_000_000 && limits.maskMinNs == 500_000_000 && limits.insertDurationNs == 3_000_000_000)
        try p.apply(.set(path: "notes", value: .string("discrete")))
        #expect(try p.historyState().undoSteps == initial + 2)
    }
}

@Test func lastEditedInsertionStylesPersistWithoutCopyingGeometry() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        #expect(try p.insertionStyles().zoom == nil)
        let changes = try p.apply(.insertTimelineItem(.zoom, patch: ["scale": .number(3), "target": .array([.number(0.1), .number(0.2)])]))
        let id = try #require(changes.createdIDs.first)
        try p.apply(.updateZoom(id: id, patch: ["scale": .number(2.5)]))
        try p.save()
        let reopened = try Project.open(package: package)
        #expect(try reopened.insertionStyles().zoom?.scale == 2.5)
        try reopened.apply(.insertTimelineItem(.zoom, startNs: 1_000_000_000))
        let zooms = try reopened.query("{\"q\":\"zooms\"}", as: [[String: JSONValue]].self)
        #expect(zooms.last?["scale"]?.numberValue == 2.5)
        #expect(zooms.last?["target"] == .array([.number(0.5), .number(0.5)]))
        try p.undo(); #expect(try p.insertionStyles().zoom?.scale == 3)
    }
}

@Test func capabilityGatesPreserveStoredAppearanceThroughABI() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
        #expect(try p.capabilities().canCursor && p.capabilities().canCrop)
        #expect(try !p.capabilities().canCamera && !p.capabilities().canExternalAudio)
        try p.apply(.batch([.set(path: "canvas.crop", value: .array([0.1,0.1,0.7,0.7].map(JSONValue.number))), .set(path: "canvas.inset", value: .number(4))]))
        let before = try p.frame(atNs: 0)
        try p.apply(.set(path: "canvas.device_frame", value: .string("own-generic-frame")))
        #expect(try !p.capabilities().canCrop && !p.capabilities().canRoundCorners && !p.capabilities().canInset)
        #expect(try p.frame(atNs: 0).screen_crop.w == 1 && p.frame(atNs: 0).screen_corner_radius == 0 && p.frame(atNs: 0).inset_width == 0)
        try p.save()
        #expect(try Project.open(package: package).capabilities().deviceFrameActive)
        try p.undo(); #expect(try p.frame(atNs: 0).screen_crop.w == before.screen_crop.w)
    }
}
