import AppKit
import SwiftUI
import YapcamDesign

// The chat column (agent on): header, history of `model.agentLog`, spinner, input. Docked on `Yap.dock` at the
// left window edge, or floating on glass over the stage when the window is narrow (lab variant B).

struct ChatColumn: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var log: AgentActivityLog
    @ObservedObject var hooks: AgentHooks
    var floating = false
    static let width: CGFloat = 300

    init(model: EditorModel, floating: Bool = false) {
        self.model = model; log = model.agentLog; hooks = model.agentHooks; self.floating = floating
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            history
            if hooks.promptHandler != nil { ChatInput(send: send).padding(10) } else { ConnectHint(command: hooks.connectCommand) }
        }
        .frame(maxHeight: .infinity)
        .background { if floating { GlassSurface(radius: Yap.Grid.barRadius, behindWindow: false, lift: 0.04) } else { Yap.dock } }
        .clipShape(RoundedRectangle(cornerRadius: floating ? Yap.Grid.barRadius : 0, style: .continuous))
        .onAppear { log.markRead() }
        .onChange(of: log.unread) { _, n in if n > 0 { log.markRead() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Chat").font(Yap.Font.label).foregroundStyle(Yap.title)
            Text(log.connection ?? "Not connected").font(Yap.Font.caption).foregroundStyle(Yap.faint).lineLimit(1)
            Spacer()
            SlotButton(symbol: "power", label: "Turn off agent", help: "Turn off the agent: no chat, no blocks bar",
                       active: false, compact: true) { withAnimation(Yap.Motion.select) { model.agentEnabled = false } }
        }
        .padding(.leading, 16).padding(.trailing, 2).frame(height: Yap.Grid.cell + 4)
    }

    private var history: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if log.entries.isEmpty { ChatWelcome().padding(.top, 40) }
                    ForEach(log.entries) { e in ChatEntryView(model: model, entry: e).id(e.id) }
                    if log.isWorking { ChatWorking().id("working") }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .onChange(of: log.entries.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: log.isWorking) { _, _ in scrollToEnd(proxy) }
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(Yap.Motion.select) {
            if log.isWorking { proxy.scrollTo("working", anchor: .bottom) } else if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let handler = hooks.promptHandler else { return }
        handler(t)
    }
}

/// Nothing happened yet: one thought.
private struct ChatWelcome: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(Yap.caption)
            Text("Edit by asking").font(.system(size: 15, weight: .semibold)).foregroundStyle(Yap.title)
            Text("Changes from your agent land here and on the timeline, each one a single undo step.")
                .font(Yap.Font.body).foregroundStyle(Yap.body).multilineTextAlignment(.center).frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ChatWorking: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working…").font(Yap.Font.body).foregroundStyle(Yap.caption)
        }
        .padding(.leading, 8)
        .accessibilityElement(children: .combine)
    }
}

/// The recessed prompt field; Return or the arrow sends.
struct ChatInput: View {
    let send: (String) -> Void
    @State private var prompt = ""

    var body: some View {
        RecessedField("Ask for a change", text: $prompt) {
            Button(action: submit) { Image(systemName: "arrow.up") }
                .buttonStyle(CircleButtonStyle(active: !prompt.trimmingCharacters(in: .whitespaces).isEmpty, size: 28))
                .help("Send").accessibilityLabel("Send")
        }
        .onSubmit(submit)
    }

    private func submit() {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        send(prompt); prompt = ""
    }
}

/// No agent takes prompts yet: one line and the command to connect one.
struct ConnectHint: View {
    let command: (() -> String)?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 10) {
            Text("Connect Claude Code or Codex to edit by asking.")
                .font(Yap.Font.body).foregroundStyle(Yap.body).multilineTextAlignment(.center)
            Button(copied ? "Copied" : "Copy connect command") { copy() }
                .buttonStyle(CapsuleButtonStyle(.secondary, height: 30))
                .disabled(command == nil)
                .help(command == nil ? "Not available in this build yet" : "Copies the command that connects your agent to this editor")
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    private func copy() {
        guard let command else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command(), forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}
