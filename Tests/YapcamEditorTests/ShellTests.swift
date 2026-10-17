import Testing
import SwiftUI
import AppKit
import YapcamDesign
@testable import YapcamEditor

/// The docked editor shell: blocks bar actions, the chat's Keep/Undo against the editor undo, the agent hooks,
/// the stage fit, and the tones (no warmth, no blue).
@MainActor @Suite struct ShellTests {
    private func model(_ seconds: Int64 = 20) -> EditorModel {
        EditorModel(project: FakeProject(durationNs: seconds * 1_000_000_000), player: FakePlayer())
    }

    @Test func blocksAddAtPlayheadAsOneUndoStepEach() {
        let m = model()
        m.seek(toNs: 4_000_000_000)
        m.addBlock(.title)
        let title = m.textItems(.annotation).last
        #expect(title?.startNs == 4_000_000_000)
        #expect(title?.fontSize == 96 && title?.background[3] == 0)
        #expect(m.selection == .text(.annotation, title!.id))
        m.addBlock(.spotlight)
        #expect(m.highlights.last?.kind == .spotlight)
        m.addBlock(.text)
        #expect(m.textItems(.annotation).count == 2)
        // Each block is exactly one undo step.
        m.undo(); #expect(m.textItems(.annotation).count == 1)
        m.undo(); #expect(m.highlights.isEmpty)
        m.undo(); #expect(m.textItems(.annotation).isEmpty)
        #expect(!m.canUndo)
    }

    @Test func titleNeedsRoom() {
        let m = model()
        m.seek(toNs: m.durationNs)
        #expect(m.addTitleAtPlayhead() == nil)
        #expect(m.lastError != nil)
    }

    @Test func undoOnlyForTheLatestAgentEntry() {
        let m = model()
        m.addZoomAtPlayhead()
        let first = AgentEntry(role: .agent, source: "Claude Code via MCP", text: "", changes: [AgentChange(label: "Zoom", timeNs: 0)])
        m.agentLog.append(first)
        #expect(m.latestUndoableAgentEntry()?.id == first.id)
        m.seek(toNs: 10_000_000_000); m.addZoomAtPlayhead()
        let second = AgentEntry(role: .agent, source: "Claude Code via MCP", text: "", changes: [AgentChange(label: "Zoom 2", timeNs: 10_000_000_000)])
        m.agentLog.append(AgentEntry(role: .user, source: "Chat", text: "More zooms"))
        m.agentLog.append(second)
        #expect(m.latestUndoableAgentEntry()?.id == second.id)
        m.undoAgentEntry(first.id)                     // not the latest: nothing happens
        #expect(m.zooms.count == 2)
        m.undoAgentEntry(second.id)
        #expect(m.zooms.count == 1)
        #expect(m.agentLog.entries.last?.decision == .undone)
        // An undone entry is no longer the latest open one; the older one is not offered either.
        #expect(m.latestUndoableAgentEntry() == nil)
        m.keepAgentEntry(first.id)
        #expect(m.agentLog.entries.first?.decision == .kept)
    }

    @Test func undoMarkerMustMatchTheUndoDepth() {
        let m = model()
        m.addZoomAtPlayhead()
        var depth = 1
        m.agentHooks.undoDepth = { depth }
        m.agentLog.append(AgentEntry(role: .agent, source: "Chat", text: "", changes: [AgentChange(label: "Zoom")], undoMarker: 1))
        #expect(m.latestUndoableAgentEntry() != nil)
        depth = 2                                      // the user edited after the agent
        #expect(m.latestUndoableAgentEntry() == nil)
    }

    @Test func hooksBelongToTheirModel() {
        let a = model(), b = model()
        var sent: [String] = []
        a.agentPromptHandler = { sent.append($0) }
        a.agentConnectCommand = { "claude mcp add yapcam" }
        #expect(b.agentPromptHandler == nil && b.agentConnectCommand == nil)
        a.agentPromptHandler?("Tighten this")
        #expect(sent == ["Tighten this"])
        #expect(a.agentHooks === a.agentHooks)
        #expect(a.agentConnectCommand?() == "claude mcp add yapcam")
    }

    @Test func previewFitsWithAir() {
        let s = EditorContent<EmptyView>.fit(aspect: 16.0 / 9, in: CGSize(width: 1000, height: 400))
        #expect(abs(s.height - (400 - EditorContent<EmptyView>.air)) < 0.01)
        #expect(abs(s.width / s.height - 16.0 / 9) < 0.001)
        let tall = EditorContent<EmptyView>.fit(aspect: 9.0 / 16, in: CGSize(width: 300, height: 2000))
        #expect(abs(tall.width - (300 - 2 * EditorContent<EmptyView>.air)) < 0.01)
        let bad = EditorContent<EmptyView>.fit(aspect: .nan, in: CGSize(width: 800, height: 600))
        #expect(abs(bad.width / bad.height - 16.0 / 9) < 0.001)
    }

    /// Neutral, a breath cool: never warm (red above blue), never blue (blue far above red).
    @Test func tonesAreNeutral() {
        for c in [EditorTheme.stage, EditorTheme.card, Yap.ground, Yap.dock] {
            let n = NSColor(c).usingColorSpace(.sRGB)!
            #expect(n.redComponent <= n.blueComponent)
            #expect(n.blueComponent - n.redComponent < 0.02)
        }
        #expect(EditorTheme.cardRadius == 0)
    }
}

/// Renders the docked editor (agent off / blocks only / agent on / not connected) at 1280×800 and 1728×1080:
/// `YAPCAM_SNAPSHOT_DIR=<dir> [YAPCAM_REAL_PKG=<package>] swift test --filter ShellSnapshotTests` (a real package is copied first).
@MainActor @Suite(.serialized) struct ShellSnapshotTests {
    @Test func renderShellStates() async throws {
        guard let d = ProcessInfo.processInfo.environment["YAPCAM_SNAPSHOT_DIR"] else { return }
        let real = ProcessInfo.processInfo.environment["YAPCAM_REAL_PKG"].map { URL(fileURLWithPath: $0) }
        try await EditorShellSnapshot.render(into: URL(fileURLWithPath: d), package: real)
    }
}
