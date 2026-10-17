import CryptoKit
import Foundation
import YapcamCore

/// One local Claude process per editor. No shell interpolation, and no token in chat text.
/// The conversation continues across prompts of the same document (`--resume`) until "New chat" or the window closes.
@MainActor final class AgentPromptRunner {
    private weak var model: EditorModel?
    private let package: URL
    private var job: ClaudeProcess?
    /// Claude Code session of this document's conversation; the next prompt resumes it.
    private(set) var sessionID: String?
    /// The strongest model alias Claude Code 2.1 accepts.
    nonisolated static let model = "opus"
    /// This prompt resumes a conversation and nothing was answered yet: a failure retries fresh.
    private var resuming = false
    /// Finds the Claude Code binary; tests substitute a script.
    var locate: () -> URL? = { AgentPromptRunner.executable() }
    init(model: EditorModel, package: URL) { self.model = model; self.package = package }

    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
            + [FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude").path, "/opt/homebrew/bin/claude"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    /// Condensed playbook and craft rules from the core, bound to this document.
    static func systemPrompt(package: URL) -> String {
        let name = package.deletingPathExtension().lastPathComponent
        let template = Project.agentDoc("chat") ?? "You are editing the Yapcam document \"{document}\". Use only the Yapcam MCP tools."
        return template.replacingOccurrences(of: "{document}", with: name)
            + "\nThis chat is bound to that document (\(package.path)); you do not need to pass `project`."
    }

    /// Claude Code keys stored sessions by working directory: one stable directory per document lets `--resume` find them.
    static func workingDirectory(for package: URL) -> URL {
        let digest = SHA256.hash(data: Data(package.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.temporaryDirectory.appending(path: "yapcam-chat-sessions/\(digest)")
    }

    /// `session_id` carried by stream-json events (init, assistant, result).
    nonisolated static func sessionID(in event: [String: Any]) -> String? {
        (event["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A quiet line for the chat while a tool runs: "Reading moments…", "Capturing 4 frames…".
    nonisolated static func workingLine(tool: String, input: [String: Any]) -> String {
        let name = tool.hasPrefix("mcp__") ? String(tool.split(separator: "__").last ?? "") : tool
        func count(_ key: String) -> Int { (input[key] as? [Any])?.count ?? 0 }
        func frames(_ n: Int) -> String { n == 1 ? "1 frame" : "\(n) frames" }
        switch name {
        case "moments": return "Reading moments…"
        case "project_summary", "read_project", "read_events", "list_documents": return "Reading the project…"
        case "read_transcript": return "Reading the transcript…"
        case "capture": return count("times") > 0 ? "Capturing \(frames(count("times")))…" : "Capturing frames…"
        case "grab": return count("times") > 0 ? "Grabbing \(frames(count("times"))) of the source…" : "Grabbing source frames…"
        case "filmstrip": return "Capturing a filmstrip…"
        case "waveform": return "Reading the waveform…"
        case "check": return "Checking the edit…"
        case "trim_start_to_first_word": return "Trimming the start…"
        case "cut_words": return "Cutting words…"
        case "remove_fillers": return "Removing fillers…"
        case "tighten_pauses": return "Tightening pauses…"
        case "zoom_on_click": return "Adding a zoom…"
        case "add_caption": return "Adding a caption…"
        case "apply", "batch": return "Editing…"
        case "undo": return "Undoing…"
        case "redo": return "Redoing…"
        case "transcribe", "transcription_status": return "Transcribing…"
        case "seek", "select": return "Showing it in the editor…"
        case "save": return "Saving…"
        case "ListMcpResourcesTool", "ReadMcpResourceTool": return "Reading the playbook…"
        default: return "Working…"
        }
    }

    func send(_ prompt: String) {
        guard let model, job == nil else { return }
        let log = model.agentLog
        log.append(AgentEntry(role: .user, source: "Chat", text: prompt))
        guard let executable = locate() else {
            log.append(AgentEntry(role: .system, source: "Chat", text: "Claude Code was not found. Install it or use Copy connect command below to connect your own client.")); return
        }
        let config = AgentConnection.shared
        let settings: [String: Any] = ["mcpServers": ["yapcam": ["type": "http", "url": "http://127.0.0.1:\(config.port)/mcp", "headers": ["Authorization": "Bearer \(config.token)", "X-Yapcam-Project": package.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? package.path]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: settings) else { return }
        let worker = ClaudeProcess(); job = worker
        model.agentHooks.promptRunning = true; log.isWorking = true
        model.agentHooks.workingLine = nil
        let entry = AgentEntry(role: .agent, source: "Claude Code", text: "")
        log.append(entry)
        let system = Self.systemPrompt(package: package)
        let directory = Self.workingDirectory(for: package)
        Task.detached { [weak self] in
            do {
                let resume = await self?.beginRun()
                var status = try await worker.run(executable: executable, prompt: prompt, system: system, config: data, resume: resume, model: Self.model, workingDirectory: directory) { [weak self] line in
                    await self?.receive(line, entry: entry.id)
                }
                // A stored conversation can disappear (Claude Code cleanup): start a fresh one instead of failing.
                if status != 0, resume != nil, await self?.resuming == true {
                    await self?.forget(note: "The earlier conversation was not available; started a new one.")
                    status = try await worker.run(executable: executable, prompt: prompt, system: system, config: data, resume: nil, model: Self.model, workingDirectory: directory) { [weak self] line in
                        await self?.receive(line, entry: entry.id)
                    }
                }
                await self?.finish(status == 0 ? nil : "Claude Code exited with status \(status). Check local Claude login, or use Copy connect command below.")
            } catch { await self?.finish("Claude Code could not start: \(error.localizedDescription). Use Copy connect command below.") }
        }
    }

    /// Forgets the conversation: the next prompt starts a new Claude session.
    func newChat() {
        cancel()
        forget(note: "New chat. Claude starts fresh from the next message.")
    }

    private func forget(note: String) {
        guard sessionID != nil else { return }
        sessionID = nil; resuming = false; model?.agentHooks.newChat = nil
        model?.agentLog.append(AgentEntry(role: .system, source: "Chat", text: note))
    }

    func setSessionForTesting(_ id: String) { sessionID = id }

    private func beginRun() -> String? {
        resuming = sessionID != nil
        return sessionID
    }

    private func receive(_ line: Data, entry: UUID) {
        guard job != nil, let model, let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let log = model.agentLog
        let type = event["type"] as? String
        if let id = Self.sessionID(in: event), id != sessionID, type != "result" || event["is_error"] as? Bool != true {
            sessionID = id
            model.agentHooks.newChat = { [weak self] in self?.newChat() }
        }
        if type == "assistant" { resuming = false }
        if type == "assistant", let message = event["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { log.update(entry) { $0.text = text } }
            if let tool = content.last(where: { $0["type"] as? String == "tool_use" }), let name = tool["name"] as? String {
                model.agentHooks.workingLine = Self.workingLine(tool: name, input: tool["input"] as? [String: Any] ?? [:])
            }
        }
        if type == "result" {
            model.agentHooks.workingLine = nil
            if resuming, event["is_error"] as? Bool == true { return } // retried without the stale session
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
        model?.agentHooks.workingLine = nil
        if let error { model?.agentLog.append(AgentEntry(role: .system, source: "Chat", text: error)) }
    }
    func cancel() {
        job?.cancel(); job = nil
        model?.agentHooks.promptRunning = false; model?.agentLog.isWorking = false
        model?.agentHooks.workingLine = nil
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
    /// `resume` continues a stored conversation; `workingDirectory` (default: the private config directory, removed
    /// afterwards) must stay the same across prompts for Claude Code to find it.
    func run(executable: URL, prompt: String, system: String, config: Data, resume: String? = nil, model: String? = nil,
             workingDirectory: URL? = nil, receive: @Sendable (Data) async -> Void) async throws -> Int32 {
        let directory = FileManager.default.temporaryDirectory.appending(path: "yapcam-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "mcp.json")
        try config.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let child = Process(), output = Pipe()
        if let workingDirectory {
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        child.executableURL = executable; child.currentDirectoryURL = workingDirectory ?? directory
        var arguments = ["-p", prompt, "--output-format", "stream-json", "--verbose", "--mcp-config", file.path,
                         "--strict-mcp-config", "--allowedTools", "mcp__yapcam__*,ListMcpResourcesTool,ReadMcpResourceTool",
                         // Only the tools that read MCP resources (yapcam://playbook); no shell, files or web.
                         "--tools", "ListMcpResourcesTool,ReadMcpResourceTool",
                         "--permission-mode", "acceptEdits", "--system-prompt", system]
        if let resume { arguments += ["--resume", resume] }
        if let model { arguments += ["--model", model] }
        child.arguments = arguments
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
