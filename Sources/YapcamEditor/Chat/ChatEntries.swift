import SwiftUI
import YapcamDesign

/// One history entry: a user prompt as a bubble on the right, an agent turn as "N changes" with one row per change,
/// a system note as a faint line.
struct ChatEntryView: View {
    @ObservedObject var model: EditorModel
    let entry: AgentEntry

    var body: some View {
        switch entry.role {
        case .user: UserBubble(text: entry.text)
        case .system:
            Text(entry.text).font(Yap.Font.caption).foregroundStyle(Yap.faint).padding(.leading, 8)
                .fixedSize(horizontal: false, vertical: true)
        case .agent: AgentTurn(model: model, entry: entry)
        }
    }
}

private struct UserBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text).font(Yap.Font.body).foregroundStyle(Yap.title)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.1)))
        }
    }
}

/// An agent turn: who acted, its reply (first paragraph, "More" for the rest), the changes (a row jumps the playhead
/// to its spot), Keep / Undo.
private struct AgentTurn: View {
    @ObservedObject var model: EditorModel
    let entry: AgentEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.source).font(Yap.Font.caption).foregroundStyle(Yap.faint).padding(.leading, 8)
            if let reply = ChatReply.visibleText(of: entry) { ChatReplyText(text: reply).padding(.horizontal, 8) }
            if !entry.changes.isEmpty { changes; ChatDecision(model: model, entry: entry).padding(.leading, 8).padding(.top, 2) }
        }
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.countTitle(entry.changes.count)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Yap.title)
                .padding(.horizontal, 8).padding(.bottom, 2)
            ForEach(entry.changes) { c in
                let value = c.timeNs.map { formatTimecode($0, showFraction: false) } ?? ""
                ValueRow(symbol: ChatChangeStyle.symbol(for: c), title: ChatChangeStyle.title(c.label, value: value), value: value,
                         help: c.timeNs == nil ? c.label : "\(c.label): show on the timeline") {
                    guard let t = c.timeNs else { return }
                    model.bottomPanel = .timeline
                    model.seek(toNs: min(max(t, 0), model.durationNs))
                }
            }
        }
        .opacity(entry.decision == .undone ? 0.45 : 1)
    }

    static func countTitle(_ n: Int) -> String { n == 1 ? "1 change" : "\(n) changes" }
}

/// What part of an agent reply the chat shows.
enum ChatReply {
    /// The reply, or nil when there is none or it only repeats the change rows (MCP turns log their labels as text).
    static func visibleText(of entry: AgentEntry) -> String? {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != entry.changes.map(\.label).joined(separator: ", ") else { return nil }
        return text
    }

    /// The reply split at its first blank line: the lead paragraph and whatever follows (nil when nothing does).
    static func split(_ text: String) -> (lead: String, rest: String?) {
        let paragraphs = text.components(separatedBy: "\n").split { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.joined(separator: "\n") }
        guard let lead = paragraphs.first else { return (text, nil) }
        let rest = paragraphs.dropFirst().joined(separator: "\n\n")
        return (lead, rest.isEmpty ? nil : rest)
    }
}

/// The reply, collapsed to its first paragraph at most three lines tall; "More" shows all of it.
struct ChatReplyText: View {
    let text: String
    @State private var expanded = false
    @State private var clipped = false
    static let collapsedLines = 3

    var body: some View {
        let parts = ChatReply.split(text)
        VStack(alignment: .leading, spacing: 4) {
            if expanded {
                reply(text)
            } else {
                reply(parts.lead).lineLimit(Self.collapsedLines)
                    .background(alignment: .topLeading) { overflowProbe(parts.lead) }
            }
            if expanded || parts.rest != nil || clipped {
                Button(expanded ? "Less" : "More") { withAnimation(Yap.Motion.select) { expanded.toggle() } }
                    .buttonStyle(.plain).font(Yap.Font.caption).foregroundStyle(Yap.caption)
                    .accessibilityHint(expanded ? "Shows only the first paragraph" : "Shows the whole reply")
            }
        }
    }

    private func reply(_ s: String) -> some View {
        Text(s).font(Yap.Font.body).foregroundStyle(Yap.body)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    /// The lead paragraph laid out without a line limit, invisible: taller than the visible text → it was cut.
    private func overflowProbe(_ s: String) -> some View {
        GeometryReader { box in
            Text(s).font(Yap.Font.body).fixedSize(horizontal: false, vertical: true)
                .frame(width: box.size.width, alignment: .leading).hidden()
                .onGeometryChange(for: Bool.self) { $0.size.height > box.size.height + 1 } action: { clipped = $0 }
        }
        .accessibilityHidden(true)
    }
}

/// How a change row looks: a symbol per kind of edit, and the title without the time the row already shows in yellow.
enum ChatChangeStyle {
    static func symbol(for change: AgentChange) -> String {
        switch change.symbol {
        case "scissors": return "scissors"
        case "plus.magnifyingglass", "minus.magnifyingglass", "magnifyingglass": return change.symbol
        case "text.bubble", "textformat": return "textformat"
        case "sparkles": break
        default: return change.symbol
        }
        let l = change.label.lowercased()
        func starts(_ prefixes: String...) -> Bool { prefixes.contains { l.hasPrefix($0) } }
        if starts("cut", "trim", "split", "removed filler", "tightened") { return "scissors" }
        if starts("zoom", "adjusted zoom", "added automatic zoom") { return "plus.magnifyingglass" }
        if starts("caption", "text", "edited caption", "generated captions") { return "textformat" }
        if starts("background", "padding", "applied visual preset", "adjusted canvas") { return "paintbrush" }
        if starts("clip speed", "sped up") { return "gauge.with.needle" }
        if starts("updated speaker notes") { return "note.text" }
        if l.hasSuffix(": on") || l.hasSuffix(": off") || starts("adjusted") { return "slider.horizontal.3" }
        return "sparkles"
    }

    /// "Zoom 1.8× on click 0:42" with 0:42 in the value column reads "Zoom 1.8× on click".
    static func title(_ label: String, value: String) -> String {
        guard !value.isEmpty, label.hasSuffix(" " + value) else { return label }
        return String(label.dropLast(value.count + 1))
    }
}

/// Keep / Undo for an open entry; afterwards a quiet note. Undo works only on the latest step (the editor's undo).
struct ChatDecision: View {
    @ObservedObject var model: EditorModel
    let entry: AgentEntry

    var body: some View {
        switch entry.decision {
        case .open:
            let undoable = model.latestUndoableAgentEntry()?.id == entry.id
            HStack(spacing: 6) {
                Button("Keep") { model.keepAgentEntry(entry.id) }
                    .buttonStyle(CapsuleButtonStyle(.secondary, height: 26))
                Button("Undo") { model.undoAgentEntry(entry.id) }
                    .buttonStyle(CapsuleButtonStyle(.secondary, height: 26))
                    .disabled(!undoable)
                    .help(undoable ? "Undo these changes (one step)" : "Only the latest change can be undone here. Use Undo in the title bar for older steps.")
            }
        case .kept, .undone:
            Text(entry.decision == .kept ? "Kept" : "Undone").font(Yap.Font.caption).foregroundStyle(Yap.faint)
        }
    }
}
