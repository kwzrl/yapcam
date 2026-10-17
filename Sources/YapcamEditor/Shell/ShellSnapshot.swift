import AppKit
import SwiftUI

/// Renders the docked editor to `<dir>/editor-shell-<state>-<width>.png` (agent off, blocks only, agent on with a
/// connected agent, agent on without one, transcript below) at 1280×800 and 1728×1080. With `package` the states use a COPY of that
/// recording (the original is never touched) and its rendered frame; without, a fake project.
/// Layout check only: offscreen renders have no live blur. Called by the UI snapshot and the shell tests.
@MainActor public enum EditorShellSnapshot {
    public static let sizes = [CGSize(width: 1280, height: 800), CGSize(width: 1728, height: 1080)]

    public static func render(into dir: URL, package: URL? = nil) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let states: [(String, (EditorModel) -> Void)] = [
            ("agent-off", { _ in }),
            ("blocks-only", { $0.blocksBarVisible = true }),
            ("agent-on", { sampleChat($0); $0.agentPromptHandler = { _ in } }),
            ("agent-unconnected", { sampleChat($0) }),
            ("transcript", { $0.bottomPanel = .transcript }),
        ]
        for size in sizes {
            for (name, setup) in states {
                let (model, preview, keep) = try await make(package: package)
                try await shot(model: model, preview: preview, size: size, setup: setup,
                               to: dir.appending(path: "editor-shell-\(name)-\(Int(size.width)).png"))
                withExtendedLifetime(keep) {}
            }
        }
    }

    /// A model with clips and zooms, its preview, and whatever must stay alive while it renders.
    private static func make(package: URL?) async throws -> (EditorModel, AnyView, Any?) {
        guard let package else {
            let m = EditorModel(project: FakeProject(durationNs: 134_000_000_000), player: FakePlayer())
            m.geometry = TimelineGeometry(pixelsPerSecond: 8)
            m.seek(toNs: 12_600_000_000); m.splitAtPlayhead()
            m.seek(toNs: 40_000_000_000); m.addZoomAtPlayhead()
            m.seek(toNs: 70_000_000_000); m.addZoomAtPlayhead()
            m.seek(toNs: 20_400_000_000); m.selection = .none
            let gradient = LinearGradient(colors: [Color(red: 0.28, green: 0.46, blue: 0.9), Color(red: 0.56, green: 0.33, blue: 0.91)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)
            return (m, AnyView(gradient), nil)
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("shell-snap-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: package, to: work)
        try? FileManager.default.removeItem(at: work.appendingPathComponent("recording/.capture.lock"))
        let doc = try EditorDocument(package: work)
        let m = doc.model
        m.seek(toNs: min(m.durationNs / 3, 20_000_000_000)); m.selection = .none
        let png = (try? FrameSnapshot.png(source: ProjectRenderSource(doc.project), atNs: m.playheadNs)) ?? Data()
        let frame = AnyView(Image(nsImage: NSImage(data: png) ?? NSImage()).resizable())
        return (m, frame, Cleanup(doc: doc, url: work))
    }

    private final class Cleanup {
        let doc: EditorDocument; let url: URL
        init(doc: EditorDocument, url: URL) { self.doc = doc; self.url = url }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    /// A short history: a prompt, a kept turn, and an open one (Keep / Undo).
    static func sampleChat(_ m: EditorModel) {
        let t = m.durationNs
        m.agentLog.connection = "Claude Code"
        m.agentLog.append(AgentEntry(role: .user, source: "Chat", text: "Tighten this"))
        m.agentLog.append(AgentEntry(role: .agent, source: "Claude Code via MCP", text: "Removed the pauses and zoomed on the deploy click.",
                                     changes: [AgentChange(label: "Removed 2 pauses", timeNs: t / 10, symbol: "scissors"),
                                               AgentChange(label: "Zoom on Deploy click", timeNs: t * 3 / 10, symbol: "plus.magnifyingglass")],
                                     decision: .kept))
        m.agentLog.append(AgentEntry(role: .agent, source: "Claude Code via MCP", text: "",
                                     changes: [AgentChange(label: "Zoom on terminal output", timeNs: t / 2, symbol: "plus.magnifyingglass")]))
        m.agentEnabled = true
    }

    private static func shot(model: EditorModel, preview: AnyView, size: CGSize, setup: (EditorModel) -> Void, to url: URL) async throws {
        let view = EditorContent(model: model, export: ExportModel(engine: FakeExporter()), title: "Deploy walkthrough") { preview }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(size)
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(300))
        setup(model)
        try await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
