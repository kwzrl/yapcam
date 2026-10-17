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
        let actions: [PaletteCommand] = [
            PaletteCommand(title: isPlaying ? "Pause" : "Play", shortcut: "Space", enabled: true) { [self] in togglePlay() },
            PaletteCommand(title: "Split at playhead", shortcut: "C", enabled: true) { [self] in splitContextAware() },
            PaletteCommand(title: "Ripple delete to previous cut", shortcut: "X", enabled: true) { [self] in rippleDeleteToPreviousCut() },
            PaletteCommand(title: "Set clip speed…", shortcut: "S", enabled: true) { [self] in speedMenuVisible = true },
            PaletteCommand(title: "Set volume…", shortcut: "V", enabled: true) { [self] in volumeMenuSystem = false; volumeMenuVisible = true },
            PaletteCommand(title: "Duplicate zoom", shortcut: "⌘D", enabled: selectedZoom != nil) { [self] in duplicateSelectedZoom() },
            PaletteCommand(title: "Copy item settings", shortcut: "⌘C", enabled: hasSel) { [self] in copySelectedSettings() },
            PaletteCommand(title: "Paste item settings", shortcut: "⌘V", enabled: itemClipboard != nil && hasSel) { [self] in pasteSettings() },
            PaletteCommand(title: "Delete selection", shortcut: "⌫", enabled: hasSel) { [self] in deleteSelection() },
            PaletteCommand(title: "Cut selection (copy settings, remove)", shortcut: "⌘X", enabled: hasSel) { [self] in cutSelection() },
            PaletteCommand(title: "Reset trim of this clip", shortcut: "", enabled: { if case .clip = selection { hasTrimsOrCuts } else { false } }()) { [self] in if case .clip(let id) = selection { resetTrim(clipID: id) } },
            PaletteCommand(title: "Reset all trims and cuts", shortcut: "", enabled: hasTrimsOrCuts) { [self] in resetAllTrimsAndCuts() },
            PaletteCommand(title: "Trim start to playhead", shortcut: "[", enabled: true) { [self] in trim(keepAfter: true) },
            PaletteCommand(title: "Trim end to playhead", shortcut: "]", enabled: true) { [self] in trim(keepAfter: false) },
            PaletteCommand(title: "Add zoom at playhead", shortcut: "Z", enabled: true) { [self] in addZoomAtPlayhead() },
            PaletteCommand(title: "Select next item", shortcut: "↓", enabled: true) { [self] in selectAdjacent(forward: true) },
            PaletteCommand(title: "Select previous item", shortcut: "↑", enabled: true) { [self] in selectAdjacent(forward: false) },
            PaletteCommand(title: "Next edit point", shortcut: "⌥→", enabled: true) { [self] in jumpToEditPoint(forward: true) },
            PaletteCommand(title: "Previous edit point", shortcut: "⌥←", enabled: true) { [self] in jumpToEditPoint(forward: false) },
            PaletteCommand(title: "Move selection later 0.1 s", shortcut: "⌃→", enabled: hasSel) { [self] in nudgeSelection(byNs: 100_000_000) },
            PaletteCommand(title: "Move selection earlier 0.1 s", shortcut: "⌃←", enabled: hasSel) { [self] in nudgeSelection(byNs: -100_000_000) },
            PaletteCommand(title: "Add text at playhead", shortcut: "", enabled: true) { [self] in addText(.annotation) },
            PaletteCommand(title: "Add reaction at playhead", shortcut: "", enabled: true) { [self] in addText(.reaction, text: reactionGlyphs[0]) },
            PaletteCommand(title: "Add highlight at playhead", shortcut: "", enabled: true) { [self] in addHighlightAtPlayhead(kind: .highlight) },
            PaletteCommand(title: "Add blur mask at playhead", shortcut: "", enabled: true) { [self] in addHighlightAtPlayhead(kind: .blur) },
            PaletteCommand(title: "Add cover mask at playhead", shortcut: "", enabled: true) { [self] in addHighlightAtPlayhead(kind: .mask) },
            PaletteCommand(title: "Generate captions from speech", shortcut: "", enabled: hasMic) { [self] in generateCaptions() },
            PaletteCommand(title: "Remove background audio", shortcut: "", enabled: !music.isEmpty) { [self] in removeAllMusic() },
            PaletteCommand(title: "Regenerate automatic zooms", shortcut: "", enabled: hasMouseData) { [self] in regenerateAutoZooms() },
            PaletteCommand(title: "Add camera layout at playhead", shortcut: "", enabled: hasCamera) { [self] in addLayoutAtPlayhead() },
            PaletteCommand(title: "Hide cursor from playhead", shortcut: "", enabled: hasMouseData) { [self] in addCursorHideAtPlayhead() },
            PaletteCommand(title: "Speed up typing", shortcut: "", enabled: true) { [self] in speedUpTyping() },
            PaletteCommand(title: "Find silent parts", shortcut: "", enabled: true) { [self] in findSilences() },
            PaletteCommand(title: "Copy current frame", shortcut: "⇧⌘C", enabled: copyFrameHandler != nil) { [self] in copyFrameHandler?() },
            PaletteCommand(title: "Keyboard shortcuts", shortcut: "⌘/", enabled: true) { ShortcutsGuide.show() },
            PaletteCommand(title: "Crop recording…", shortcut: "", enabled: true) { [self] in cropRequested = true },
            PaletteCommand(title: "Export current frame as image…", shortcut: "", enabled: canExportFrame) { [self] in exportCurrentFrame() },
            PaletteCommand(title: "Undo", shortcut: "⌘Z", enabled: canUndo) { [self] in undo() },
            PaletteCommand(title: "Redo", shortcut: "⇧⌘Z", enabled: canRedo) { [self] in redo() },
            PaletteCommand(title: "Zoom timeline in", shortcut: "⌘=", enabled: true) { [self] in zoomTimeline(by: 1.25) },
            PaletteCommand(title: "Zoom timeline out", shortcut: "⌘-", enabled: true) { [self] in zoomTimeline(by: 0.8) },
            PaletteCommand(title: "Fit timeline to window", shortcut: "⇧Z", enabled: true) { [self] in fitTimeline(width: timelineViewportWidth) },
            PaletteCommand(title: "Move recording to Trash…", shortcut: "", enabled: true) { [self] in trashRequested = true },
            PaletteCommand(title: showWaveform ? "Hide audio waveform" : "Show audio waveform", shortcut: "", enabled: true) { [self] in setShowWaveform(!showWaveform) },
            PaletteCommand(title: "Reel preview: Off", shortcut: "", enabled: reelPreviewAvailable && reelMode != .off) { [self] in setReelMode(.off) },
            PaletteCommand(title: "Reel preview: Instagram", shortcut: "", enabled: reelPreviewAvailable && reelMode != .instagram) { [self] in setReelMode(.instagram) },
            PaletteCommand(title: "Reel preview: TikTok", shortcut: "", enabled: reelPreviewAvailable && reelMode != .tiktok) { [self] in setReelMode(.tiktok) },
            PaletteCommand(title: smoothWaveform ? "Use detailed waveform" : "Use smooth waveform", shortcut: "", enabled: showWaveform) { [self] in setSmoothWaveform(!smoothWaveform) },
            PaletteCommand(title: "Toggle snapping", shortcut: "", enabled: true) { [self] in snappingEnabled.toggle() },
        ]
        let musicCommands = project.musicLibrary.map { t in PaletteCommand(title: "Add background music: \(t.name) (\(t.categoryTitle))", shortcut: "", enabled: true) { [self] in addLibraryMusic(trackID: t.id) } }
        return actions + exportCommands + musicCommands + settingCommands
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
                            .background(i == highlighted ? Color.white.opacity(0.18) : .clear)
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
