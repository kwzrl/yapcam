import Foundation
import Testing
@testable import YapcamCapture

private func recoveryFixture() throws -> (root: URL, package: URL, manifest: SessionManifest) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-recovery-\(UUID())")
    let package = root.appendingPathComponent("Test.yapcam")
    try FileManager.default.createDirectory(at: package.appendingPathComponent("recording"), withIntermediateDirectories: true)
    let value = SessionManifest(source: SourceMetadata(kind: "display", displayID: 2,
        contentRectPoints: [0, 0, 64, 64], scale: 1), tracks: TrackMetadata(screen: ScreenMetadata(pixelSize: [64, 64], maxFPS: 30)))
    return (root, package, value)
}

@Test func recoveryPreservesFinalizedDurationBeforeInterruptedTail() throws {
    let fixture = try recoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var value = fixture.manifest
    value.segments = [
        SegmentMetadata(index: 0, dir: "seg-000", srcStartNs: 0, durationNs: 1_000, hostStartNs: 10_000,
            trackStartNs: ["screen": 10, "system_audio": 20]),
        SegmentMetadata(index: 1, dir: "seg-001", srcStartNs: 1_000, hostStartNs: 20_000, trackStartNs: ["screen": 0])
    ]
    try PackageIO.write(value, to: fixture.package.appendingPathComponent("recording/session.json"))
    for segment in value.segments {
        try FileManager.default.createDirectory(at: fixture.package.appendingPathComponent("recording/\(segment.dir)"), withIntermediateDirectories: true)
    }
    _ = try Recovery.recover(fixture.package) { url, _ in
        switch (url.deletingLastPathComponent().lastPathComponent, url.lastPathComponent) {
        case ("seg-000", "screen.mov"): return 890
        case ("seg-000", "system.m4a"): return 1_030 // audio packet extends past the finalized stop
        case ("seg-001", "screen.mov"): return 500
        default: throw CaptureError.sourceUnavailable
        }
    }
    let recovered = try PackageIO.readManifest(at: fixture.package.appendingPathComponent("recording/session.json"))
    #expect(recovered.segments.map(\.durationNs) == [1_000, 500])
    #expect(recovered.segments.map(\.srcStartNs) == [0, 1_000])
    #expect(try SegmentTimeline.nextSourceStart(after: recovered.segments) == 1_500)
}

@Test func recoveryFallsBackToPreviousTrackStartsAfterCorruptSidecar() throws {
    let fixture = try recoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var value = fixture.manifest
    value.segments = [SegmentMetadata(index: 0, dir: "seg-000", srcStartNs: 0, hostStartNs: 10_000)]
    let segment = fixture.package.appendingPathComponent("recording/seg-000")
    try FileManager.default.createDirectory(at: segment, withIntermediateDirectories: true)
    try PackageIO.write(value, to: fixture.package.appendingPathComponent("recording/session.json"))
    try PackageIO.write(["screen": Int64(50)], to: segment.appendingPathComponent("track-starts.json.prev"))
    try Data("{broken".utf8).write(to: segment.appendingPathComponent("track-starts.json"))
    _ = try Recovery.recover(fixture.package) { url, _ in
        guard url.lastPathComponent == "screen.mov" else { throw CaptureError.sourceUnavailable }
        return 100
    }
    let recovered = try PackageIO.readManifest(at: fixture.package.appendingPathComponent("recording/session.json"))
    #expect(recovered.segments[0].trackStartNs == ["screen": 50])
    #expect(recovered.segments[0].durationNs == 150)
}

@Test(arguments: [0, 1, 2]) func recoveryRenumbersSegmentsAfterUnreadableScreen(missing: Int) throws {
    let fixture = try recoveryFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    var value = fixture.manifest
    for index in 0..<3 {
        let segment = SegmentMetadata(index: index, dir: String(format: "seg-%03d", index),
            srcStartNs: Int64(index) * 777, hostStartNs: Int64(index + 1) * 10_000, trackStartNs: ["screen": 0])
        value.segments.append(segment)
        try FileManager.default.createDirectory(at: fixture.package.appendingPathComponent("recording/\(segment.dir)"),
                                               withIntermediateDirectories: true)
    }
    try PackageIO.write(value, to: fixture.package.appendingPathComponent("recording/session.json"))
    _ = try Recovery.recover(fixture.package) { url, _ in
        let directory = url.deletingLastPathComponent().lastPathComponent
        guard url.lastPathComponent == "screen.mov", directory != value.segments[missing].dir else {
            throw CaptureError.sourceUnavailable
        }
        let index = try #require(value.segments.firstIndex { $0.dir == directory })
        return Int64(index + 1) * 100
    }
    let recovered = try PackageIO.readManifest(at: fixture.package.appendingPathComponent("recording/session.json"))
    let survivors = value.segments.filter { $0.index != missing }
    #expect(recovered.status == "complete")
    #expect(recovered.segments.map(\.index) == [0, 1])
    #expect(recovered.segments.map(\.dir) == survivors.map(\.dir))
    #expect(recovered.segments.map(\.srcStartNs) == [0, Int64(survivors[0].index + 1) * 100])
    #expect(recovered.segments.map { $0.files["screen"] } == survivors.map { "\($0.dir)/screen.mov" })
    #expect(try RecordingSession.recover(fixture.package) == fixture.package)
}

@Test func recoveryUsesDurableScreenOriginBeforeManifestOrOffsetSidecarCatchesUp() throws {
    let fixture = try recoveryFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
    var value = fixture.manifest
    value.segments = [SegmentMetadata(index: 0, dir: "seg-000", srcStartNs: 0, hostStartNs: 10_000)]
    let directory = fixture.package.appendingPathComponent("recording/seg-000")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try PackageIO.write(value, to: fixture.package.appendingPathComponent("recording/session.json"))
    try PackageIO.write(Int64(750_010_000), to: directory.appendingPathComponent("host-start.json"))
    _ = try Recovery.recover(fixture.package) { url, _ in
        guard url.lastPathComponent == "screen.mov" else { throw CaptureError.sourceUnavailable }
        return 100
    }
    let recovered = try PackageIO.readManifest(at: fixture.package.appendingPathComponent("recording/session.json"))
    #expect(recovered.segments[0].hostStartNs == 750_010_000)
    #expect(recovered.segments[0].trackStartNs == ["screen": 0])
    #expect(recovered.segments[0].durationNs == 100)
}

@Test func recoveryRejectsSegmentSymlinkOutsidePackage() throws {
    let fixture = try recoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let external = fixture.root.appendingPathComponent("external")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    let original = Data("external data must remain unchanged".utf8)
    try original.write(to: external.appendingPathComponent("events.jsonl"))
    try FileManager.default.createSymbolicLink(at: fixture.package.appendingPathComponent("recording/seg-000"), withDestinationURL: external)
    var value = fixture.manifest
    value.segments = [SegmentMetadata(index: 0, dir: "seg-000", srcStartNs: 0, hostStartNs: 10_000)]
    try PackageIO.write(value, to: fixture.package.appendingPathComponent("recording/session.json"))
    #expect(throws: CaptureError.self) { try RecordingSession.recover(fixture.package) }
    #expect(try Data(contentsOf: external.appendingPathComponent("events.jsonl")) == original)
}

@Test func streamedEventRepairHandlesOversizedLinesAndPreservesPreviousFile() throws {
    let fixture = try recoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let url = fixture.package.appendingPathComponent("recording/events.jsonl")
    var data = Data("{\"t\":0,\"type\":\"move\",\"x\":1,\"y\":2}\n".utf8)
    data.append(Data(repeating: 0x78, count: 1_048_577))
    data.append(Data("\n{\"t\":20,\"type\":\"move\",\"x\":3,\"y\":4}".utf8))
    try data.write(to: url)
    try Recovery.repairEvents(at: url, duration: 100)
    let lines = try Data(contentsOf: url).split(separator: 0x0a)
    let events = try lines.map { try JSONDecoder().decode(CaptureEvent.self, from: Data($0)) }
    #expect(events.map(\.t) == [0, 20])
    #expect(try Data(contentsOf: url.appendingPathExtension("prev")) == data)
}

@Test func failedStreamingWriteKeepsOriginalAndRemovesTemporaryFile() throws {
    let fixture = try recoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let url = fixture.package.appendingPathComponent("recording/session.json")
    let original = Data("old manifest".utf8)
    try original.write(to: url)
    #expect(throws: CaptureError.self) {
        try PackageIO.writeStreaming(to: url) { output in
            try output.write(contentsOf: Data("partial replacement".utf8))
            throw CaptureError.writerFailed("Simulated I/O failure")
        }
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["session.json"])
}

@Test func livePackageIsExcludedFromRecoveryUntilLockIsReleased() throws {
    let fixture = try recoveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try PackageIO.write(fixture.manifest, to: fixture.package.appendingPathComponent("recording/session.json"))
    var lease: RecordingPackageLease? = try RecordingPackageLease(package: fixture.package)
    #expect(!RecordingPackageLease.isAvailable(fixture.package))
    #expect(RecordingSession.interruptedPackages(in: fixture.root).isEmpty)
    #expect(throws: CaptureError.self) { try RecordingSession.recover(fixture.package) }
    withExtendedLifetime(lease) {}
    lease = nil
    #expect(RecordingPackageLease.isAvailable(fixture.package))
    #expect(RecordingSession.interruptedPackages(in: fixture.root).map { $0.resolvingSymlinksInPath().path }
            == [fixture.package.resolvingSymlinksInPath().path])
}
