import AppKit
import Foundation
import Testing
import YapcamEditor
@testable import YapcamUI

/// Live, opt-in: real Claude Code through the chat runner and the in-app MCP server, on a COPY of a recording.
/// `YAPCAM_LIVE_CHAT=/tmp/copy.yapcam [YAPCAM_LIVE_PORT=7791] swift test --filter AgentLiveChatTests`
/// The port and token live in the volatile argument domain, so nothing is written to preferences.
@MainActor @Suite(.serialized) struct AgentLiveChatTests {
    nonisolated static let package = ProcessInfo.processInfo.environment["YAPCAM_LIVE_CHAT"]

    @Test(.enabled(if: package != nil), .timeLimit(.minutes(15)))
    func secondPromptRefersToTheFirst() async throws {
        _ = NSApplication.shared
        let package = URL(fileURLWithPath: try #require(Self.package))
        let port = Int(ProcessInfo.processInfo.environment["YAPCAM_LIVE_PORT"] ?? "") ?? 7791
        UserDefaults.standard.setVolatileDomain(["agent.mcp.port": port, "agent.mcp.token": UUID().uuidString + UUID().uuidString], forName: UserDefaults.argumentDomain)
        AgentServer.startServer()
        EditorWindows.open(package: package)
        defer { EditorWindows.close(package: package) }
        let doc = try #require(EditorWindows.openDocuments.first { $0.project.packageURL.standardizedFileURL == package.standardizedFileURL })
        for _ in 0..<100 where !AgentConnection.shared.running { try await Task.sleep(for: .milliseconds(50)) }
        #expect(AgentConnection.shared.running)
        let model = doc.model

        func ask(_ prompt: String) async throws {
            let start = model.agentLog.entries.count
            let handler = try #require(model.agentPromptHandler)
            handler(prompt)
            var lines: [String] = []
            for _ in 0..<3000 where model.agentHooks.promptRunning {
                if let line = model.agentHooks.workingLine, lines.last != line { lines.append(line) }
                try await Task.sleep(for: .milliseconds(100))
            }
            print("LIVE working lines: \(lines)")
            for e in model.agentLog.entries[start...] { print("LIVE [\(e.role)] \(e.source): \(e.text)" + (e.changes.isEmpty ? "" : " {\(e.changes.map(\.label).joined(separator: ", "))}")) }
        }
        func manual() -> [TimelineZoom] { model.project.zooms.filter { $0.mode == .manual } }

        let before = manual()
        try await ask("Add one manual zoom at 2x on the first click in the recording. Nothing else.")
        let added = manual().filter { z in !before.contains { $0.id == z.id } }
        #expect(added.count == 1)
        let zoom = try #require(added.first)
        print("LIVE zoom after prompt 1: \(zoom.id) \(Double(zoom.startNs) / 1e9)–\(Double(zoom.endNs) / 1e9) s")
        #expect(model.agentHooks.newChat != nil)

        try await ask("Make that zoom shorter.")
        let after = try #require(model.project.zooms.first { $0.id == zoom.id } ?? manual().first { z in !before.contains { $0.id == z.id } })
        print("LIVE zoom after prompt 2: \(after.id) \(Double(after.startNs) / 1e9)–\(Double(after.endNs) / 1e9) s")
        #expect(after.endNs - after.startNs < zoom.endNs - zoom.startNs)
        #expect(manual().count == before.count + 1)
    }
}
