import AppKit
import CoreMedia
import Foundation
import Testing
@testable import YapcamCapture

@MainActor private func translate(keys: Bool, _ snapshots: [InputEventSnapshot]) throws -> [CaptureEvent] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-events-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = InputEventRecorder(directory: directory,
        rect: CGRect(x: -100, y: 50, width: 800, height: 600), hostStartNs: 100, keys: keys)
    try recorder.openEventLog()
    for snapshot in snapshots { recorder.record(snapshot) }
    try recorder.stop()
    return try Data(contentsOf: directory.appendingPathComponent("events.jsonl")).split(separator: 0x0a)
        .map { try JSONDecoder().decode(CaptureEvent.self, from: Data($0)) }
}

@Test @MainActor func movesDragsAndClicksUseContentCoordinatesIncludingOutsideArea() throws {
    let events = try translate(keys: false, [
        InputEventSnapshot(type: .mouseMoved, hostNs: 100, location: CGPoint(x: -110, y: 40)),
        InputEventSnapshot(type: .leftMouseDragged, hostNs: 110, location: CGPoint(x: 200, y: 250)),
        InputEventSnapshot(type: .leftMouseDown, hostNs: 120, location: CGPoint(x: 200, y: 250)),
        InputEventSnapshot(type: .leftMouseUp, hostNs: 130, location: CGPoint(x: 200, y: 250)),
        InputEventSnapshot(type: .rightMouseDown, hostNs: 140, location: CGPoint(x: 200, y: 250), button: 1),
        InputEventSnapshot(type: .otherMouseUp, hostNs: 150, location: CGPoint(x: 200, y: 250), button: 2)
    ])
    #expect(events.map(\.type) == ["move", "move", "down", "up", "down", "up"])
    #expect(events.map(\.t) == [0, 10, 20, 30, 40, 50])
    #expect(events.map(\.x) == [-10, 300, 300, 300, 300, 300])
    #expect(events.map(\.y) == [-10, 200, 200, 200, 200, 200])
    #expect(events.compactMap(\.button) == ["left", "left", "right", "other"])
}

@Test @MainActor func scrollRetainsSignedPointDeltas() throws {
    let events = try translate(keys: false, [InputEventSnapshot(type: .scrollWheel, hostNs: 110, dx: 1.5, dy: -12.25)])
    #expect(events == [CaptureEvent(t: 10, type: "scroll", dx: 1.5, dy: -12.25)])
}

@Test @MainActor func keystrokesAreAbsentUntilExplicitlyEnabled() throws {
    let key = InputEventSnapshot(type: .keyDown, hostNs: 150, text: "k", keyCode: 40, flags: [.maskCommand, .maskShift])
    #expect(try translate(keys: false, [key]).isEmpty)
    let recorded = try translate(keys: true, [key])
    #expect(recorded == [CaptureEvent(t: 50, type: "key", key: "k", modifiers: ["cmd", "shift"])])
}

@Test @MainActor func nonprintingKeysAndUnicodeKeepTheirIdentity() throws {
    let events = try translate(keys: true, [
        InputEventSnapshot(type: .keyDown, hostNs: 110, keyCode: 36, flags: [.maskControl]),
        InputEventSnapshot(type: .keyDown, hostNs: 120, text: "é", keyCode: 14, flags: [.maskAlternate])
    ])
    #expect(events.map(\.key) == ["keycode:36", "é"])
    #expect(events.map(\.modifiers) == [["ctrl"], ["alt"]])
}

@Test @MainActor func lateAndPrestartEventsStayMonotonicAndInvalidCoordinatesAreIgnored() throws {
    let events = try translate(keys: false, [
        InputEventSnapshot(type: .mouseMoved, hostNs: 90, location: CGPoint(x: 0, y: 50)),
        InputEventSnapshot(type: .leftMouseDown, hostNs: 130, location: CGPoint(x: 0, y: 50)),
        InputEventSnapshot(type: .leftMouseUp, hostNs: 120, location: CGPoint(x: 0, y: 50)),
        InputEventSnapshot(type: .mouseMoved, hostNs: 140, location: CGPoint(x: CGFloat.nan, y: 50)),
        InputEventSnapshot(type: .scrollWheel, hostNs: 150, dx: Double.infinity, dy: 0)
    ])
    #expect(events.map(\.t) == [0, 30, 30])
    #expect(events.map(\.type) == ["move", "down", "up"])
}

@Test @MainActor func inputDeliveryConvertsSampleHostClockUnitsToEventNanoseconds() throws {
    // A 24 MHz host-clock representation deliberately differs from nanoseconds.
    let origin = CaptureClock.inputEventTime(receivedAt: CMTime(value: 36_000_000, timescale: 24_000_000))
    let click = CaptureClock.inputEventTime(receivedAt: CMTime(value: 48_000_000, timescale: 24_000_000))
    #expect(origin == 1_500_000_000)
    #expect(click == 2_000_000_000)
    #expect(CaptureClock.inputEventTime(receivedAt: CMTime(value: 1, timescale: 24_000_000)) == 42)
    // A parked pointer need not emit a move for subsequent clicks to advance time.
    let events = try translate(keys: false, [InputEventSnapshot(type: .leftMouseDown, hostNs: click)])
    #expect(events[0].t == 1_999_999_900)
    let before = CaptureClock.now
    let delivered = CaptureClock.inputEventTime()
    let after = CaptureClock.now
    #expect(delivered >= before && delivered <= after)
}
