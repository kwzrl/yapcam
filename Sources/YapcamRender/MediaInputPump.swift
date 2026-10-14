import Foundation

/// Pull-source work runs on a dedicated serial queue, never a Swift cooperative worker.
/// AVAssetWriter drives requests independently for each track. Samples stay on this queue.
final class MediaInputPump<Sample>: @unchecked Sendable {
    typealias Request = @Sendable (DispatchQueue,@escaping @Sendable () -> Void) -> Void
    private let queue=DispatchQueue(label: "mov.yapcam.export.audio",qos: .userInitiated)
    private let monitor=DispatchQueue(label: "mov.yapcam.export.audio.watchdog")
    private let lock=NSLock()
    private let request: Request
    private let ready: @Sendable () -> Bool
    private let read: @Sendable () throws -> Sample?
    private let append: @Sendable (Sample) throws -> Void
    private let end: @Sendable () throws -> Void
    private let stop: @Sendable () -> Void
    private let cancelSource: @Sendable () -> Void
    private let timeout: Double
    private var continuation: CheckedContinuation<Void,Error>?
    private var terminal: Result<Void,Error>?
    private var cancelled=false
    private var requestedFailure: Error?
    private var started=false
    private var lastProgress=ProcessInfo.processInfo.systemUptime
    private var timer: DispatchSourceTimer?
    init(timeout: Double = 30,request: @escaping Request,ready: @escaping @Sendable () -> Bool,read: @escaping @Sendable () throws -> Sample?,append: @escaping @Sendable (Sample) throws -> Void,end: @escaping @Sendable () throws -> Void,stop: @escaping @Sendable () -> Void,cancelSource: @escaping @Sendable () -> Void) {
        self.timeout=timeout; self.request=request; self.ready=ready; self.read=read
        self.append=append; self.end=end; self.stop=stop; self.cancelSource=cancelSource
    }
    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (value: CheckedContinuation<Void,Error>) in
                let immediate: Result<Void,Error>?=lock.withLock {
                    if started { return .failure(RenderError.write("Audio pump is already running")) }
                    started=true
                    if let terminal { return terminal }
                    continuation=value; return nil
                }
                if let immediate { value.resume(with: immediate); return }
                queue.async { [self] in
                    guard !lock.withLock({ cancelled }) else { complete(.failure(CancellationError())); return }
                    let timer=DispatchSource.makeTimerSource(queue: monitor)
                    self.timer=timer
                    timer.schedule(deadline: .now()+timeout,repeating: .milliseconds(100))
                    timer.setEventHandler { [weak self] in
                        guard let self else { return }
                        let stalled=self.lock.withLock { self.terminal==nil && ProcessInfo.processInfo.systemUptime-self.lastProgress>=self.timeout }
                        if stalled { self.fail(RenderError.write("Timed out waiting for audio source or encoder")) }
                    }
                    timer.resume()
                    request(queue) { [weak self] in self?.drain() }
                }
            }
        } onCancel: { cancel() }
    }
    func cancel() { fail(CancellationError()) }
    private func fail(_ error: Error) {
        let active=lock.withLock { if terminal != nil || cancelled { return false }; cancelled=true; requestedFailure=error; return true }
        guard active else { return }
        // Unblock any native read; completion is queued after the reader returns.
        cancelSource()
        queue.async { [self] in complete(.failure(error)) }
    }
    private func drain() {
        do {
            while ready() {
                if lock.withLock({ cancelled }) { throw CancellationError() }
                if lock.withLock({ terminal != nil }) { return }
                let finished=try autoreleasepool { () throws -> Bool in
                    guard let sample=try read() else { try end(); return true }
                    if lock.withLock({ cancelled }) { throw CancellationError() }
                    try append(sample); return false
                }
                lock.withLock { lastProgress=ProcessInfo.processInfo.systemUptime }
                if finished { complete(.success(())); return }
            }
        } catch { complete(.failure(error)) }
    }
    private func complete(_ result: Result<Void,Error>) {
        let outcome: (Bool,CheckedContinuation<Void,Error>?,Result<Void,Error>)=lock.withLock {
            if terminal != nil { return (false,nil,result) }
            let result=requestedFailure.map { Result<Void,Error>.failure($0) } ?? result
            terminal=result; let value=continuation; continuation=nil; return (true,value,result)
        }
        guard outcome.0 else { return }
        stop(); timer?.cancel(); timer=nil
        outcome.1?.resume(with: outcome.2)
    }
}
