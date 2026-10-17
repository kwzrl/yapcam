import Foundation
import ObjectiveC

/// What the chat column needs from whoever connects an agent (the MCP server, the chat runner). Filled by the
/// integrator; the chat column only reads it. One instance per editor model.
@MainActor public final class AgentHooks: ObservableObject {
    /// Sends a prompt typed in the chat. Nil: no agent can take prompts yet; the chat shows "Connect an agent".
    @Published public var promptHandler: ((String) -> Void)?
    /// The command a user runs to connect their own agent (e.g. `claude mcp add yapcam …`); copied by the empty state.
    @Published public var connectCommand: (() -> String)?
    /// Current undo depth of the project; lets "Undo" on an entry check its `undoMarker` is still the latest step.
    public var promptRunning = false
    /// What the running chat prompt is doing ("Reading moments…"); nil shows "Working…".
    @Published public var workingLine: String?
    /// Starts a new conversation; nil while there is none to reset (the header hides its button).
    @Published public var newChat: (() -> Void)?
    public var undoDepth: (() -> Int)?

    public init() {}

    private static var key: UInt8 = 0
    /// The hooks of `model`, created on first use and released with the model.
    static func of(_ model: EditorModel) -> AgentHooks {
        if let h = objc_getAssociatedObject(model, &key) as? AgentHooks { return h }
        let h = AgentHooks()
        objc_setAssociatedObject(model, &key, h, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return h
    }
}

extension EditorModel {
    /// This document's agent hooks (see `AgentHooks`).
    public var agentHooks: AgentHooks { AgentHooks.of(self) }
    /// Sends a prompt from the chat input to the connected agent; nil shows the "Connect an agent" state.
    public var agentPromptHandler: ((String) -> Void)? {
        get { agentHooks.promptHandler }
        set { agentHooks.promptHandler = newValue }
    }
    /// The connect command the chat's empty state copies.
    public var agentConnectCommand: (() -> String)? {
        get { agentHooks.connectCommand }
        set { agentHooks.connectCommand = newValue }
    }

    /// The entry whose changes are the most recent undo step: the last agent entry with changes that is still open,
    /// and nothing was edited after it (checked through its `undoMarker` when the undo depth is known).
    public func latestUndoableAgentEntry() -> AgentEntry? {
        guard canUndo, let last = agentLog.entries.last(where: { $0.role == .agent && !$0.changes.isEmpty }),
              last.decision == .open else { return nil }
        if let marker = last.undoMarker, let depth = agentHooks.undoDepth?() { return marker == depth ? last : nil }
        return last
    }

    /// Reverts an agent entry's changes with the editor's undo (one step), when it is the latest step.
    public func undoAgentEntry(_ id: UUID) {
        guard latestUndoableAgentEntry()?.id == id else { return }
        undo()
        agentLog.update(id) { $0.decision = .undone }
    }

    public func keepAgentEntry(_ id: UUID) { agentLog.update(id) { $0.decision = .kept } }
}
