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
}
