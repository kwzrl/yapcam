import Foundation

/// Shared contract for the agentic editor (fleet 2026-10-17-agentic, night build).
/// The MCP server and the chat runner write entries; the chat column shows them. Nothing here talks to an agent.

/// What the bottom panel shows: the timeline or the transcript of the same edit.
public enum BottomPanel: String, Sendable { case timeline, transcript }

/// One step an agent took, shown as a row in the chat ("Zoom on Deploy click  0:40").
public struct AgentChange: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var label: String
    /// Timeline position the row jumps to, if the change has one.
    public var timeNs: Int64?
    /// SF Symbol for the row.
    public var symbol: String
    public init(id: UUID = UUID(), label: String, timeNs: Int64? = nil, symbol: String = "sparkles") {
        self.id = id; self.label = label; self.timeNs = timeNs; self.symbol = symbol
    }
}

/// One chat entry: a prompt from the user, or an agent turn that changed the project.
public struct AgentEntry: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable { case user, agent, system }
    public enum Decision: String, Sendable { case open, kept, undone }
    public let id: UUID
    public var role: Role
    /// Who acted: "Claude Code via MCP", "Chat", …
    public var source: String
    public var text: String
    public var changes: [AgentChange]
    /// Undo depth right after this entry's batch was applied; lets "Undo" revert exactly this step when it is the latest.
    public var undoMarker: Int?
    public var decision: Decision
    public var date: Date
    public init(id: UUID = UUID(), role: Role, source: String, text: String, changes: [AgentChange] = [],
                undoMarker: Int? = nil, decision: Decision = .open, date: Date = Date()) {
        self.id = id; self.role = role; self.source = source; self.text = text; self.changes = changes
        self.undoMarker = undoMarker; self.decision = decision; self.date = date
    }
}

/// The chat history of one editor document. Main-actor only; views observe it.
@MainActor public final class AgentActivityLog: ObservableObject {
    @Published public private(set) var entries: [AgentEntry] = []
    /// True while an agent turn is running (spinner in the chat).
    @Published public var isWorking = false
    /// Bumps when something new arrived while the chat was collapsed (toolbar toggle brightens).
    @Published public var unread = 0
    /// Connection state shown in the chat header ("Claude Code", "Not connected").
    @Published public var connection: String?

    public init() {}

    public func append(_ entry: AgentEntry) { entries.append(entry); unread += 1 }
    public func update(_ id: UUID, _ change: (inout AgentEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
    }
    public func markRead() { unread = 0 }
    public func clear() { entries.removeAll(); unread = 0 }
}
