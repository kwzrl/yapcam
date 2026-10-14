import SwiftUI

/// Editor window content. The preview surface is injected so the module can be built and
/// previewed against fakes; `EditorDocument` passes `PreviewView(player:)`.
public struct EditorContent<Preview: View>: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var export: ExportModel
    let preview: Preview
    let title: String
    @State private var showExport = false
    @State private var showInspector = true

    public init(model: EditorModel, export: ExportModel, title: String = "Recording", @ViewBuilder preview: () -> Preview) {
        self.model = model; self.export = export; self.title = title; self.preview = preview()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                preview.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.88))
                if showInspector { Divider(); InspectorView(model: model).frame(width: 280) }
            }
            Divider()
            TransportBar(model: model)
            Divider()
            TimelineView(model: model)
        }
        .frame(minWidth: 900, minHeight: 600)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .toolbar {
            ToolbarItemGroup {
                Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(!model.canUndo)
                Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }.disabled(!model.canRedo)
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
            }
        }
        .sheet(isPresented: $showExport) { ExportSheet(export: export, suggestedName: title) }
        .alert("Something went wrong", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: { Text(model.lastError ?? "") }
        .focusedSceneValue(\.editorModel, model)
        .onDisappear { model.saveNow() }
    }

    private func handleKey(_ p: KeyPress) -> KeyPress.Result {
        if p.modifiers.contains(.command) { return .ignored }
        switch p.key {
        case .space: model.togglePlay(); return .handled
        case .delete, .deleteForward: model.deleteSelection(); return .handled
        case .leftArrow: model.step(bySeconds: p.modifiers.contains(.shift) ? -1 : -1.0 / 30); return .handled
        case .rightArrow: model.step(bySeconds: p.modifiers.contains(.shift) ? 1 : 1.0 / 30); return .handled
        default: break
        }
        switch p.characters.lowercased() {
        case "j", "k", "l": model.shuttle(Character(p.characters.lowercased())); return .handled
        case "s": model.splitAtPlayhead(); return .handled
        case "z": model.addZoomAtPlayhead(); return .handled
        case "=", "+": model.zoomTimeline(by: 1.25, anchorX: model.geometry.x(forNs: model.playheadNs)); return .handled
        case "-": model.zoomTimeline(by: 0.8, anchorX: model.geometry.x(forNs: model.playheadNs)); return .handled
        default: return .ignored
        }
    }
}

struct TransportBar: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
            }
            .help("Play / Pause (Space)")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            Text("\(formatTimecode(model.playheadNs)) / \(formatTimecode(model.durationNs))")
                .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Button { model.splitAtPlayhead() } label: { Label("Split", systemImage: "scissors") }.help("Split at playhead (S, ⌘B)")
            Button { model.addZoomAtPlayhead() } label: { Label("Add zoom", systemImage: "plus.magnifyingglass") }.help("Add zoom at playhead (Z)")
            Button { model.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                .disabled(model.selection == .none).help("Delete selection (⌫)")
            Toggle(isOn: $model.snappingEnabled) { Image(systemName: "magnet") }.toggleStyle(.button).help("Snapping")
            Divider().frame(height: 16)
            Button { model.zoomTimeline(by: 0.8, anchorX: model.geometry.x(forNs: model.playheadNs)) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom timeline out (-)")
            Button { model.zoomTimeline(by: 1.25, anchorX: model.geometry.x(forNs: model.playheadNs)) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom timeline in (+)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

// MARK: menu commands

struct EditorModelKey: FocusedValueKey { typealias Value = EditorModel }
extension FocusedValues { var editorModel: EditorModel? { get { self[EditorModelKey.self] } set { self[EditorModelKey.self] = newValue } } }

/// Include in the app's `.commands { }` — wires Undo/Redo and split to the focused editor.
public struct EditorCommands: Commands {
    @FocusedValue(\.editorModel) private var model
    public init() {}
    public var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model?.undo() }.keyboardShortcut("z").disabled(!(model?.canUndo ?? false))
            Button("Redo") { model?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!(model?.canRedo ?? false))
        }
        CommandMenu("Edit Timeline") {
            Button("Split at Playhead") { model?.splitAtPlayhead() }.keyboardShortcut("b").disabled(model == nil)
            Button("Add Zoom at Playhead") { model?.addZoomAtPlayhead() }.keyboardShortcut("z", modifiers: [.command, .option]).disabled(model == nil)
        }
    }
}
