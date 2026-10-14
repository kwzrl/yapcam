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
