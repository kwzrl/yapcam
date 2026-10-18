import AppKit
import Testing
@testable import YapcamCapture

private let focusApp = FocusApplication(pid: 123, bundleID: "test.browser", name: "Browser")
private let focusRect = CGRect(x: -80, y: 70, width: 400, height: 300)

@MainActor private final class FocusApplicationFixture {
    var value: FocusApplication
    init(_ value: FocusApplication) { self.value = value }
}

private func window(_ id: UInt32, pid: Int32 = 123, title: String? = "Page", layer: Int = 0,
                    alpha: Double = 1, onScreen: Bool = true, rect: CGRect = focusRect) -> [String: Any] {
    var info: [String: Any] = [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
        kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
        kCGWindowIsOnscreen as String: onScreen, kCGWindowBounds as String: rect.dictionaryRepresentation]
    if let title { info[kCGWindowName as String] = title }
    return info
}

/// Protects only injected test state; the real provider retains no window list.
private final class FocusProviderFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [[String: Any]] = [window(10)]
    private var available = true
    private var calls = 0
    private let gate: DispatchSemaphore?
    private var callWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    init(blocked: Bool = false) { gate = blocked ? DispatchSemaphore(value: 0) : nil }
    func set(_ windows: [[String: Any]], available: Bool = true) {
        lock.withLock { self.windows = windows; self.available = available }
    }
    var callCount: Int { lock.withLock { calls } }
    func waitForCallCount(_ target: Int) async {
        await withCheckedContinuation { continuation in
            let reached = lock.withLock {
                guard calls < target else { return true }
                callWaiters.append((target, continuation))
                return false
            }
            if reached { continuation.resume() }
        }
    }
    func release() { gate?.signal() }
    func read(_ app: FocusApplication) -> FocusWindowSnapshot? {
        #expect(!Thread.isMainThread)
        let ready = lock.withLock {
            calls += 1
            let ready = callWaiters.filter { $0.target <= calls }.map(\.continuation)
            callWaiters.removeAll { $0.target <= calls }
            return ready
        }
        ready.forEach { $0.resume() }
        gate?.wait()
        return lock.withLock { available ? FocusWindowInfo.select(app: app, windows: windows) : nil }
    }
}

@Suite struct FocusEventsTests {
    @Test func selectsFrontmostNormalWindowOfActiveApp() {
        let snapshot = FocusWindowInfo.select(app: focusApp, windows: [
            window(1, pid: 999), window(2, layer: 25), window(3, alpha: 0),
            window(4, onScreen: false), window(5, rect: .zero), window(6), window(7)
        ])
        #expect(snapshot.app == focusApp)
        #expect(snapshot.windowID == 6)
        #expect(snapshot.windowTitle == "Page")
        #expect(snapshot.windowRect == focusRect)
    }

    @Test func missingTitleAndMissingWindowRemainUseful() {
        let redacted = FocusWindowInfo.select(app: focusApp, windows: [window(10, title: nil)])
        #expect(redacted.windowTitle == nil)
        #expect(redacted.windowID == 10)
        #expect(redacted.windowRect == focusRect)
        let noWindow = FocusWindowInfo.select(app: focusApp, windows: [window(1, pid: 999)])
        #expect(noWindow.app == focusApp)
        #expect(noWindow.windowID == nil)
        #expect(noWindow.windowRect == nil)
    }

    @Test @MainActor func emitsInitialAppWindowAndTitleChangesOnly() async throws {
        let fixture = FocusProviderFixture()
        let app = FocusApplicationFixture(focusApp)
        var seen: [FocusWindowSnapshot] = []
        var times: [Int64] = []
        let poller = FocusEventPoller(provider: fixture.read, application: { app.value }, clock: { 1234 }) {
            seen.append($0); times.append($1)
        }
        defer { poller.stop() }
        poller.start(periodic: false)
        await poller.waitUntilIdle()
        #expect(seen.count == 1)
        poller.poll()
        await poller.waitUntilIdle()
        #expect(seen.count == 1)
        fixture.set([window(10, rect: CGRect(x: 0, y: 0, width: 800, height: 600))])
        poller.poll()
        await poller.waitUntilIdle()
        #expect(seen.count == 1)
        fixture.set([window(10, title: "Next page — Browser")])
        poller.poll()
        await poller.waitUntilIdle()
        fixture.set([window(11, title: "Next page — Browser")])
        poller.poll()
        await poller.waitUntilIdle()
        app.value = FocusApplication(pid: 456, bundleID: "test.editor", name: "Editor")
        fixture.set([window(20, pid: 456, title: "Document")])
        poller.poll()
        await poller.waitUntilIdle()
        #expect(seen.map(\.windowID) == [10, 10, 11, 20])
        #expect(seen.last?.app == app.value)
        #expect(times == [1234, 1234, 1234, 1234])
    }

    @Test @MainActor func failedLookupDoesNotInventFocusChange() async throws {
        let fixture = FocusProviderFixture()
        var count = 0
        let poller = FocusEventPoller(provider: fixture.read, application: { focusApp }) { _, _ in count += 1 }
        defer { poller.stop() }
        poller.start(periodic: false)
        await poller.waitUntilIdle()
        fixture.set([], available: false)
        poller.poll()
        await poller.waitUntilIdle()
        fixture.set([window(10)])
        poller.poll()
        await poller.waitUntilIdle()
        #expect(count == 1)
    }

    @Test @MainActor func lookupIsBoundedAndStopDiscardsLateResult() async throws {
        let fixture = FocusProviderFixture(blocked: true)
        var count = 0
        let poller = FocusEventPoller(provider: fixture.read, application: { focusApp }) { _, _ in count += 1 }
        defer { fixture.release(); poller.stop() }
        poller.start(periodic: false)
        await fixture.waitForCallCount(1)
        for _ in 0..<1000 { poller.poll() }
        #expect(fixture.callCount == 1)
        poller.stop() // Must return even while the provider is blocked.
        fixture.release()
        await poller.waitUntilIdle()
        #expect(count == 0)
        poller.poll()
        #expect(fixture.callCount == 1)
        // A new segment must get an initial observation even with unchanged focus.
        fixture.release()
        poller.start(periodic: false)
        await poller.waitUntilIdle()
        #expect(count == 1)
    }

    @Test @MainActor func appSwitchDuringLookupDiscardsStaleSnapshot() async throws {
        let fixture = FocusProviderFixture(blocked: true)
        let app = FocusApplicationFixture(focusApp)
        var count = 0
        let poller = FocusEventPoller(provider: fixture.read, application: { app.value }) { _, _ in count += 1 }
        defer { fixture.release(); poller.stop() }
        poller.start(periodic: false)
        await fixture.waitForCallCount(1)
        app.value.pid = 999
        fixture.release()
        await poller.waitUntilIdle()
        #expect(count == 0)
    }

    @Test @MainActor func focusJournalUsesMonotonicSegmentTimeAndMappedBounds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("focus-events-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = InputEventRecorder(directory: directory,
            rect: CGRect(x: -100, y: 50, width: 800, height: 600), hostStartNs: 100, keys: false)
        try recorder.openEventLog()
        let snapshot = FocusWindowInfo.select(app: focusApp, windows: [window(10, title: "Hello \"世界\"\nTab")])
        recorder.recordFocus(snapshot, hostNs: 90)
        recorder.record(InputEventSnapshot(type: .leftMouseDown, hostNs: 130))
        recorder.recordFocus(snapshot, hostNs: 110)
        recorder.updateContentRect(CGRect(x: -100, y: 50, width: 800, height: 600),
            destination: CGRect(x: 10, y: 20, width: 400, height: 300))
        recorder.recordFocus(snapshot, hostNs: 150)
        try recorder.stop()
        recorder.recordFocus(snapshot, hostNs: 200)
        let lines = try Data(contentsOf: directory.appendingPathComponent("events.jsonl")).split(separator: 0x0a)
        let events = try lines.map { try JSONDecoder().decode(CaptureEvent.self, from: Data($0)) }
        #expect(events.map(\.type) == ["focus", "down", "focus", "focus"])
        #expect(events.map(\.t) == [0, 30, 30, 50])
        #expect(events[0].windowRect == [20, 20, 400, 300])
        #expect(events[3].windowRect == [20, 30, 200, 150])
        let json = try #require(JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any])
        #expect(json["app_bundle_id"] as? String == "test.browser")
        #expect(json["app_name"] as? String == "Browser")
        #expect(json["window_title"] as? String == "Hello \"世界\"\nTab")
        #expect(json["window_id"] as? Int == 10)
        #expect(json["key"] == nil)
    }
}
