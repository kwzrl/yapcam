import Foundation
import Testing
import AppKit
@testable import YapcamEditor

@MainActor @Suite(.serialized) struct AgentMCPTests {
    @Test func liveDocumentBatchUsesEditorHistoryAndRefreshesCaches() throws {
        _ = NSApplication.shared
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-editor-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: source, to: package)
        defer { try? FileManager.default.removeItem(at: package) }
        let document = try EditorDocument(package: package)
        defer { document.model.close() }
        func call(_ name: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]
            let response = try document.handleMCP(JSONSerialization.data(withJSONObject: request))
            let rpc = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
            return try #require(rpc["result"] as? [String: Any])
        }
        let before = try document.project.toJSON()
        let revision = document.model.revision
        let duration = document.model.durationNs
        let batch: [[String: Any]] = [
            ["op": "delete_range", "tl_start_ns": 1_000_000_000, "tl_end_ns": 1_500_000_000],
            ["op": "add_zoom", "tl_start_ns": 0, "tl_end_ns": 500_000_000, "mode": "manual", "target": [0.5, 0.5], "scale": 2]
        ]
        #expect(try call("batch", ["commands": batch])["isError"] as? Bool == false)
        #expect(document.model.revision == revision + 1)
        #expect(document.model.durationNs == duration - 500_000_000)
        #expect(document.model.project.zooms.count == 1)
        let summary = try call("project_summary")["structuredContent"] as? [String: Any]
        #expect(summary?["undo_steps"] as? Int == 1)
        document.model.undo()
        #expect(try document.project.toJSON() == before)
        #expect(document.model.project.zooms.isEmpty)
        document.model.redo()
        #expect(document.model.project.zooms.count == 1)
        #expect(try call("undo")["isError"] as? Bool == false)
        #expect(document.model.durationNs == duration)
        #expect(document.model.project.zooms.isEmpty)
        let failedRevision = document.model.revision
        #expect(try call("batch", ["commands": [batch[0], ["op": "invalid"]]])["isError"] as? Bool == true)
        #expect(document.model.revision == failedRevision)
        #expect(try document.project.toJSON() == before)
    }

    /// Intention tools mutate through the core directly; the editor (and the vision hint cache keyed by revision)
    /// must still see a new revision, or the timeline doesn't redraw and stale hints break `check` (eval round 3).
    @Test func intentionToolBumpsRevisionAndReachesTheEditor() throws {
        _ = NSApplication.shared
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-intent-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: source, to: package)
        defer { try? FileManager.default.removeItem(at: package) }
        let document = try EditorDocument(package: package)
        defer { document.model.close() }
        func call(_ name: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]
            let response = try document.handleMCP(JSONSerialization.data(withJSONObject: request))
            let rpc = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
            return try #require(rpc["result"] as? [String: Any])
        }
        let revision = document.model.revision
        let zoom = try call("zoom_on_click", ["click_index": 0])
        #expect(zoom["isError"] as? Bool == false)
        #expect(document.model.revision == revision + 1)
        #expect(document.model.project.zooms.count == 1)
        #expect(try call("check")["isError"] as? Bool == false)
        let unchanged = document.model.revision
        _ = try call("moments")
        #expect(document.model.revision == unchanged)
    }
}
