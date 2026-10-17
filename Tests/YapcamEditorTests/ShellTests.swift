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

/// Renders the docked editor (agent off / on / narrow floating chat / blocks only) at 1280×800 and 1728×1080:
/// `YAPCAM_SNAPSHOT_DIR=<dir> swift test --filter ShellSnapshotTests`.
@MainActor @Suite(.serialized) struct ShellSnapshotTests {
    static func populated() -> EditorModel {
        let m = EditorModel(project: FakeProject(durationNs: 134_000_000_000), player: FakePlayer())
        m.geometry = TimelineGeometry(pixelsPerSecond: 8)
        m.seek(toNs: 12_600_000_000); m.splitAtPlayhead()
        m.seek(toNs: 40_000_000_000); m.addZoomAtPlayhead()
        m.seek(toNs: 70_000_000_000); m.addZoomAtPlayhead()
        m.seek(toNs: 20_400_000_000)
        return m
    }

    static func withChat(_ m: EditorModel, handler: Bool) {
        m.agentLog.connection = "Claude Code"
        m.agentLog.append(AgentEntry(role: .user, source: "Chat", text: "Tighten this"))
        m.agentLog.append(AgentEntry(role: .agent, source: "Claude Code via MCP", text: "Removed the pauses and zoomed on the deploy click.",
                                     changes: [AgentChange(label: "Removed 2 pauses", timeNs: 12_600_000_000, symbol: "scissors"),
                                               AgentChange(label: "Zoom on Deploy click", timeNs: 40_000_000_000, symbol: "plus.magnifyingglass")],
                                     decision: .kept))
        m.agentLog.append(AgentEntry(role: .agent, source: "Claude Code via MCP", text: "",
                                     changes: [AgentChange(label: "Zoom on terminal output", timeNs: 70_000_000_000, symbol: "plus.magnifyingglass")]))
        if handler { m.agentPromptHandler = { _ in } }
        m.agentEnabled = true
    }

    private func render(_ name: String, _ m: EditorModel, size: CGSize, dir: URL, setup: (EditorModel) -> Void = { _ in }) async throws {
        _ = NSApplication.shared
        let view = EditorContent(model: m, export: ExportModel(engine: FakeExporter()), title: "Deploy walkthrough") {
            LinearGradient(colors: [Color(red: 0.28, green: 0.46, blue: 0.9), Color(red: 0.56, green: 0.33, blue: 0.91)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.setContentSize(size)
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(300))
        setup(m)
        try await Task.sleep(for: .milliseconds(700)); host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appending(path: "shell-\(name)-\(Int(size.width)).png"))
        window.orderOut(nil)
    }

    @Test func renderShellStates() async throws {
        guard let d = ProcessInfo.processInfo.environment["YAPCAM_SNAPSHOT_DIR"] else { return }
        let dir = URL(fileURLWithPath: d)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for size in [CGSize(width: 1280, height: 800), CGSize(width: 1728, height: 1080)] {
            try await render("agent-off", Self.populated(), size: size, dir: dir)
            try await render("blocks-only", Self.populated(), size: size, dir: dir) { $0.blocksBarVisible = true }
            try await render("agent-on", Self.populated(), size: size, dir: dir) { Self.withChat($0, handler: true) }
            try await render("agent-unconnected", Self.populated(), size: size, dir: dir) { Self.withChat($0, handler: false) }
        }
    }
}
