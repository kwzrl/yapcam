import Foundation
import Testing
import YapcamCore

@Test func toolbarMarkerSidecarMapsSourceTimeThroughPausesEditsAndReopen() throws {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let package = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-core-marker-sidecar-\(UUID().uuidString).yapcam")
    defer { try? FileManager.default.removeItem(at: package) }
    try FileManager.default.copyItem(at: fixtures.appendingPathComponent("Fixtures/synthetic/basic.yapcam"), to: package)
    let sidecar = package.appendingPathComponent("recording/markers.json")
    // This is the exact toolbar writer schema; source time already excludes pauses.
    let bytes = Data("{\"markers_ns\":[3000000000,0,1000000000,3000000000,5000000000]}".utf8)
    try bytes.write(to: sidecar)
    let project = try Project.create(package: package)
    let original = try project.markers()
    #expect(original.map(\.srcNs) == [0,1_000_000_000,3_000_000_000])
    #expect(original.map(\.markerID) == ["ui-marker:1","ui-marker:2","ui-marker:0"])
    #expect(original[2].segment == 1 && original[2].segmentNs == 0)
    try project.apply(.split(atNs: 1_000_000_000))
    let clip = try project.query("{\"q\":\"clips\"}", as: [ClipInfo].self)[1]
    try project.apply(.setSpeed(clipID: clip.id, speed: 2))
    let edited = try project.markers()
    #expect(edited.map(\.tlNs) == [0,1_000_000_000,2_000_000_000])
    let snapshot = try project.snapshot()
    try project.apply(.deleteRange(startNs: 900_000_000, endNs: 1_100_000_000))
    #expect(try project.markers().count == 2)
    try project.undo(); #expect(try project.markers() == edited)
    try project.save()
    #expect(try Project.open(package: package).markers() == edited)
    #expect(try Data(contentsOf: sidecar) == bytes)
    try Data("{\"markers_ns\":[]}".utf8).write(to: sidecar)
    #expect(try snapshot.markers() == edited)
    #expect(try Project.open(package: package).markers().isEmpty)
}
