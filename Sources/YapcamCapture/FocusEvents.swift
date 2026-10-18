import AppKit

struct FocusApplication: Equatable, Sendable {
    var pid: pid_t
    var bundleID: String?
    var name: String?

    @MainActor static func frontmost() -> Self? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return Self(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName)
    }
}

struct FocusWindowSnapshot: Sendable {
    var app: FocusApplication
    var windowID: UInt32?
    var windowTitle: String?
    var windowRect: CGRect?

    func hasSameFocus(as other: Self) -> Bool {
        // Moving/resizing a window is not navigation. Keep its latest bounds in
        // the next actual focus event without flooding the journal on drags.
        app == other.app && windowID == other.windowID && windowTitle == other.windowTitle
    }
}

enum FocusWindowInfo {
    static func read(app: FocusApplication) -> FocusWindowSnapshot? {
        autoreleasepool {
            guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]] else { return nil }
            return select(app: app, windows: windows)
        }
    }

    /// WindowServer lists windows front to back. Without Accessibility, the
    /// frontmost app's first visible normal-layer window is our best focus proxy.
    /// Window titles can be absent without screen-recording permission; neither
    /// this lookup nor the app lookup requests a permission prompt.
    static func select(app: FocusApplication, windows: [[String: Any]]) -> FocusWindowSnapshot {
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue != false,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0,
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
                  rect.width > 0, rect.height > 0 else { continue }
            return FocusWindowSnapshot(app: app, windowID: id,
                windowTitle: window[kCGWindowName as String] as? String, windowRect: rect)
        }
        // Still report an app switch when it has no visible normal window.
        return FocusWindowSnapshot(app: app)
    }
}

/// One background lookup at a time, with no queue of missed ticks. Stop never
/// waits for WindowServer; generation checks discard late results. Only the last
/// snapshot is retained, and all journal delivery stays on the recorder's actor.
@MainActor final class FocusEventPoller {
    typealias Provider = @Sendable (FocusApplication) -> FocusWindowSnapshot?
    private let provider: Provider
    private let application: @MainActor () -> FocusApplication?
    private let clock: @Sendable () -> Int64
    private let receive: @MainActor (FocusWindowSnapshot, Int64) -> Void
    private var timer: Timer?
    private var generation: UInt64 = 0
    private var running = false
    private(set) var inFlight = false
    private var previous: FocusWindowSnapshot?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(provider: @escaping Provider = FocusWindowInfo.read,
         application: @escaping @MainActor () -> FocusApplication? = FocusApplication.frontmost,
         clock: @escaping @Sendable () -> Int64 = { CaptureClock.now },
         receive: @escaping @MainActor (FocusWindowSnapshot, Int64) -> Void) {
        self.provider = provider; self.application = application
        self.clock = clock; self.receive = receive
    }

    func start(periodic: Bool = true) {
        guard !running else { return }
        running = true
        generation &+= 1
        previous = nil
        poll()
        guard periodic else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func poll() {
        guard running, !inFlight, let app = application() else { return }
        inFlight = true
        let generation = generation, hostNs = clock(), provider = provider
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) { provider(app) }.value
            guard let self else { return }
            defer { self.finishLookup() }
            guard self.running, self.generation == generation, self.application() == app,
                  let snapshot else { return }
            if let previous = self.previous, snapshot.hasSameFocus(as: previous) { return }
            self.previous = snapshot
            self.receive(snapshot, hostNs)
        }
    }

    /// Deterministic completion boundary for tests and controlled callers. This
    /// observes the whole lookup, including stale-result rejection and delivery.
    func waitUntilIdle() async {
        guard inFlight else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func finishLookup() {
        inFlight = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func stop() {
        running = false
        generation &+= 1
        timer?.invalidate(); timer = nil
        previous = nil
    }
}
