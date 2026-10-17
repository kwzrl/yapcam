#if FOCUS_POLLER_HARNESS
import Foundation
@testable import YapcamCapture

/// Metadata only: no screen capture, input tap, activation, or permission request.
@main private enum FocusPollerHarness {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("focus-harness-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = CaptureClock.now
        let recorder = InputEventRecorder(directory: directory,
            rect: CGRect(x: 0, y: 0, width: 1920, height: 1080), hostStartNs: origin, keys: false)
        try recorder.openEventLog()
        var count = 0
        let poller = FocusEventPoller { snapshot, hostNs in
            recorder.recordFocus(snapshot, hostNs: hostNs)
            count += 1
        }
        poller.start()
        try await Task.sleep(for: .seconds(5))
        poller.stop()
        try recorder.stop()
        let data = try Data(contentsOf: directory.appendingPathComponent("events.jsonl"))
        print(String(decoding: data, as: UTF8.self), terminator: "")
        print("FOCUS_POLLER_DONE seconds=5 events=\(count)")
    }
}
#endif
