import SwiftUI

public struct PaletteCommand: Identifiable {
    public var id: String { title }
    public let title: String
    public let shortcut: String
    public let enabled: Bool
    public let run: @MainActor () -> Void
}

extension EditorModel {
    /// Everything reachable from the ⌘K palette; also the single source for the shortcut cheat sheet.
    public var paletteCommands: [PaletteCommand] {
        let hasSel = selection != .none
        return [
            PaletteCommand(title: isPlaying ? "Pause" : "Play", shortcut: "Space", enabled: true) { [self] in togglePlay() },
            PaletteCommand(title: "Split at playhead", shortcut: "S", enabled: true) { [self] in splitAtPlayhead() },
            PaletteCommand(title: "Delete selection", shortcut: "⌫", enabled: hasSel) { [self] in deleteSelection() },
            PaletteCommand(title: "Trim start to playhead", shortcut: "[", enabled: true) { [self] in trim(keepAfter: true) },
            PaletteCommand(title: "Trim end to playhead", shortcut: "]", enabled: true) { [self] in trim(keepAfter: false) },
            PaletteCommand(title: "Add zoom at playhead", shortcut: "Z", enabled: true) { [self] in addZoomAtPlayhead() },
            PaletteCommand(title: "Add text at playhead", shortcut: "", enabled: true) { [self] in addText(.annotation) },
            PaletteCommand(title: "Add reaction at playhead", shortcut: "", enabled: true) { [self] in addText(.reaction, text: reactionGlyphs[0]) },
            PaletteCommand(title: "Add highlight at playhead", shortcut: "", enabled: true) { [self] in addHighlightAtPlayhead(kind: .highlight) },
            PaletteCommand(title: "Add mask at playhead", shortcut: "", enabled: true) { [self] in addHighlightAtPlayhead(kind: .mask) },
            PaletteCommand(title: "Generate captions from speech", shortcut: "", enabled: true) { [self] in generateCaptions() },
            PaletteCommand(title: "Add calm background music", shortcut: "", enabled: true) { [self] in addBuiltInMusic(builtInMusic[0]) },
            PaletteCommand(title: "Regenerate automatic zooms", shortcut: "", enabled: true) { [self] in regenerateAutoZooms() },
            PaletteCommand(title: "Add camera layout at playhead", shortcut: "", enabled: hasCamera) { [self] in addLayoutAtPlayhead() },
            PaletteCommand(title: "Hide cursor from playhead", shortcut: "", enabled: true) { [self] in addCursorHideAtPlayhead() },
            PaletteCommand(title: "Speed up typing", shortcut: "", enabled: true) { [self] in speedUpTyping() },
            PaletteCommand(title: "Find silent parts", shortcut: "", enabled: true) { [self] in findSilences() },
            PaletteCommand(title: "Copy current frame", shortcut: "⇧⌘C", enabled: copyFrameHandler != nil) { [self] in copyFrameHandler?() },
            PaletteCommand(title: "Undo", shortcut: "⌘Z", enabled: canUndo) { [self] in undo() },
            PaletteCommand(title: "Redo", shortcut: "⇧⌘Z", enabled: canRedo) { [self] in redo() },
            PaletteCommand(title: "Zoom timeline in", shortcut: "+", enabled: true) { [self] in zoomTimeline(by: 1.25) },
            PaletteCommand(title: "Zoom timeline out", shortcut: "−", enabled: true) { [self] in zoomTimeline(by: 0.8) },
            PaletteCommand(title: "Fit timeline to window", shortcut: "⇧Z", enabled: true) { [self] in fitTimeline(width: 900) },
            PaletteCommand(title: "Toggle snapping", shortcut: "", enabled: true) { [self] in snappingEnabled.toggle() },
        ]
    }

    public func filteredCommands(_ query: String) -> [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return paletteCommands }
        // Every query word must appear as a prefix of some title word (fuzzy enough, predictable).
        let words = q.split(separator: " ")
        return paletteCommands.filter { c in
            let titleWords = c.title.lowercased().split(separator: " ")
            return words.allSatisfy { w in titleWords.contains { $0.hasPrefix(w) } }
        }
    }
}

struct CommandPaletteView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0

    var body: some View {
        let items = model.filteredCommands(query)
        VStack(spacing: 0) {
            TextField("Type a command…", text: $query)
                .textFieldStyle(.plain).font(.title3).padding(14)
                .onSubmit { run(items) }
                .onChange(of: query) { _, _ in highlighted = 0 }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(items.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
            Divider()
            if items.isEmpty { Text("No matching command").foregroundStyle(.secondary).padding(20) }
            else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                            HStack {
                                Text(c.title).foregroundStyle(c.enabled ? .primary : .tertiary)
                                Spacer()
                                Text(c.shortcut).font(.callout.monospaced()).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(i == highlighted ? Color.accentColor.opacity(0.18) : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { highlighted = i; run(items) }
                        }
                    }
                }
            }
        }
        .frame(width: 460, height: 340)
    }

    private func run(_ items: [PaletteCommand]) {
        guard items.indices.contains(highlighted), items[highlighted].enabled else { return }
        let c = items[highlighted]
        dismiss()
        c.run()
    }
}
