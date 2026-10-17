import AppKit
import SwiftUI
import YapcamDesign

/// Editor window content. The preview surface is injected so the module can be built and
/// previewed against fakes; `EditorDocument` passes `PreviewView(player:)`.
public struct EditorContent<Preview: View>: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var export: ExportModel
    let preview: Preview
    let title: String
    let packageURL: URL?
    let initialSection: InspectorSection
    @State private var showExport = false
    /// The docked chat column is open (wide window, agent on).
    @State private var chatOpen = true
    /// The chat floats over the stage (narrow window, agent on).
    @State private var chatFloating = false
    /// Current width of the editor (decides docked or floating chat when the agent is switched on).
    @State private var width: CGFloat = 0

    public init(model: EditorModel, export: ExportModel, title: String = "Recording", packageURL: URL? = nil,
                initialSection: InspectorSection = .background, @ViewBuilder preview: () -> Preview) {
        self.model = model; self.export = export; self.title = title; self.packageURL = packageURL
        self.initialSection = initialSection; self.preview = preview()
    }

    /// Variant B: below this width the chat column collapses and opens floating over the stage.
    static var autoCollapseWidth: CGFloat { 1500 }
    static var inspectorWidth: CGFloat { 354 }

    public var body: some View {
        GeometryReader { geo in
            let narrow = geo.size.width < Self.autoCollapseWidth
            VStack(spacing: 0) {
                EditorTitleRow(model: model, title: title, packageURL: packageURL, showExport: $showExport,
                               exportRunning: export.isRunning, chatShown: chatShown(narrow: narrow)) { toggleAgent(narrow: narrow) }
                DockSeparator(axis: .horizontal)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            if model.agentEnabled && !narrow && chatOpen {
                                ChatColumn(model: model).frame(width: ChatColumn.width)
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                                DockSeparator()
                            }
                            stage
                                .overlay(alignment: .topLeading) { floatingChat(narrow: narrow) }
                        }
                        DockSeparator(axis: .horizontal)
                        BottomPanelView(model: model, topHairline: false)
                            .frame(height: BottomPanelView.preferredHeight(model: model, windowHeight: geo.size.height))
                    }
                    DockSeparator()
                    InspectorView(model: model, initialSection: initialSection)
                        .frame(width: Self.inspectorWidth)
                        .frame(maxHeight: .infinity)
                        .background(Yap.dock)
                }
            }
        }
        .ignoresSafeArea()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .frame(minWidth: 1000, minHeight: 640)
        .background(Yap.ground)
        .background(EditorWindowChrome())
        .yapWindow()
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .sheet(isPresented: $model.paletteVisible) { CommandPaletteView(model: model) }
        .sheet(isPresented: $showExport) { ExportSheet(export: export, suggestedName: title) }
        .alert("Something went wrong", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: { Text(model.lastError ?? "") }
        .focusedSceneValue(\.editorModel, model)
        .onChange(of: model.selection) { _, new in if new != .none { model.announce(model.describe(new)) } }
        .onChange(of: model.agentEnabled) { _, on in agentSwitched(on) }
        .onAppear { model.showExportPickerHandler = { showExport = true }; if model.exportModel == nil { model.exportModel = export }; model.exportTitle = title
            if model.agentEnabled { agentSwitched(true) } }
        .onDisappear { model.saveNow() }
    }

    // MARK: agent and chat

    private func chatShown(narrow: Bool) -> Bool { model.agentEnabled && (narrow ? chatFloating : chatOpen) }

    /// Off: switches the agent on (chat and blocks bar). On: shows or hides the chat, floating on a narrow window.
    private func toggleAgent(narrow: Bool) {
        if !model.agentEnabled { model.agentEnabled = true }
        else if narrow { chatFloating.toggle() }
        else { chatOpen.toggle() }
    }

    /// The agent comes with its chat and the blocks bar; switched off, both go.
    private func agentSwitched(_ on: Bool) {
        chatOpen = on
        chatFloating = on && width > 0 && width < Self.autoCollapseWidth
        model.blocksBarVisible = on
    }

    /// Variant B on a narrow window: the chat floats over the stage instead of taking its width.
    @ViewBuilder private func floatingChat(narrow: Bool) -> some View {
        if model.agentEnabled && narrow && chatFloating {
            ChatColumn(model: model, floating: true)
                .frame(width: ChatColumn.width)
                .padding(12).padding(.top, StageControls.height - 12)
                .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    // MARK: stage

    /// Air around the preview on the stage.
    static var air: CGFloat { 32 }

    /// The stage: quiet controls on top, the preview large and centred with air around it, the blocks bar just under it.
    private var stage: some View {
        VStack(spacing: 0) {
            StageControls(model: model)
            GeometryReader { geo in
                let showBar = model.blocksBarVisible
                let size = Self.fit(aspect: model.previewAspect, in: geo.size, reserve: showBar ? Yap.Grid.bar + 14 : 0)
                VStack(spacing: 14) {
                    previewArea.frame(width: size.width, height: size.height)
                    if showBar { BlocksBar(model: model).transition(.opacity.combined(with: .scale(scale: 0.96))) }
                }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .padding(.bottom, StageControls.height / 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Yap.ground.onTapGesture { model.selection = .none })
        .clipped()
    }

    /// The largest size of `aspect` inside `room` minus the air (and the room `reserve` keeps below it).
    static func fit(aspect: Double, in room: CGSize, reserve: CGFloat = 0) -> CGSize {
        let a = aspect > 0 && aspect.isFinite ? CGFloat(aspect) : 16 / 9
        let w = max(room.width - 2 * air, 10), h = max(room.height - air - reserve, 10)
        return w / h > a ? CGSize(width: h * a, height: h) : CGSize(width: w, height: w / a)
    }

    private var previewArea: some View {
        ZStack {
            if model.clips.isEmpty || model.durationNs <= 0 {
                Text("Nothing to preview yet").font(Yap.Font.body).foregroundStyle(Yap.caption)
            }
            preview
                .overlay { if model.selectedZoom != nil { FocusPickerOverlay(model: model, playhead: model.playhead) } }
                .overlay { rectEditor }
                .scaleEffect(model.previewZoom)
                .offset(model.previewPan)
                // ⌥-drag pans a magnified preview; plain drags belong to the focus/box editors.
                .simultaneousGesture(DragGesture().onChanged { v in
                    if model.previewZoom > 1, NSEvent.modifierFlags.contains(.option) { model.previewPan = v.translation }
                })
        }
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
        // While a text field edits (chat input, captions, text items, transcript), every key belongs to the field.
        if NSApp.keyWindow?.firstResponder is NSText { return .ignored }
        var mods = ShortcutModifiers()
        if p.modifiers.contains(.command) { mods.insert(.command) }
        if p.modifiers.contains(.shift) { mods.insert(.shift) }
        if p.modifiers.contains(.option) { mods.insert(.option) }
        if p.modifiers.contains(.control) { mods.insert(.control) }
        if p.modifiers.contains(.command) {
            if p.key == .leftArrow { model.seek(toNs: 0); return .handled }
            if p.key == .rightArrow { model.seek(toNs: model.durationNs); return .handled }
            // ⌥ changes `characters` (⌥S types ß): the key itself identifies the command.
            let c = mods.contains(.option) ? p.key.character : (p.characters.first ?? p.key.character)
            if model.handleShortcut(c, mods) { return .handled }
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
        if let c = p.characters.first, !p.modifiers.contains(.option), model.handleShortcut(c, mods) { return .handled }
        return .ignored
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
                    Circle().strokeBorder(Yap.zoom, lineWidth: 2).background(Circle().fill(Yap.zoom.opacity(0.25)))
                        .frame(width: 22, height: 22)
                        .position(markerPosition(z, in: geo.size))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in if let u = PointerMath.unit(v.location, in: geo.size) { model.previewFocus(fromPreview: u) } }
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
    enum Mode: Equatable { case move, corner(Int) }   // 0 TL, 1 TR, 2 BL, 3 BR

    private func nudge(_ dx: Double, _ dy: Double, resize: Bool) {
        guard let r = base() else { return }
        preview(resize ? [r[0], r[1], r[2] + dx, r[3] + dy] : [r[0] + dx, r[1] + dy, r[2], r[3]])
        commit()
    }

    private func pixelFrame(_ rect: [Double], space: String, _ g: FrameGeometry, _ size: CGSize) -> CGRect {
        let r = g.previewRect(fromNormalized: rect, space: space)
        return CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
    }

    @ViewBuilder private func box(_ size: CGSize) -> some View {
        if let c = current(), let g = model.project.frameGeometry(atNs: model.playheadNs) {
            let frame = pixelFrame(c.rect, space: c.space, g, size)
            Rectangle().strokeBorder(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .background(Color.white.opacity(0.08))
                .frame(width: frame.width, height: frame.height).offset(x: frame.minX, y: frame.minY)
            ForEach(0..<4, id: \.self) { i in
                Circle().fill(Color.white).overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1)).frame(width: 12, height: 12)
                    .position(x: i % 2 == 0 ? frame.minX : frame.maxX, y: i < 2 ? frame.minY : frame.maxY)
            }
        }
    }

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard let c = current(), let rect = base(), let g = model.project.frameGeometry(atNs: model.playheadNs) else { return }
                if start == nil {
                    guard let mode = PointerMath.rectHit(at: v.startLocation, frame: pixelFrame(rect, space: c.space, g, size)) else { return }
                    start = (mode, rect, v.startLocation)
                }
                guard let s = start else { return }
                let pd = PointerMath.delta(from: s.origin, to: v.location, in: size)
                let d = g.normalizedDelta(dx: pd.width, dy: pd.height, space: c.space)
                preview(HighlightGeometry.apply(rect: s.rect, delta: d, mode: s.mode))
            }
            .onEnded { _ in start = nil; commit() }
    }

    private var accessibilityRect: String {
        guard let r = current()?.rect else { return "" }
        return String(format: "left %.0f, top %.0f, width %.0f, height %.0f percent", r[0] * 100, r[1] * 100, r[2] * 100, r[3] * 100)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                box(geo.size)
            }
            .gesture(drag(geo.size))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Box editor")
        .accessibilityValue(accessibilityRect)
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
