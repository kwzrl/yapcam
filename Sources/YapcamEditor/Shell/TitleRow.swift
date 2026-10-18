import AppKit
import SwiftUI
import YapcamDesign

/// The editor's one title row (52 pt, under the unified title bar so the window buttons sit centred in it).
/// Left: Agent and Blocks toggles, project name and duration. Right: Presets, Undo, Redo, "…", the white Export capsule.
struct EditorTitleRow: View {
    @ObservedObject var model: EditorModel
    let title: String
    let packageURL: URL?
    @Binding var showExport: Bool
    var exportRunning = false
    /// The chat is visible (docked or floating).
    let chatShown: Bool
    let toggleAgent: () -> Void
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    static let height: CGFloat = 52
    /// Room for the window's own buttons at the leading edge.
    static let windowButtons: CGFloat = 72

    var body: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: Self.windowButtons, height: 1).accessibilityHidden(true)
            AgentToggle(model: model, log: model.agentLog, chatShown: chatShown, action: toggleAgent)
            SlotButton(symbol: "square.on.circle", label: "Blocks",
                       help: model.blocksBarVisible ? "Hide building blocks" : "Show building blocks: title, spotlight, text",
                       active: model.blocksBarVisible, compact: true) {
                withAnimation(Yap.Motion.select) { model.blocksBarVisible.toggle() }
            }
            name.padding(.leading, 10)
            Text(formatTimecode(model.durationNs, showFraction: false)).technical().padding(.leading, 6)
                .accessibilityLabel("Duration")
            if case .failed(let why) = model.saveState {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Yap.title).padding(.leading, 8)
                    .help("Couldn't save the project: \(why)").accessibilityLabel("Couldn't save the project")
            }
            Spacer(minLength: 12)
            PresetsMenu(model: model)
            SlotButton(symbol: "arrow.uturn.backward", label: "Undo", help: model.canUndo ? "\(model.undoTitle) (⌘Z)" : "Nothing to undo", active: false, enabled: model.canUndo, compact: true) { model.undo() }
            SlotButton(symbol: "arrow.uturn.forward", label: "Redo", help: model.canRedo ? "\(model.redoTitle) (⇧⌘Z)" : "Nothing to redo", active: false, enabled: model.canRedo, compact: true) { model.redo() }
            moreMenu
            if model.canRecordFromEditor {
                Button { model.requestNewRecording() } label: {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                }
                .buttonStyle(CapsuleButtonStyle(.secondary, height: 30)).padding(.leading, 10)
                .help("New recording (⌘N): shows the recording toolbar")
                .accessibilityLabel("New recording")
            }
            Button("Export") { showExport = true }
                .buttonStyle(CapsuleButtonStyle(.primary, height: 30)).padding(.leading, 10)
                .disabled(exportRunning)
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .help(exportRunning ? "An export is running. Wait for it to finish." : "Export the video (⇧⌘E)")
                .accessibilityLabel("Export")
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(Yap.dock)
        .confirmationDialog("Move “\(title)” to the Trash?", isPresented: $model.trashRequested, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                guard let url = packageURL else { return }
                // Close the window first (it saves), then trash, so nothing is written into a moved package.
                // This document's own window (not whichever window happens to be key).
                EditorWindows.close(package: url)
                NSWorkspace.shared.recycle([url])
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The recording and its edits will be moved to the Trash.") }
    }

    @ViewBuilder private var name: some View {
        if editingTitle {
            TextField("Project name", text: $titleDraft)
                .textFieldStyle(.plain).font(Yap.Font.label).foregroundStyle(Yap.title)
                .padding(.horizontal, 8).frame(width: 220, height: 26)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Yap.recess))
                .focused($titleFocused)
                .onSubmit { commitTitle() }
                .onExitCommand { editingTitle = false }
                .accessibilityLabel("Project name")
        } else {
            Text(title).font(Yap.Font.label).foregroundStyle(Yap.label).lineLimit(1).truncationMode(.middle)
                .help(packageURL == nil ? "" : "Double-click to rename")
                .onTapGesture(count: 2) { beginRename() }
                .accessibilityAction(named: "Rename") { beginRename() }
        }
    }

    /// Rarely used project actions.
    private var moreMenu: some View {
        SlotMenu(symbol: "ellipsis", label: "More", help: "More: command palette, Finder, rename, trash") {
            Button("Command Palette…") { model.paletteVisible = true }
            if model.canShowProjects { Button("Projects…") { model.showProjects() } }
            if let copy = model.copyFrameHandler { Button("Copy Frame") { copy() } }
            Divider()
            Button("Show in Finder") { if let packageURL { NSWorkspace.shared.activateFileViewerSelecting([packageURL]) } }
                .disabled(packageURL == nil)
            Button("Rename…") { beginRename() }.disabled(packageURL == nil)
            Divider()
            Button("Move to Trash…") { model.trashRequested = true }.disabled(packageURL == nil)
        }
    }

    private func beginRename() {
        guard packageURL != nil else { return }
        titleDraft = title; editingTitle = true; titleFocused = true
    }

    private func commitTitle() {
        editingTitle = false
        guard let packageURL, titleDraft != title else { return }
        do { try EditorWindows.rename(package: packageURL, to: titleDraft) } catch { model.lastError = error.localizedDescription }
    }
}

/// Agent off: a quiet way in. On: shows and hides the chat; brightens while something new waits in a hidden chat.
private struct AgentToggle: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var log: AgentActivityLog
    let chatShown: Bool
    let action: () -> Void

    var body: some View {
        let unread = log.unread > 0 && !chatShown
        let help = model.agentEnabled ? (chatShown ? "Hide chat" : (unread ? "Show chat: something new" : "Show chat"))
                                      : "Edit with an agent (Claude Code, Codex)"
        SlotButton(symbol: "bubble.left", label: "Chat", help: help, active: chatShown, compact: true, attention: unread) {
            withAnimation(Yap.Motion.select) { action() }
        }
    }
}

/// Apply, save and manage looks (presets): the popover lives in PresetsPopover.swift.
private struct PresetsMenu: View {
    @ObservedObject var model: EditorModel
    @State private var shown = false

    var body: some View {
        SlotButton(symbol: "wand.and.rays", label: "Presets", help: "Apply or save a look", active: shown, compact: true) { shown.toggle() }
            .popover(isPresented: $shown, arrowEdge: .bottom) { PresetsPopover(model: model, shown: $shown) }
    }
}
