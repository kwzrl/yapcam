import Foundation
import Testing
@testable import YapcamCore

private func autosaveFixture() throws -> URL {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
    let package = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-core-autosave-\(UUID().uuidString).yapcam")
    do { try FileManager.default.copyItem(at: fixtures, to: package); return package }
    catch { try? FileManager.default.removeItem(at: package); throw error }
}
private actor AutosaveSleeps {
    var waits: [Int: CheckedContinuation<Void, Never>] = [:]
    var next = 0
    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in next += 1; waits[next] = continuation }
    }
    func contains(_ id: Int) -> Bool { waits[id] != nil }
    func release(_ id: Int) { waits.removeValue(forKey: id)?.resume() }
    func releaseAll() { let pending = waits; waits.removeAll(); for continuation in pending.values { continuation.resume() } }
}
@Test func staleSaveRevisionCannotClearNewerDirtyState() throws {
    let package = try autosaveFixture(); defer { try? FileManager.default.removeItem(at: package) }
    let p = try Project.create(package: package)
    #expect(p.isDirty); try p.save(); #expect(!p.isDirty)
    try p.apply(.set(path: "notes", value: .string("first"))); let revision = p.revision
    try p.apply(.set(path: "notes", value: .string("second")))
    #expect(try !p.save(ifRevision: revision) && p.isDirty)
    #expect(try Project.open(package: package).toJSON() == p.toJSON()) // recovery journal includes the newer edit
    #expect(try p.save(ifRevision: p.revision) && !p.isDirty)
    let clean = p.revision
    #expect(try p.apply(.set(path: "notes", value: .string("second"))).changed.isEmpty)
    #expect(p.revision == clean && !p.isDirty)
    try p.undo(); #expect(p.isDirty && p.revision > clean)
    let snapshot = try p.snapshot(); try snapshot.save(); #expect(p.isDirty)
    p.close(); #expect(throws: CoreError.self) { try p.save(ifRevision: p.revision) }
}
@MainActor @Test func autosaverRestartsTrailingTimerAndIgnoresCancelledGenerations() async throws {
    let package = try autosaveFixture(); defer { try? FileManager.default.removeItem(at: package) }
    let p = try Project.create(package: package); try p.save()
    let sleeps = AutosaveSleeps()
    let autosaver = ProjectAutosaver(project: p, delay: .seconds(30), sleep: { await sleeps.sleep($0) })
    defer { autosaver.cancel() }
    #expect(try p.autosavePolicy().delayNs == 30_000_000_000)
    try p.apply(.set(path: "notes", value: .string("first")))
    for _ in 0..<1000 { if await sleeps.contains(1) { break }; await Task.yield() }
    #expect(await sleeps.contains(1))
    try p.apply(.set(path: "notes", value: .string("second")))
    for _ in 0..<1000 { if await sleeps.contains(2) { break }; await Task.yield() }
    #expect(await sleeps.contains(2))
    await sleeps.release(1); await Task.yield(); #expect(p.isDirty)
    await sleeps.release(2)
    for _ in 0..<200 { if !p.isDirty { break }; try await Task.sleep(for: .milliseconds(1)) }
    #expect(!p.isDirty && autosaver.lastError == nil)
    try p.apply(.set(path: "notes", value: .string("cancelled")))
    for _ in 0..<1000 { if await sleeps.contains(3) { break }; await Task.yield() }
    autosaver.cancel(); await sleeps.releaseAll(); await Task.yield(); #expect(p.isDirty)
}

@MainActor @Test func autosaveDisabledAndClosedDocumentsDoNotLoseDirtyState() async throws {
    let package = try autosaveFixture(); defer { try? FileManager.default.removeItem(at: package) }
    let p = try Project.create(package: package); try p.save()
    try p.apply(.set(path: "autosave", value: .bool(false)))
    let sleeps = AutosaveSleeps()
    let autosaver = ProjectAutosaver(project: p, delay: .seconds(30), sleep: { await sleeps.sleep($0) })
    defer { autosaver.cancel() }
    #expect(try !p.autosavePolicy().enabled)
    await Task.yield(); #expect(await !sleeps.contains(1))
    try p.apply(.set(path: "autosave", value: .bool(true)))
    for _ in 0..<1000 { if await sleeps.contains(1) { break }; await Task.yield() }
    #expect(await sleeps.contains(1))
    p.close(); await sleeps.releaseAll()
    for _ in 0..<200 { if autosaver.lastError != nil { break }; try await Task.sleep(for: .milliseconds(1)) }
    #expect(autosaver.lastError?.contains("closed") == true && p.isDirty)
}

@MainActor @Test func manualSaveMakesPendingAutosaveSkipASecondDiskWrite() async throws {
    let package = try autosaveFixture(); defer { try? FileManager.default.removeItem(at: package) }
    let p = try Project.create(package: package); try p.save()
    let sleeps = AutosaveSleeps()
    let autosaver = ProjectAutosaver(project: p, delay: .seconds(30), sleep: { await sleeps.sleep($0) })
    defer { autosaver.cancel() }
    try p.apply(.set(path: "notes", value: .string("manually saved")))
    for _ in 0..<1000 { if await sleeps.contains(1) { break }; await Task.yield() }
    #expect(await sleeps.contains(1))
    try p.save()
    let file = package.appendingPathComponent("project.json")
    let inode = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber).uint64Value
    await sleeps.release(1); await autosaver.waitForScheduledSave()
    let after = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber).uint64Value
    #expect(after == inode)
    #expect(!p.isDirty && autosaver.lastError == nil)
}
