import Foundation

/// One local Claude process per editor. No shell interpolation, and no token in chat text.
@MainActor final class AgentPromptRunner {
    private weak var model: EditorModel?
    private let package: URL
    private var job: ClaudeProcess?
    init(model: EditorModel, package: URL) { self.model = model; self.package = package }

    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
            + [FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude").path, "/opt/homebrew/bin/claude"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    func send(_ prompt: String) {
        guard let model, job == nil else { return }
        let log = model.agentLog
        log.append(AgentEntry(role: .user, source: "Chat", text: prompt))
        guard let executable = Self.executable() else {
            log.append(AgentEntry(role: .system, source: "Chat", text: "Claude Code was not found. Install it or use Copy connect command below to connect your own client.")); return
        }
        let config = AgentConnection.shared
        let settings: [String: Any] = ["mcpServers": ["yapcam": ["type": "http", "url": "http://127.0.0.1:\(config.port)/mcp", "headers": ["Authorization": "Bearer \(config.token)", "X-Yapcam-Project": package.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? package.path]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: settings) else { return }
        let worker = ClaudeProcess(); job = worker
        model.agentHooks.promptRunning = true; log.isWorking = true
        let entry = AgentEntry(role: .agent, source: "Claude Code", text: "")
        log.append(entry)
        let system = "You edit only the Yapcam document at \(package.path). Read the tool descriptions and project before editing. Use the project path explicitly. Apply all requested edits in one batch tool call so they are one undo step. Use only Yapcam MCP tools. Explain the result briefly."
        Task.detached { [weak self] in
            do {
                let status = try await worker.run(executable: executable, prompt: prompt, system: system, config: data) { [weak self] line in
                    await self?.receive(line, entry: entry.id)
                }
                await self?.finish(status == 0 ? nil : "Claude Code exited with status \(status). Check local Claude login, or use Copy connect command below.")
            } catch { await self?.finish("Claude Code could not start: \(error.localizedDescription). Use Copy connect command below.") }
        }
    }

    private func receive(_ line: Data, entry: UUID) {
        guard job != nil, let log = model?.agentLog,
              let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let type = event["type"] as? String
        if type == "assistant", let message = event["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { log.update(entry) { $0.text = text } }
        }
        if type == "result" {
            let text = event["result"] as? String ?? (event["errors"] as? [String])?.joined(separator: "\n") ?? "Claude finished without a text response."
            log.update(entry) { $0.text = text }
            if event["is_error"] as? Bool == true {
                log.append(AgentEntry(role: .system, source: "Chat", text: "Claude could not complete the request. Check Claude login in Terminal. You can also use Copy connect command below."))
            }
        }
    }
    private func finish(_ error: String?) {
        guard job != nil else { return }
        job = nil; model?.agentHooks.promptRunning = false; model?.agentLog.isWorking = false
        if let error { model?.agentLog.append(AgentEntry(role: .system, source: "Chat", text: error)) }
    }
    func cancel() {
        job?.cancel(); job = nil
        model?.agentHooks.promptRunning = false; model?.agentLog.isWorking = false
    }
}

/// Blocking pipe reads run on a detached task. The lock closes the launch/cancel race.
final class ClaudeProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
    private func launch(_ child: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try child.run(); process = child
    }
    func run(executable: URL, prompt: String, system: String, config: Data,
             receive: @Sendable (Data) async -> Void) async throws -> Int32 {
        let directory = FileManager.default.temporaryDirectory.appending(path: "yapcam-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "mcp.json")
        try config.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let child = Process(), output = Pipe()
        child.executableURL = executable; child.currentDirectoryURL = directory
        child.arguments = ["-p", prompt, "--output-format", "stream-json", "--verbose", "--mcp-config", file.path,
                           "--strict-mcp-config", "--allowedTools", "mcp__yapcam__*", "--tools", "",
                           "--permission-mode", "acceptEdits", "--no-session-persistence", "--system-prompt", system]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output; child.standardError = output
        try launch(child)
        var pending = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                await receive(line)
            }
            if pending.count > 4_000_000 { pending.removeAll() }
        }
        if !pending.isEmpty { await receive(pending) }
        child.waitUntilExit()
        return child.terminationStatus
    }
}
