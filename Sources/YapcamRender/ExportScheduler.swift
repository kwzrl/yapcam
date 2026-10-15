import Foundation

public enum ExportPhase: Sendable, Equatable {
    case waiting, preparing, rendering, completed, cancelled
    case failed(String)
}

/// A process-wide FIFO permit; queued jobs allocate no decoder/GPU/writer state.
/// Cancellation removes a waiting continuation and never releases the active job.
actor ExportScheduler {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void,Error>
    }
    private var active = false
    private var waiters: [Waiter] = []
    var waitingCount: Int { waiters.count }

    func run<T: Sendable>(waiting: @Sendable () -> Void,
                          operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire(waiting: waiting)
        defer { release() }
        // If cancellation races a grant, this owner still returns its permit.
        try Task.checkCancellation()
        return try await operation()
    }
    private func acquire(waiting: @Sendable () -> Void) async throws {
        try Task.checkCancellation()
        if !active { active = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else {
                    waiters.append(Waiter(id: id,continuation: continuation))
                    waiting()
                }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { active = false }
        else { waiters.removeFirst().continuation.resume() }
    }
}
