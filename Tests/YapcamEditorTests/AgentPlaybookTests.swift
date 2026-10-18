import Foundation
import Testing
import AppKit
import YapcamCore
@testable import YapcamEditor

@MainActor @Suite(.serialized) struct AgentPlaybookTests {
    @Test func coreShipsTheHandbook() throws {
        #expect(Project.agentDoc("playbook")?.hasPrefix("# Yapcam playbook") == true)
        #expect(Project.agentDoc("yapcam://craft")?.contains("Visual budget 0") == true)
        #expect(Project.agentDoc("examples/changelog") != nil)
        #expect(Project.agentDoc("app_instructions")?.contains("yapcam://playbook") == true)
        #expect(Project.agentDoc("nope") == nil)
        let read = try #require(try Project.agentDocsRPC(Data(#"{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"yapcam://playbook"}}"#.utf8)))
        let object = try #require(try JSONSerialization.jsonObject(with: read) as? [String: Any])
        #expect(object["id"] as? Int == 3)
        #expect(try Project.agentDocsRPC(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)) == nil)
    }

    @Test func systemPromptWorkingLinesAndSessions() {
        let package = URL(fileURLWithPath: "/tmp/Demo Take.yapcam")
        let prompt = AgentPromptRunner.systemPrompt(package: package)
        #expect(prompt.contains("\"Demo Take\"") && prompt.contains("moments") && !prompt.contains("{document}"))
        #expect(AgentPromptRunner.workingDirectory(for: package) == AgentPromptRunner.workingDirectory(for: URL(fileURLWithPath: "/tmp/./Demo Take.yapcam")))
        #expect(AgentPromptRunner.workingDirectory(for: package) != AgentPromptRunner.workingDirectory(for: URL(fileURLWithPath: "/tmp/Other.yapcam")))
        #expect(AgentPromptRunner.workingLine(tool: "mcp__yapcam__moments", input: [:]) == "Reading moments…")
        #expect(AgentPromptRunner.workingLine(tool: "mcp__yapcam__capture", input: ["times": [0, 1.5, 3, 4]]) == "Capturing 4 frames…")
        #expect(AgentPromptRunner.workingLine(tool: "mcp__yapcam__zoom_on_click", input: [:]) == "Adding a zoom…")
        #expect(AgentPromptRunner.workingLine(tool: "mcp__yapcam__unknown", input: [:]) == "Working…")
        #expect(AgentPromptRunner.sessionID(in: ["type": "system", "session_id": "abc"]) == "abc")
        #expect(AgentPromptRunner.sessionID(in: ["type": "system", "session_id": ""]) == nil)
    }

    /// A fake `claude` records its arguments: the second prompt of a document resumes the first one's session,
    /// "New chat" drops it, and a stale session retries fresh.
    @Test func promptsOfOneDocumentShareAConversation() async throws {
        _ = NSApplication.shared
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/synthetic/basic.yapcam")
        let dir = FileManager.default.temporaryDirectory.appending(path: "resume-claude-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir.appending(path: "Demo.yapcam")
        try FileManager.default.copyItem(at: fixture, to: package)
        let argsLog = dir.appending(path: "args.log")
        let script = dir.appending(path: "claude")
        // Each run prints its argv on one line; `--resume stale` fails like a missing session; sessions are s1, s2, …
        try Data("""
        #!/bin/sh
        { printf '%s' "$*" | tr '\\n' ' '; echo; } >> '\(argsLog.path)'
        case "$*" in *"--resume stale"*) printf '%s\\n' '{"type":"result","is_error":true,"errors":["No conversation found"],"session_id":"x"}'; exit 1;; esac
        n=$(wc -l < '\(argsLog.path)' | tr -d ' ')
        printf '%s\\n' "{\\"type\\":\\"system\\",\\"subtype\\":\\"init\\",\\"session_id\\":\\"s$n\\"}"
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__yapcam__moments","input":{}}]}}'
        printf '%s\\n' "{\\"type\\":\\"result\\",\\"result\\":\\"done $n\\",\\"session_id\\":\\"s$n\\"}"

        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let doc = try EditorDocument(package: package)
        defer { doc.model.close() }
        let runner = doc.agentRunner
        runner.locate = { script }
        func runs() throws -> [String] {
            guard let text = try? String(contentsOf: argsLog, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map(String.init)
        }
        // Flaky under load for two reasons: the wait gave up after 5 s (a loaded machine needs longer to fork the fake shell
        // script), and `promptRunning` may still be false right after `send`, so the loop could return before the run began.
        // Now: wait (up to 60 s) until the expected number of fake-claude runs happened AND the prompt finished.
        func send(_ text: String, runs expected: Int = 1) async throws {
            let before = try runs().count
            runner.send(text)
            let deadline = ContinuousClock.now + .seconds(60)
            while ContinuousClock.now < deadline {
                if try runs().count >= before + expected, !doc.model.agentHooks.promptRunning { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(try runs().count >= before + expected && !doc.model.agentHooks.promptRunning)
        }

        try await send("add a zoom on the deploy click")
        #expect(runner.sessionID == "s1")
        #expect(doc.model.agentHooks.newChat != nil)
        try await send("make that zoom shorter")
        var argv = try runs()
        #expect(!argv[0].contains("--resume"))
        #expect(argv[1].contains("--resume s1") && argv[1].contains("--model opus"))
        #expect(!argv[1].contains("--no-session-persistence"))
        #expect(doc.model.agentLog.entries.last?.text == "done 2")

        doc.model.agentHooks.newChat?()
        #expect(runner.sessionID == nil && doc.model.agentHooks.newChat == nil)
        try await send("start over")
        argv = try runs()
        #expect(!argv[2].contains("--resume"))

        runner.setSessionForTesting("stale")
        try await send("again", runs: 2)
        argv = try runs()
        #expect(argv[3].contains("--resume stale") && !argv[4].contains("--resume"))
        #expect(runner.sessionID == "s5")
        #expect(doc.model.agentLog.entries.contains { $0.text.contains("started a new one") })
        #expect(!doc.model.agentLog.entries.contains { $0.text.contains("could not complete") })
        #expect(doc.model.agentHooks.workingLine == nil)
    }
}
