import Foundation

/// At most one background fsync. A slow disk must not build an unbounded queue or
/// block the main-actor event tap / realtime sample queue every two seconds.
final class CaptureDiskCheckpoint: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mov.yapcam.capture.checkpoint", qos: .utility)
    private let lock = NSLock()
    private let url: URL
    private let synchronize: @Sendable (URL) throws -> Void
    private var lastRequest: Int64
    private var pending = false
    private var finished = false
    private var failure: CaptureError?

    init(url: URL, originNs: Int64, synchronize: @escaping @Sendable (URL) throws -> Void = { url in
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }) {
        self.url = url; self.lastRequest = originNs; self.synchronize = synchronize
    }

    func request(atHostNs host: Int64) throws {
        try lock.withLock {
            if let failure { throw failure }
            guard !finished, !pending, host >= lastRequest,
                  host - lastRequest >= CaptureMediaPolicy.fragmentDurationNs else { return }
            pending = true; lastRequest = host
            // Enqueue before releasing the state lock so finish cannot overtake
            // an accepted request on another thread.
            queue.async {
                do { try self.synchronize(self.url) }
                catch { self.lock.withLock { self.failure = .writerFailed("Disk checkpoint: \(error.localizedDescription)") } }
                self.lock.withLock { self.pending = false }
            }
        }
    }

    /// Used after a marker's synchronous acknowledgment flush.
    func didSynchronize(atHostNs host: Int64) { lock.withLock { lastRequest = max(lastRequest, host) } }

    /// Waits for prior work and commits the final bytes. Never called on this queue.
    func finish() throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        lock.withLock { finished = true }
        try queue.sync {
            if let failure = lock.withLock({ failure }) { throw failure }
            try synchronize(url)
        }
    }
}
