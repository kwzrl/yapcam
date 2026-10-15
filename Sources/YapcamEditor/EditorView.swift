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
                ZStack {
                    Color.black.opacity(0.88)
                    preview
                        .aspectRatio(model.previewAspect, contentMode: .fit)
                        .overlay { if model.selectedZoom != nil { FocusPickerOverlay(model: model, playhead: model.playhead) } }
                        .overlay { rectEditor }
                        .padding(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Button { model.paletteVisible = true } label: { Label("Commands", systemImage: "command") }
                Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
            }
        }
        .sheet(isPresented: $model.paletteVisible) { CommandPaletteView(model: model) }
        .sheet(isPresented: $showExport) { ExportSheet(export: export, suggestedName: title) }
        .alert("Something went wrong", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: { Text(model.lastError ?? "") }
        .focusedSceneValue(\.editorModel, model)
        .onChange(of: model.selection) { _, new in if new != .none { model.announce(model.describe(new)) } }
        .onDisappear { model.saveNow() }
    }

    /// Box editor over the preview for the selected highlight or text item (not for music/captions lists).
    @ViewBuilder private var rectEditor: some View {
        if case .highlight(let id) = model.selection, model.highlights.contains(where: { $0.id == id }) {
            RectEditOverlay(model: model,
                            current: { model.highlights.first { $0.id == id }.map { (model.displayedRect(of: $0), $0.space) } },
                            preview: { model.previewHighlightRect(id: id, rect: $0) }, commit: { model.commitHighlightRect() },
                            base: { model.highlights.first { $0.id == id }?.rect })
        } else if case .text(let kind, let id) = model.selection, let t = model.textItems(kind).first(where: { $0.id == id }) {
            RectEditOverlay(model: model,
                            current: { model.textItems(kind).first { $0.id == id }.map { (model.displayedRect(of: $0), $0.space) } },
                            preview: { model.previewTextRect(key: EditorModel.textKey(t), rect: $0) }, commit: { model.commitTextRect() },
                            base: { model.textItems(kind).first { $0.id == id }?.rect })
        }
    }

    private func handleKey(_ p: KeyPress) -> KeyPress.Result {
        if p.modifiers.contains(.command) {
            if p.characters.lowercased() == "k" { model.paletteVisible = true; return .handled }
            if p.characters.lowercased() == "c", p.modifiers.contains(.shift) { model.copyFrameHandler?(); return .handled }
            return .ignored
        }
        switch p.key {
        case .space: model.togglePlay(); return .handled
        case .delete, .deleteForward: model.deleteSelection(); return .handled
        case .leftArrow, .rightArrow:
            let forward = p.key == .rightArrow
            if p.modifiers.contains(.option) { model.jumpToEditPoint(forward: forward) }
            else if p.modifiers.contains(.control) { model.nudgeSelection(byNs: (forward ? 1 : -1) * (p.modifiers.contains(.shift) ? 1_000_000_000 : 100_000_000)) }
            else { model.step(bySeconds: (forward ? 1 : -1) * (p.modifiers.contains(.shift) ? 1 : 1.0 / 30)) }
            return .handled
        case .upArrow, .downArrow: return model.selectAdjacent(forward: p.key == .downArrow) ? .handled : .ignored
        case .escape: if model.selection == .none { return .ignored }; model.selection = .none; return .handled
        case .return: if let i = model.selectableItems.first(where: { $0.selection == model.selection }) { model.seek(toNs: i.startNs); return .handled }; return .ignored
        default: break
        }
        switch p.characters.lowercased() {
        case "j", "k", "l": model.shuttle(Character(p.characters.lowercased())); return .handled
        case "s": model.splitAtPlayhead(); return .handled
        case "z":
            if p.modifiers.contains(.shift) { model.fitTimeline(width: 900) } else { model.addZoomAtPlayhead() }
            return .handled
        case "[": model.trim(keepAfter: true); return .handled
        case "]": model.trim(keepAfter: false); return .handled
        case "=", "+": model.zoomTimeline(by: 1.25, anchorX: model.geometry.x(forNs: model.playheadNs)); return .handled
        case "-": model.zoomTimeline(by: 0.8, anchorX: model.geometry.x(forNs: model.playheadNs)); return .handled
        default: return .ignored
        }
    }
}

struct TransportBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var playhead: PlayheadState
    init(model: EditorModel) { self.model = model; playhead = model.playhead }
    var body: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                Image(systemName: playhead.isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
            }
            .help("Play / Pause (Space)")
            .accessibilityLabel(playhead.isPlaying ? "Pause" : "Play")
            Text("\(formatTimecode(playhead.ns)) / \(formatTimecode(model.durationNs))")
                .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Button { model.splitAtPlayhead() } label: { Label("Split", systemImage: "scissors") }.help("Split at playhead (S, ⌘B)")
            Button { model.addZoomAtPlayhead() } label: { Label("Add zoom", systemImage: "plus.magnifyingglass") }.help("Add zoom at playhead (Z)")
            Button { model.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                .disabled(model.selection == .none).help("Delete selection (⌫)")
            Toggle(isOn: $model.snappingEnabled) { Image(systemName: "magnet") }.toggleStyle(.button).help("Snapping").accessibilityLabel("Snapping")
            Divider().frame(height: 16)
            Button { model.zoomTimeline(by: 0.8, anchorX: model.geometry.x(forNs: model.playheadNs)) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom timeline out (-)").accessibilityLabel("Zoom timeline out")
            Button { model.zoomTimeline(by: 1.25, anchorX: model.geometry.x(forNs: model.playheadNs)) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom timeline in (+)").accessibilityLabel("Zoom timeline in")
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
            Button("Command Palette…") { model?.paletteVisible = true }.keyboardShortcut("k").disabled(model == nil)
            Button("Add Zoom at Playhead") { model?.addZoomAtPlayhead() }.keyboardShortcut("z", modifiers: [.command, .option]).disabled(model == nil)
        }
    }
}

/// Transparent layer over the preview while a zoom is selected: click or drag to place its focus point.
struct FocusPickerOverlay: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var playhead: PlayheadState
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                if let z = model.selectedZoom {
                    // Marker shows the stored focus in the same (uncropped) preview space as the click mapping.
                    Circle().strokeBorder(Color.orange, lineWidth: 2).background(Circle().fill(Color.orange.opacity(0.25)))
                        .frame(width: 22, height: 22)
                        .position(markerPosition(z, in: geo.size))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in model.previewFocus(fromPreview: CGPoint(x: v.location.x / geo.size.width, y: v.location.y / geo.size.height)) }
                .onEnded { _ in model.commitFocusPreview() })
        }
        .help("Click to set the zoom focus point")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Zoom focus point")
        .accessibilityValue(model.selectedZoom.map { String(format: "%.0f percent across, %.0f percent down", $0.focusX * 100, $0.focusY * 100) } ?? "")
        .accessibilityAction(named: "Move left") { model.nudgeFocus(dx: -0.05, dy: 0) }
        .accessibilityAction(named: "Move right") { model.nudgeFocus(dx: 0.05, dy: 0) }
        .accessibilityAction(named: "Move up") { model.nudgeFocus(dx: 0, dy: -0.05) }
        .accessibilityAction(named: "Move down") { model.nudgeFocus(dx: 0, dy: 0.05) }
    }
    private func markerPosition(_ z: TimelineZoom, in size: CGSize) -> CGPoint {
        guard let g = model.project.frameGeometry(atNs: model.playheadNs) else { return .zero }
        let fx = model.focusPreview?.id == z.id ? model.focusPreview!.x : z.focusX
        let fy = model.focusPreview?.id == z.id ? model.focusPreview!.y : z.focusY
        let cx = g.dest.minX + (fx - g.crop.minX) / max(g.crop.width, 0.001) * g.dest.width
        let cy = g.dest.minY + (fy - g.crop.minY) / max(g.crop.height, 0.001) * g.dest.height
        return CGPoint(x: cx / g.canvasWidth * size.width, y: cy / g.canvasHeight * size.height)
    }
}

/// Rectangle editor over the preview for the selected region/text: drag the body to move,
/// drag a corner to resize. One command is committed on release.
struct RectEditOverlay: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var playhead: PlayheadState
    let current: () -> (rect: [Double], space: String)?
    let preview: ([Double]) -> Void
    let commit: () -> Void
    let base: () -> [Double]?
    init(model: EditorModel, current: @escaping () -> (rect: [Double], space: String)?, preview: @escaping ([Double]) -> Void,
         commit: @escaping () -> Void, base: @escaping () -> [Double]?) {
        self.model = model; self.current = current; self.preview = preview; self.commit = commit; self.base = base; playhead = model.playhead
    }
    @State private var start: (mode: Mode, rect: [Double], origin: CGPoint)?
    enum Mode { case move, corner(Int) }   // 0 TL, 1 TR, 2 BL, 3 BR

    private func nudge(_ dx: Double, _ dy: Double, resize: Bool) {
        guard let r = base() else { return }
        preview(resize ? [r[0], r[1], r[2] + dx, r[3] + dy] : [r[0] + dx, r[1] + dy, r[2], r[3]])
        commit()
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                if let c = current(), let g = model.project.frameGeometry(atNs: model.playheadNs) {
                    let r = g.previewRect(fromNormalized: c.rect, space: c.space)
                    let frame = CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
                    Rectangle().strokeBorder(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .background(Color.accentColor.opacity(0.08))
                        .frame(width: frame.width, height: frame.height).offset(x: frame.minX, y: frame.minY)
                    ForEach(0..<4, id: \.self) { i in
                        Circle().fill(Color.white).overlay(Circle().stroke(Color.accentColor, lineWidth: 2)).frame(width: 12, height: 12)
                            .position(x: i % 2 == 0 ? frame.minX : frame.maxX, y: i < 2 ? frame.minY : frame.maxY)
                    }
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard let c = current(), let rect = base(), let g = model.project.frameGeometry(atNs: model.playheadNs) else { return }
                    if start == nil {
                        let r = g.previewRect(fromNormalized: rect, space: c.space)
                        let f = CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
                        let corners = [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.maxY)]
                        let hit = corners.firstIndex { hypot($0.x - v.startLocation.x, $0.y - v.startLocation.y) <= 14 }
                        guard hit != nil || f.contains(v.startLocation) else { return }
                        start = (hit.map { .corner($0) } ?? .move, rect, v.startLocation)
                    }
                    guard let s = start else { return }
                    let d = g.normalizedDelta(dx: (v.location.x - s.origin.x) / size.width, dy: (v.location.y - s.origin.y) / size.height, space: c.space)
                    preview(HighlightGeometry.apply(rect: s.rect, delta: d, mode: s.mode))
                }
                .onEnded { _ in start = nil; commit() })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Box editor")
        .accessibilityValue(current().map { r in String(format: "left %.0f, top %.0f, width %.0f, height %.0f percent", r.rect[0] * 100, r.rect[1] * 100, r.rect[2] * 100, r.rect[3] * 100) } ?? "")
        .accessibilityAction(named: "Move left") { nudge(-0.02, 0, resize: false) }
        .accessibilityAction(named: "Move right") { nudge(0.02, 0, resize: false) }
        .accessibilityAction(named: "Move up") { nudge(0, -0.02, resize: false) }
        .accessibilityAction(named: "Move down") { nudge(0, 0.02, resize: false) }
        .accessibilityAction(named: "Make wider") { nudge(0.02, 0, resize: true) }
        .accessibilityAction(named: "Make narrower") { nudge(-0.02, 0, resize: true) }
        .accessibilityAction(named: "Make taller") { nudge(0, 0.02, resize: true) }
        .accessibilityAction(named: "Make shorter") { nudge(0, -0.02, resize: true) }
    }
}

enum HighlightGeometry {
    static func apply(rect r: [Double], delta d: CGSize, mode: RectEditOverlay.Mode) -> [Double] {
        switch mode {
        case .move: return [r[0] + d.width, r[1] + d.height, r[2], r[3]]
        case .corner(let i):
            var x0 = r[0], y0 = r[1], x1 = r[0] + r[2], y1 = r[1] + r[3]
            if i % 2 == 0 { x0 += d.width } else { x1 += d.width }
            if i < 2 { y0 += d.height } else { y1 += d.height }
            return [min(x0, x1), min(y0, y1), abs(x1 - x0), abs(y1 - y0)]
        }
    }
}
