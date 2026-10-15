import Foundation
import Testing
import YapcamCore

private func migrationFixture(_ name: String, body: (URL, Data) throws -> Void) throws {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    let package = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-migration-\(UUID().uuidString).yapcam")
    try FileManager.default.copyItem(at: fixtures.appendingPathComponent("synthetic/basic.yapcam"), to: package)
    defer { try? FileManager.default.removeItem(at: package) }
    let frozen = try Data(contentsOf: fixtures.appendingPathComponent("schema/\(name).json"))
    try frozen.write(to: package.appendingPathComponent("project.json"))
    try body(package, frozen)
}
@Test func frozenV0AndV1PackagesOpenSaveAndReopenThroughTheABI() throws {
    for name in ["v0-prerelease", "v1-minimal"] {
        try migrationFixture(name) { package, frozen in
            let project = try Project.open(package: package)
            let before = try project.toJSON()
            let snapshot = try project.snapshot()
            #expect(project.durationNs == 5_000_000_000)
            #expect(try project.frame(atNs: 4_000_000_000).screen.segment == 1)
            let fields = try project.query("{\"q\":\"project\"}", as: [String: JSONValue].self)
            #expect(fields["schema_version"]?.integerValue == 1)
            #expect(try !project.speechEnhancementPlan().enabled)
            #expect(try Data(contentsOf: package.appendingPathComponent("project.json")) == frozen)
            try project.apply(.set(path: "notes", value: .string("migrated café 🎥")))
            #expect(try snapshot.toJSON() == before)
            try project.undo()
            #expect(try project.frame(atNs: 4_000_000_000).screen.src_ns == snapshot.frame(atNs: 4_000_000_000).screen.src_ns)
            try project.save()
            let reopened = try Project.open(package: package)
            #expect(try reopened.toJSON() == project.toJSON())
            #expect(reopened.durationNs == 5_000_000_000)
        }
    }
}
@Test func frozenMediaFingerprintIsAnExplicitRelinkFailure() throws {
    try migrationFixture("v1-populated") { package, frozen in
        do { _ = try Project.open(package: package); Issue.record("Frozen mismatched fingerprint silently accepted") }
        catch CoreError.missingMedia(let paths) { #expect(paths == ["recording/seg-000/screen.mov"]) }
        #expect(try Data(contentsOf: package.appendingPathComponent("project.json")) == frozen)
    }
}
@Test func futurePrimaryCannotFallBackToFrozenOlderBackup() throws {
    try migrationFixture("v1-minimal") { package, frozen in
        try frozen.write(to: package.appendingPathComponent("project.json.prev"))
        let future = Data("{\"schema_version\":4294967295}".utf8)
        try future.write(to: package.appendingPathComponent("project.json"))
        do { _ = try Project.open(package: package); Issue.record("Future primary downgraded to old backup") }
        catch CoreError.unsupportedVersion(let version) { #expect(version == 4_294_967_295) }
        #expect(try Data(contentsOf: package.appendingPathComponent("project.json")) == future)
        #expect(try Data(contentsOf: package.appendingPathComponent("project.json.prev")) == frozen)
    }
}
