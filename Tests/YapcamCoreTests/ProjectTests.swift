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
@Test func projectLifecycleAndCFrameLayout() throws {
    try withFixture { package in
        let p = try Project.create(package: package)
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
