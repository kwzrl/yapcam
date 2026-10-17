import AppKit
import Foundation
import Testing
@testable import YapcamCapture

@Test func cursorShapeIdentityNeverClassifiesUnregisteredObjects() throws {
    let objects = CapturedCursorShape.allCases.map { _ in NSObject() }
    let standards = zip(objects, CapturedCursorShape.allCases).map { (ObjectIdentifier($0.0), $0.1) }
    for (identity, shape) in standards {
        #expect(CapturedCursorShape.identify(identity, standards: standards) == shape)
    }
    let unknown = NSObject()
    #expect(CapturedCursorShape.identify(ObjectIdentifier(unknown), standards: standards) == nil)
    #expect(CapturedCursorShape.identify(nil, standards: standards) == nil)
    withExtendedLifetime(objects) {}
}

@Test func cursorMetadataReadsLegacyAndOmitsUnknownShape() throws {
    let legacy = Data(#"{"file":"cursors/0.png","hotspot":[2,3],"size_points":[16,24]}"#.utf8)
    let cursor = try JSONDecoder().decode(CursorMetadata.self, from: legacy)
    #expect(cursor.shape == nil)
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cursor)) as? [String: Any])
    #expect(object["shape"] == nil)
}

@Test @MainActor func standardAndIdenticalCustomArtHaveSeparateSidecarIDs() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-cursor-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
        bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    let recorder = InputEventRecorder(directory: directory, rect: CGRect(x: 0, y: 0, width: 800, height: 600),
        hostStartNs: 100, keys: false)
    let arrow = CursorSnapshot(png: png, hotspot: CGPoint(x: 1, y: 2), sizePoints: CGSize(width: 16, height: 16), shape: .arrow)
    let unknown = CursorSnapshot(png: png, hotspot: arrow.hotspot, sizePoints: arrow.sizePoints, shape: nil)
    try recorder.openEventLog()
    recorder.recordCursor(arrow, hostNs: 101)
    recorder.recordCursor(unknown, hostNs: 102)
    recorder.recordCursor(arrow, hostNs: 103)
    recorder.recordCursor(unknown, hostNs: 104)
    try recorder.stop()
    let sidecar = try JSONDecoder().decode([String: CursorMetadata].self, from: Data(contentsOf: directory.appendingPathComponent("cursors.json")))
    #expect(sidecar.count == 2)
    #expect(sidecar["0"]?.shape == "arrow")
    #expect(sidecar["1"]?.shape == nil)
    #expect(sidecar["0"]?.hotspot == sidecar["1"]?.hotspot)
    #expect(sidecar["0"]?.sizePoints == sidecar["1"]?.sizePoints)
    let events = try String(contentsOf: directory.appendingPathComponent("events.jsonl"), encoding: .utf8)
        .split(separator: "\n").map { try JSONDecoder().decode(CaptureEvent.self, from: Data($0.utf8)) }
    #expect(events.map(\.id) == [0, 1, 0, 1])
    #expect(events.map(\.t) == [1, 2, 3, 4])
    #expect(try Data(contentsOf: directory.appendingPathComponent("cursors/0.png")) == Data(contentsOf: directory.appendingPathComponent("cursors/1.png")))
}
