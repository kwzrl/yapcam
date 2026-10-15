import Foundation

public struct CoreAutosavePolicy: Decodable, Sendable, Equatable {
    public var enabled: Bool
    public var delayNs: Int64
}
extension Project {
    public func autosavePolicy() throws -> CoreAutosavePolicy {
        try query("{\"q\":\"autosave_policy\"}", as: CoreAutosavePolicy.self)
    }
}

private final class AutosaveObservation: @unchecked Sendable {
    var token: NSObjectProtocol?
    func cancel() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
    deinit { cancel() }
}

/// Own one per document and cancel before Project.close(). Recovery journaling
/// is separate. This coordinator saves the full project after a quiet period.
@MainActor public final class ProjectAutosaver {
    public private(set) var lastError: String?
    private let project: Project
    private let delay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let observation = AutosaveObservation()
    private var pending: Task<Void, Never>?
    private var active = true

    public convenience init(project: Project, delay: Duration = .seconds(30)) {
        self.init(project: project, delay: delay, sleep: { try await Task.sleep(for: $0) })
    }
    // Deterministic virtual sleeps in Core tests avoid wall-clock race assertions.
    init(project: Project, delay: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.project = project; self.delay = delay; self.sleep = sleep
        observation.token = NotificationCenter.default.addObserver(forName: Project.didChange, object: nil, queue: nil) { [weak self, weak project] event in
            guard let project, let changed = event.object as? Project, changed === project else { return }
            Task { @MainActor [weak self] in self?.schedule() }
        }
        schedule()
    }
    deinit { pending?.cancel() }

    public func cancel() {
        active = false
        pending?.cancel(); pending = nil
        observation.cancel()
    }
    // Allows deterministic clock tests to join the scheduled save after waking it.
    func waitForScheduledSave() async { await pending?.value }
    private func schedule() {
        pending?.cancel(); pending = nil
        guard active, project.isDirty else { return }
        do { guard try project.autosavePolicy().enabled else { return } }
        catch { lastError = error.localizedDescription; return }
        let expected = project.revision, delay = self.delay, sleep = self.sleep
        pending = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, self.active, self.project.isDirty else { return }
            do {
                let project = self.project
                let saved = try await Task.detached(priority: .utility) { try project.save(ifRevision: expected) }.value
                guard !Task.isCancelled, self.active else { return }
                self.lastError = nil
                if !saved || project.isDirty { self.schedule() }
            } catch {
                guard !Task.isCancelled, self.active else { return }
                self.lastError = error.localizedDescription
            }
        }
    }
}
