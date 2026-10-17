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

/// An agent turn: who acted, its reply, the changes (a row jumps the playhead to its spot), Keep / Undo.
private struct AgentTurn: View {
    @ObservedObject var model: EditorModel
    let entry: AgentEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.source).font(Yap.Font.caption).foregroundStyle(Yap.faint).padding(.leading, 8)
            if !entry.text.isEmpty {
                Text(entry.text).font(Yap.Font.body).foregroundStyle(Yap.body)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.horizontal, 8)
            }
            if !entry.changes.isEmpty { changes; ChatDecision(model: model, entry: entry).padding(.leading, 8).padding(.top, 2) }
        }
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.countTitle(entry.changes.count)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Yap.title)
                .padding(.horizontal, 8).padding(.bottom, 2)
            ForEach(entry.changes) { c in
                ValueRow(symbol: c.symbol, title: c.label, value: c.timeNs.map { formatTimecode($0, showFraction: false) } ?? "",
                         help: c.timeNs == nil ? c.label : "Show on the timeline") {
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
