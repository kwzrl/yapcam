import Foundation
import Testing
import AppKit
@testable import YapcamEditor

@MainActor @Suite(.serialized) struct AgentIntegrationTests {
    @Test func documentHooksFollowLiveHistory() throws {
        _ = NSApplication.shared
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/synthetic/basic.yapcam")
        let package = FileManager.default.temporaryDirectory.appending(path: "agent-hooks-\(UUID()).yapcam")
        try FileManager.default.copyItem(at: fixture, to: package)
        defer { try? FileManager.default.removeItem(at: package) }
        let doc = try EditorDocument(package: package)
        defer { doc.model.close() }
        #expect(doc.model.agentConnectCommand?() == AgentConnection.shared.claudeCommand)
        #expect(doc.model.agentPromptHandler != nil)
        #expect(doc.model.agentHooks.undoDepth?() == 0)
        _ = try doc.project.mcp(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"batch","arguments":{"commands":[{"op":"delete_range","tl_start_ns":0,"tl_end_ns":1000000000}]}}}"#.utf8))
        #expect(doc.model.agentHooks.undoDepth?() == 1)
    }

    @Test func processStreamsAndRemovesPrivateConfig() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "fake-claude-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appending(path: "claude")
        try Data("#!/bin/sh\nstat -f '%Lp' mcp.json\npwd\nprintf '%s\\n' '{\"type\":\"result\",\"result\":\"done\"}'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        #expect(AgentPromptRunner.executable(environment: ["PATH": dir.path]) == script)
        let lines = Lines()
        let status = try await ClaudeProcess().run(executable: script, prompt: "test", system: "test", config: Data("{}".utf8)) { data in await lines.append(data) }
        let values = await lines.values
        #expect(status == 0)
        #expect(values.first == "600")
        #expect(values.last?.contains("done") == true)
        #expect(!FileManager.default.fileExists(atPath: values[1]))
    }

    @Test func cancellationStopsRunningProcess() async throws {
        let script = FileManager.default.temporaryDirectory.appending(path: "cancel-claude-\(UUID())")
        try Data("#!/bin/sh\nprintf 'ready\\n'\nexec /bin/sleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }
        let worker = ClaudeProcess()
        let status = try await worker.run(executable: script, prompt: "", system: "", config: Data("{}".utf8)) { _ in worker.cancel() }
        #expect(status != 0)
    }

    @Test func cancellationBeforeLaunchPreventsExecution() async throws {
        let worker = ClaudeProcess(); worker.cancel()
        do {
            _ = try await worker.run(executable: URL(fileURLWithPath: "/usr/bin/true"), prompt: "", system: "", config: Data("{}".utf8)) { _ in }
            Issue.record("Cancelled process launched")
        } catch is CancellationError { }
    }
}

private actor Lines {
    var values: [String] = []
    func append(_ data: Data) { values.append(String(decoding: data, as: UTF8.self)) }
}
