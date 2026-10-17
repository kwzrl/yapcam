import Foundation

/// Runs `body` on the main actor: inline when already on the main thread, hopped there otherwise.
/// `MainActor.assumeIsolated` traps when a Combine sink or notification fires on another thread; this never does.
func onMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread { MainActor.assumeIsolated(body) } else { DispatchQueue.main.async { MainActor.assumeIsolated(body) } }
}

/// Synchronous variant for calls that need a result; blocks the caller only when it is not already on the main thread.
func onMainSync<T: Sendable>(_ body: @MainActor () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try MainActor.assumeIsolated(body) }
    return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
}
