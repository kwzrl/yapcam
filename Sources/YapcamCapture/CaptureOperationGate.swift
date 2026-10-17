import Foundation

/// Cleanup must still acquire the session after its caller's Task is cancelled.
/// Continuations avoid cancellable polling sleeps while stream start/stop finishes.
@MainActor final class CaptureOperationGate {
    private(set) var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func setBusy(_ busy: Bool) {
        isBusy = busy
        if !busy {
            let ready = waiters
            waiters.removeAll()
            for waiter in ready { waiter.resume() }
        }
    }

    func waitUntilAvailable() async {
        while isBusy { await withCheckedContinuation { waiters.append($0) } }
    }

    /// Wait for the current operation and claim the gate before another resumed
    /// waiter can begin. Cleanup operations use this when they must not be lost
    /// merely because stream startup or another stop is still in flight.
    func acquire() async {
        while isBusy { await withCheckedContinuation { waiters.append($0) } }
        setBusy(true)
    }
}
