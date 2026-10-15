import Foundation

/// Bounds CPU + GPU work together. Encoding/commit stays FIFO, while a GPU
/// completion returns capacity immediately, without a round trip to the UI.
final class PreviewRenderQueue: @unchecked Sendable {
    static let capacity = 2
    private let worker = DispatchQueue(label: "mov.yapcam.preview.encode", qos: .userInitiated,
                                       autoreleaseFrequency: .workItem)
    private let slots = DispatchSemaphore(value: capacity)

    func reserve() -> Ticket? {
        guard slots.wait(timeout: .now()) == .success else { return nil }
        return Ticket { [slots] in slots.signal() }
    }

    func submit(_ ticket: Ticket, work: @escaping @Sendable (Ticket) -> Void) {
        worker.async { work(ticket) }
    }

    final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var release: (@Sendable () -> Void)?
        init(release: @escaping @Sendable () -> Void) { self.release = release }
        /// Safe for both a failed encode and a command-buffer completion.
        func finish() {
            let action = lock.withLock { let action = release; release = nil; return action }
            action?()
        }
        deinit { finish() }
    }
}
