import Foundation

/// At most one main-actor delivery is scheduled at a time. If the UI is busy,
/// replace the pending preview image instead of retaining every camera frame or
/// slowing the writer queue.
final class CameraPreviewRelay: @unchecked Sendable {
    typealias Receive = @MainActor @Sendable (Int64, CameraPreviewUpdate) -> Void

    private let lock = NSLock()
    private let receive: Receive
    private var pending: (generation: Int64, update: CameraPreviewUpdate)?
    private var deliveryScheduled = false

    init(receive: @escaping Receive) { self.receive = receive }

    func submit(_ update: CameraPreviewUpdate, generation: Int64) {
        let shouldSchedule = lock.withLock {
            pending = (generation, update)
            guard !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        if shouldSchedule { scheduleDelivery() }
    }

    private func scheduleDelivery() {
        Task { @MainActor [weak self] in self?.deliverLatest() }
    }

    @MainActor private func deliverLatest() {
        if let pending = lock.withLock({ let pending = pending; self.pending = nil; return pending }) {
            receive(pending.generation, pending.update)
        }
        let shouldReschedule = lock.withLock {
            if pending == nil {
                deliveryScheduled = false
                return false
            }
            return true
        }
        if shouldReschedule { scheduleDelivery() }
    }
}
