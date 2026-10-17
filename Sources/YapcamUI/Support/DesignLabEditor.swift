import AppKit
import SwiftUI
import YapcamDesign

// The design lab's "Editor" page: the agentic editor as a mock-up (no engine, no project).
// The agent adds to the editor, it replaces nothing: today's full inspector with its icon rail stays
// (DesignLabEditorInspector.swift), the timeline lies on the window ground (DesignLabEditorTimeline.swift).
// Docked like a professional editor: one title row across the window, the chat (agent on) and the inspector as
// columns flush with the window edges, the timeline docked at the bottom from the left edge to the inspector, all
// on the dock tone and separated by hairlines only. The stage in the middle is the calm, darkest place; glass only
// for what really floats (the blocks bar, the floating chat of variant B).
// Agent and building blocks are opt-in: off, there is no chat column, no suggestion and no blocks bar.
// Variants differ only in the open questions: chat always open (A) or auto-collapse on narrow windows (B).

// MARK: - Mock

struct MockSpan {
    let start: Double
    let end: Double
    var title = ""
    var scale = 1.0
    var focus = UnitPoint.center
}

struct MockBlock: Identifiable {
    enum Kind: String, CaseIterable {
        case title, callout, spotlight, text
        var label: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .title: return "textformat.size"
            case .callout: return "text.bubble"
            case .spotlight: return "scope"
            case .text: return "character.cursor.ibeam"
            }
        }
        var sample: String {
            switch self {
            case .title: return "Chapter title"
            case .callout: return "Click Deploy"
            case .spotlight: return ""
            case .text: return "Text"
            }
        }
    }
    let id = UUID()
    var kind: Kind
    var text: String
    var start: Double
    var end: Double
    var center: CGPoint
    var scale: CGFloat = 1
}

struct MockWord: Identifiable {
    let id: Int
    let text: String
    let filler: Bool
}

struct MockMessage: Identifiable {
    let id = UUID()
    let text: String
}

@MainActor @Observable final class EditorMock {
    enum Variant: Hashable, CaseIterable { case open, auto }
    /// Off by default; on = chat and blocks; unconnected = switched on, but no agent set up yet.
    enum Agent: Hashable { case off, on, unconnected }
    enum Lower: Hashable { case timeline, transcript }
    enum Selection: Hashable { case none, clip(Int), zoom(Int), suggestion, layout(Int), block(UUID) }
    enum Review { case pending, accepted, rejected }

    static let duration: Double = 134
    /// Variant B hides the chat column below this window width; opening it then floats it over the preview.
    static let autoCollapseWidth: CGFloat = 1500

    static let clips = [MockSpan(start: 0, end: 12.6), MockSpan(start: 12.6, end: 31.8),
                        MockSpan(start: 31.8, end: 88), MockSpan(start: 88, end: 134)]
    static let zooms = [MockSpan(start: 40, end: 47, title: "Deploy click", scale: 2.0, focus: UnitPoint(x: 0.74, y: 0.24)),
                        MockSpan(start: 70, end: 78, title: "Logs", scale: 1.6, focus: UnitPoint(x: 0.5, y: 0.62))]
    static let suggestion = MockSpan(start: 103, end: 110, title: "Terminal output", scale: 1.8, focus: UnitPoint(x: 0.78, y: 0.8))
    static let layouts = [MockSpan(start: 0, end: 12.6, title: "Camera only"), MockSpan(start: 88, end: 103, title: "Split")]
    static let markers: [Double] = [42, 95]
    static let captions: [MockSpan] = stride(from: 1.0, to: 130, by: 4.3).map { MockSpan(start: $0, end: $0 + 3.7) }
    static let paragraphs = makeTranscript()
    static var fillerCount: Int { paragraphs.flatMap(\.words).filter(\.filler).count }

    var variant = Variant.open
    var agent = Agent.off {
        didSet {
            chatOpen = agent != .off; chatOverlay = false; unread = false
            motion = agent != .off
            if agent == .off, selection == .suggestion { selection = .none }
        }
    }
    var chatOpen = false
    var chatOverlay = false
    /// New agent activity while the chat is closed: shown on the toggle through brightness only.
    var unread = false
    /// The building blocks bar over the preview (opt-in, comes with the agent or on its own).
    var motion = false
    var tab = InspectorTab.background
    var selection = Selection.none
    var lower = Lower.timeline
    var time: Double = 20.4
    var playing = false
    var review = Review.pending
    var blocks: [MockBlock]
    let titleID: UUID
    var sent: [MockMessage] = []
    var prompt = ""
    var selectedWords: Set<Int> = []
    var cutWords: Set<Int> = []
    var wordAnchor: Int?
    let settings = MockSettings()

    init() {
        let title = MockBlock(kind: .title, text: "Deploy in 60 seconds", start: 0, end: 4.5, center: CGPoint(x: 0.5, y: 0.4))
        blocks = [title]
        titleID = title.id
    }

    var agentOn: Bool { agent != .off }
    var zoomSpans: [MockSpan] { review == .accepted ? Self.zooms + [Self.suggestion] : Self.zooms }
    /// Only lanes with something on them (the take has a camera; captions are generated).
    var lanes: [MockLane] { [.camera, .graphics, .captions] }

    func zoom(at t: Double) -> MockSpan? { zoomSpans.first { t >= $0.start && t < $0.end } }

    func jump(to t: Double, select s: Selection = .none) {
        time = t; selection = s; lower = .timeline
    }

    /// A rail section leaves any element's settings, like ⌘digit in today's editor.
    func show(_ t: InspectorTab) { selection = .none; tab = t }

    func accept() { review = .accepted; selection = .zoom(2) }
    func reject() { review = .rejected; if selection == .suggestion { selection = .none } }

    /// Lab only: an external agent writes into the history while the chat may be closed.
    func simulateActivity(chatShown: Bool) {
        review = .pending
        if !chatShown { unread = true }
    }

    func add(_ kind: MockBlock.Kind) {
        let b = MockBlock(kind: kind, text: kind.sample, start: time, end: min(time + 4, Self.duration),
                          center: CGPoint(x: 0.5, y: kind == .title ? 0.4 : 0.6))
        blocks.append(b)
        selection = .block(b.id)
    }

    func send() {
        let text = prompt.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        sent.append(MockMessage(text: text)); prompt = ""
    }

    func tapWord(_ i: Int, extend: Bool) {
        if extend, let a = wordAnchor {
            selectedWords = Set(min(a, i)...max(a, i))
        } else if selectedWords == [i] {
            selectedWords = []; wordAnchor = nil
        } else {
            selectedWords = [i]; wordAnchor = i
        }
    }

    func cutSelection() {
        cutWords.formUnion(selectedWords); selectedWords = []; wordAnchor = nil
    }

    func cutFillers() {
        cutWords.formUnion(Self.paragraphs.flatMap(\.words).filter(\.filler).map(\.id))
    }

    static func timecode(_ t: Double, fraction: Bool = false) -> String {
        let s = Int(t), base = String(format: "%d:%02d", s / 60, s % 60)
        return fraction ? base + String(format: ".%02d", Int((t - Double(s)) * 100)) : base
    }

    private static func makeTranscript() -> [(time: Double, words: [MockWord])] {
        let script: [(Double, String)] = [
            (0, "Hi, ~um this is a quick look at how we deploy the app in under a minute."),
            (12.6, "First I open the project ~uh and check that the build is green."),
            (31.8, "Now the important part. I click Deploy and ~like the logs start streaming right away."),
            (70, "Here you can see each step, ~you ~know build, upload and switch."),
            (103, "And the terminal confirms it, version 2.4 is live. ~So that's it."),
        ]
        var n = 0
        return script.map { t, line in
            let words = line.split(separator: " ").map { raw -> MockWord in
                defer { n += 1 }
                let filler = raw.hasPrefix("~")
                return MockWord(id: n, text: filler ? String(raw.dropFirst()) : String(raw), filler: filler)
            }
            return (t, words)
        }
    }
}

// MARK: - Lab page

@MainActor enum DesignLabEditor {
    static let strip: CGFloat = 64
    static let sizes = [CGSize(width: 1280, height: 800), CGSize(width: 1728, height: 1080)]
    static let sizeTitles: [(id: Int, title: String)] = [(0, "13 inch"), (1, "Large")]

    /// Renders the states that matter to `<dir>/editor-*.png` (layout check only: offscreen renders have no live blur).
    static func snapshot(into dir: URL) async {
        var shots: [(String, CGSize, EditorMock)] = []
        for s in sizes {
            shots.append(("editor-off-\(Int(s.width))", s, EditorMock()))
            for (v, name) in [(EditorMock.Variant.open, "A"), (.auto, "B")] {
                let m = EditorMock(); m.agent = .on; m.variant = v
                shots.append(("editor-on-\(name)-\(Int(s.width))", s, m))
            }
        }
        let unconnected = EditorMock(); unconnected.agent = .unconnected
        shots.append(("editor-unconnected", sizes[0], unconnected))
        let unread = EditorMock(); unread.agent = .on; unread.chatOpen = false; unread.unread = true
        shots.append(("editor-on-collapsed-unread", sizes[0], unread))
        let selected = EditorMock(); selected.selection = .zoom(0)
        shots.append(("editor-zoom-selected", sizes[0], selected))
        for t in [InspectorTab.cursor, .audio, .cameraLayout, .extras] {
            let m = EditorMock(); m.tab = t
            shots.append(("editor-tab-\(t.rawValue)", sizes[1], m))
        }
        let transcript = EditorMock(); transcript.lower = .transcript; transcript.selectedWords = [14, 15, 16]
        shots.append(("editor-transcript", sizes[0], transcript))

        let hosts = shots.map { name, size, mock -> (String, NSView, NSWindow) in
            let host = NSHostingView(rootView: EditorMockView(mock: mock).frame(width: size.width, height: size.height).yapWindow())
            host.frame = CGRect(origin: .zero, size: size)
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host; w.orderFront(nil)
            return (name, host, w)
        }
        try? await Task.sleep(for: .seconds(1))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, host, w) in hosts {
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
            }
            w.orderOut(nil)
        }
    }
}

/// The Editor page lives in its own window: a real editor window (title bar buttons over the top bar, opaque
/// ground) at the chosen editor size, with the lab strip below. The glass lab window hides meanwhile; picking
/// another page in the strip brings it back.
@MainActor enum EditorLabWindow {
    private static var window: NSWindow?

    static func show(back: @escaping (String) -> Void) {
        let lab = NSApp.windows.first { $0.title == "Design Lab" }
        let w = window ?? make()
        window = w
        let host = NSHostingView(rootView: DesignLabEditorPage { page in
            w.orderOut(nil)
            lab?.makeKeyAndOrderFront(nil)
            back(page)
        }.yapWindow())
        // The top bar sits under the title bar; without a safe area nothing (scroll views) reaches up into it.
        host.safeAreaRegions = []
        w.contentView = host
        lab?.orderOut(nil)
        w.makeKeyAndOrderFront(nil)
    }

    private static func make() -> NSWindow {
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: DesignLabEditor.sizes[0]),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Design Lab · Editor"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // An empty unified toolbar gives the 52-pt title bar, so the window buttons sit centred in the top bar.
        w.toolbar = NSToolbar(identifier: "design-lab-editor")
        w.toolbarStyle = .unified
        w.applyYapChrome()
        w.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        return w
    }

    /// Sizes the window to the editor size plus the strip, clamped to the screen (the readout shows what fits).
    static func resize(to editor: CGSize) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        let w = min(editor.width, vis.width), h = min(editor.height + DesignLabEditor.strip, vis.height)
        window.setFrame(CGRect(x: vis.midX - w / 2, y: vis.midY - h / 2, width: w, height: h), display: true, animate: true)
    }
}

/// The page: the editor at window size, the lab strip (page switch, agent state, variant, size) below it.
struct DesignLabEditorPage: View {
    let switchPage: (String) -> Void
    @State private var mock = EditorMock()
    @State private var page = "editor"
    @State private var size = 0
    @State private var actual = CGSize.zero
    @State private var tones = false

    var body: some View {
        VStack(spacing: 0) {
            EditorMockView(mock: mock)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { actual = $0 }
            DockHairline(axis: .horizontal)
            strip
        }
        .overlay(alignment: .bottomTrailing) {
            if tones { TonePanel().padding(.trailing, 12).padding(.bottom, DesignLabEditor.strip + 8) }
        }
        .background(ToneTuning.shared.stageColor)
        .onAppear { EditorLabWindow.resize(to: DesignLabEditor.sizes[size]) }
        .onChange(of: size) { _, new in EditorLabWindow.resize(to: DesignLabEditor.sizes[new]) }
        .onChange(of: page) { _, new in if new != "editor" { switchPage(new); page = "editor" } }
        .onExitCommand { if mock.selection != .none { mock.selection = .none } else { NSApp.terminate(nil) } }
    }

    private var strip: some View {
        HStack(spacing: 12) {
            OptionRow(["toolbars", "kit", "editor"], selection: $page) { id, on in
                Text(id.capitalized).font(Yap.Font.label).foregroundStyle(on ? Yap.title : Yap.caption)
            }
            .frame(width: 270).padding(4)
            .glassPanel(radius: Yap.Radius.card + 4, floating: false, behindWindow: false)
            HStack(spacing: 4) {
                SegmentSwitch([(EditorMock.Agent.off, "Agent off"), (.on, "Agent on"), (.unconnected, "Not connected")], selection: $mock.agent)
                    .help("Agent and blocks are opt-in; off is the default")
                Button("New activity") { mock.simulateActivity(chatShown: mock.chatOpen || mock.chatOverlay) }
                    .buttonStyle(CapsuleButtonStyle(.secondary, height: 26)).disabled(mock.agent != .on)
                    .help("An external agent writes a suggestion; with the chat closed, its toggle brightens")
                separator
                SegmentSwitch([(EditorMock.Variant.open, "A Open"), (.auto, "B Auto-collapse")], selection: $mock.variant)
                    .help("How the chat behaves on a narrow window")
                separator
                SegmentSwitch(DesignLabEditor.sizeTitles, selection: $size)
                Text("\(Int(actual.width)) × \(Int(actual.height))").technical().frame(width: 84)
                    .help("Size of the editor in points")
            }
            .padding(.horizontal, 8).frame(height: 44)
            .glassPanel(radius: Yap.Grid.barRadius, floating: false, behindWindow: false)
            Spacer(minLength: 0)
            Button { tones.toggle() } label: { Label("Tones", systemImage: "slider.horizontal.3") }
                .buttonStyle(CapsuleButtonStyle(tones ? .primary : .secondary, height: 30))
                .help("Tune stage, columns and hairlines live")
        }
        .padding(.horizontal, 12)
        .frame(height: DesignLabEditor.strip)
    }

    private var separator: some View { DockHairline().frame(height: 24).padding(.horizontal, 4) }
}

/// A hairline between docked surfaces, at the tuned opacity.
struct DockHairline: View {
    var axis: Axis = .vertical
    var body: some View { Hairline(axis: axis, opacity: ToneTuning.shared.hairline) }
}

/// Live tones of the opaque editor (stage, columns, hairline, coolness), like the glass knobs; its values become
/// the defaults of `Yap.ground`, `Yap.dock` and `Yap.dockHairline`.
private struct TonePanel: View {
    @State private var t = ToneTuning.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tones").font(Yap.Font.title(17)).foregroundStyle(Yap.title)
            ValueSlider("Stage", value: t.hex(t.stage), amount: level(\.stage))
            ValueSlider("Columns", value: t.hex(t.dock), amount: level(\.dock))
            ValueSlider("Hairline", value: String(format: "%.0f %%", t.hairline * 100),
                        amount: Binding(get: { t.hairline / 0.3 }, set: { t.hairline = $0 * 0.3 }))
            ValueSlider("Cool", value: String(format: "+%.0f", t.cool * 255),
                        amount: Binding(get: { t.cool / (8 / 255) }, set: { t.cool = ($0 * 8).rounded() / 255 }))
            HStack {
                Button("Reset") { t.reset() }.buttonStyle(CapsuleButtonStyle(.secondary, height: 28))
                Spacer()
                Button("Copy values") {
                    let s = "stage \(t.hex(t.stage)), columns \(t.hex(t.dock)), hairline \(String(format: "%.2f", t.hairline))"
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
                }.buttonStyle(CapsuleButtonStyle(.secondary, height: 28))
            }
        }
        .padding(18)
        .frame(width: 320)
        .glassPanel(radius: Yap.Radius.panel, behindWindow: false, lift: 0.04)
    }

    /// Grey levels from black to 30 %, in whole steps of 1/255.
    private func level(_ key: ReferenceWritableKeyPath<ToneTuning, Double>) -> Binding<Double> {
        Binding(get: { t[keyPath: key] / 0.3 }, set: { t[keyPath: key] = ($0 * 0.3 * 255).rounded() / 255 })
    }
}

// MARK: - Editor

struct EditorMockView: View {
    @Bindable var mock: EditorMock
    static let chatWidth: CGFloat = 300
    static let inspectorWidth: CGFloat = InspectorColumn.railWidth + 300

    var body: some View {
        GeometryReader { geo in
            let narrow = mock.variant == .auto && geo.size.width < EditorMock.autoCollapseWidth
            VStack(spacing: 0) {
                EditorTopBar(mock: mock, narrow: narrow)
                DockHairline(axis: .horizontal)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            if mock.agentOn && !narrow && mock.chatOpen {
                                ChatColumn(mock: mock).frame(width: Self.chatWidth)
                                DockHairline()
                            }
                            PreviewArea(mock: mock)
                                .overlay(alignment: .topLeading) { overlayChat(narrow: narrow) }
                        }
                        DockHairline(axis: .horizontal)
                        TimelineArea(mock: mock)
                    }
                    DockHairline()
                    InspectorColumn(mock: mock).frame(width: Self.inspectorWidth)
                }
            }
        }
        .background(ToneTuning.shared.stageColor)
        .task(id: mock.playing) { await play() }
        .onChange(of: mock.chatOpen) { _, open in if open { mock.unread = false } }
        .onChange(of: mock.chatOverlay) { _, open in if open { mock.unread = false } }
    }

    /// Variant B on a narrow window: the chat floats over the stage instead of taking its width.
    @ViewBuilder private func overlayChat(narrow: Bool) -> some View {
        if mock.agentOn && narrow && mock.chatOverlay {
            ChatColumn(mock: mock, floating: true)
                .frame(width: Self.chatWidth)
                .padding(12)
                .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    private func play() async {
        while mock.playing {
            try? await Task.sleep(for: .milliseconds(33))
            mock.time += 0.033
            if mock.time >= EditorMock.duration { mock.time = 0; mock.playing = false }
        }
    }
}

// MARK: Top bar

/// Title bar row. Left: the agent toggle (off: a quiet way in; on: shows and hides the chat, brightening when
/// something new arrived) and the blocks toggle, then the project name. Right: Undo, Redo, the white Export capsule.
private struct EditorTopBar: View {
    @Bindable var mock: EditorMock
    let narrow: Bool

    var body: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: 72, height: 1).accessibilityHidden(true)   // the window's own buttons
            agentToggle
            SlotButton(symbol: "square.on.circle", label: "Blocks", help: mock.motion ? "Hide building blocks" : "Show building blocks: titles, callouts, spotlights, text",
                       active: mock.motion, compact: true) { withAnimation(Yap.Motion.select) { mock.motion.toggle() } }
            Text("Deploy walkthrough").font(Yap.Font.label).foregroundStyle(Yap.label).padding(.leading, 10)
            Text(EditorMock.timecode(EditorMock.duration)).technical().padding(.leading, 6)
            Spacer(minLength: 12)
            SlotButton(symbol: "arrow.uturn.backward", label: "Undo", active: false, compact: true) {}
            SlotButton(symbol: "arrow.uturn.forward", label: "Redo", active: false, compact: true) {}
            Button("Export") {}.buttonStyle(CapsuleButtonStyle(.primary, height: 30)).padding(.leading, 10)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(ToneTuning.shared.dockColor)
    }

    /// The unified title bar's height, so the window buttons sit centred in this row.
    static let height: CGFloat = 52

    private var chatShown: Bool { mock.agentOn && (narrow ? mock.chatOverlay : mock.chatOpen) }

    private var agentToggle: some View {
        let help = mock.agentOn ? (chatShown ? "Hide chat" : (mock.unread ? "Show chat: something new" : "Show chat"))
                                : "Edit with an agent (Claude Code, Codex)"
        return SlotButton(symbol: "sparkles", label: "Agent", help: help, active: chatShown, compact: true, attention: mock.unread && !chatShown) {
            withAnimation(Yap.Motion.select) {
                if !mock.agentOn { mock.agent = .on; if narrow { mock.chatOverlay = true } }
                else if narrow { mock.chatOverlay.toggle() }
                else { mock.chatOpen.toggle() }
            }
        }
    }
}

// MARK: - Chat

private struct ChatColumn: View {
    @Bindable var mock: EditorMock
    var floating = false

    var body: some View {
        Group {
            if mock.agent == .on { connected } else { ChatEmptyState(mock: mock) }
        }
        .frame(maxHeight: .infinity)
        .background { if floating { GlassSurface(radius: Yap.Grid.barRadius, behindWindow: false, lift: 0.04) } else { ToneTuning.shared.dockColor } }
    }

    private var connected: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat").font(Yap.Font.label).foregroundStyle(Yap.title)
                Text("Claude Code").font(Yap.Font.caption).foregroundStyle(Yap.faint)
                Spacer()
                SlotButton(symbol: "power", label: "Turn off agent", help: "Turn off the agent: no chat, no suggestions",
                           active: false, compact: true) { withAnimation(Yap.Motion.select) { mock.agent = .off } }
            }
            .padding(.leading, 16).padding(.trailing, 2).frame(height: Yap.Grid.cell + 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    UserBubble(text: "Tighten this")
                    ChangeList(mock: mock, title: "3 changes", rows: tightenRows)
                    suggestion
                    ForEach(mock.sent) { m in
                        UserBubble(text: m.text)
                        Text("Mock only: nothing changes in the lab.").font(Yap.Font.body).foregroundStyle(Yap.faint)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            ChatInput(mock: mock).padding(10)
        }
    }

    private var tightenRows: [ChangeItem] {
        [ChangeItem(symbol: "scissors", title: "Removed 2 pauses", time: 12.6, select: .clip(1)),
         ChangeItem(symbol: "plus.magnifyingglass", title: "Zoom on Deploy click", time: 40, select: .zoom(0)),
         ChangeItem(symbol: "textformat.size", title: "Chapter title", time: 0, select: .block(mock.titleID))]
    }

    /// An external agent (MCP) writes into the same history; its suggestion waits for accept or reject.
    private var suggestion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Code via MCP").font(Yap.Font.caption).foregroundStyle(Yap.faint).padding(.leading, 8)
            ChangeList(mock: mock, title: "1 suggestion",
                       rows: [ChangeItem(symbol: "plus.magnifyingglass", title: "Zoom on terminal output",
                                             time: EditorMock.suggestion.start, select: .suggestion)])
            ReviewButtons(mock: mock).padding(.leading, 8)
        }
    }
}

private struct UserBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text).font(Yap.Font.body).foregroundStyle(Yap.title)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.1)))
        }
    }
}

/// A short agent reply: the count as the headline, one row per change; a row jumps to its spot on the timeline.
private struct ChangeList: View {
    @Bindable var mock: EditorMock
    let title: String
    let rows: [ChangeItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Yap.title)
                .padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(rows) { r in
                ValueRow(symbol: r.symbol, title: r.title, value: EditorMock.timecode(r.time), help: "Show on the timeline") {
                    mock.jump(to: r.time, select: r.select)
                }
            }
        }
    }
}

/// One change in an agent reply; it points at a spot (and an element) on the timeline.
private struct ChangeItem: Identifiable {
    var id: String { title }
    let symbol: String
    let title: String
    let time: Double
    let select: EditorMock.Selection
}

struct ReviewButtons: View {
    @Bindable var mock: EditorMock
    var height: CGFloat = 26

    var body: some View {
        switch mock.review {
        case .pending:
            HStack(spacing: 6) {
                Button("Accept") { mock.accept() }
                    .buttonStyle(CapsuleButtonStyle(.secondary, height: height))
                Button("Reject") { mock.reject() }
                    .buttonStyle(CapsuleButtonStyle(.secondary, height: height))
            }
        case .accepted, .rejected:
            HStack(spacing: 8) {
                Text(mock.review == .accepted ? "Accepted" : "Rejected").font(Yap.Font.caption).foregroundStyle(Yap.faint)
                Button("Undo") { mock.review = .pending }.buttonStyle(.plain)
                    .font(Yap.Font.caption).foregroundStyle(Yap.caption)
            }
        }
    }
}

private struct ChatInput: View {
    @Bindable var mock: EditorMock
    var body: some View {
        RecessedField("Ask for a change", text: $mock.prompt) {
            Button(action: mock.send) { Image(systemName: "arrow.up") }
                .buttonStyle(CircleButtonStyle(active: !mock.prompt.isEmpty, size: 28))
                .help("Send").accessibilityLabel("Send")
        }
        .onSubmit(mock.send)
    }
}

/// Agent switched on, but none set up yet: one thought, one action.
private struct ChatEmptyState: View {
    @Bindable var mock: EditorMock
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 26, weight: .regular)).foregroundStyle(Yap.caption)
            Text("Edit by asking").font(.system(size: 15, weight: .semibold)).foregroundStyle(Yap.title)
            Text("Connect Claude Code or Codex. Its changes land here and on the timeline.")
                .font(Yap.Font.body).foregroundStyle(Yap.body).multilineTextAlignment(.center)
                .frame(maxWidth: 220)
            Button("Connect an agent") { mock.agent = .on }
                .buttonStyle(CapsuleButtonStyle(.secondary, height: 32)).padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

/// The stage: the preview large and centred with air around it; the blocks bar floats just under it.
private struct PreviewArea: View {
    @Bindable var mock: EditorMock
    static let air: CGFloat = 32
    static let barRoom: CGFloat = Yap.Grid.bar + 14

    var body: some View {
        GeometryReader { geo in
            let stage = fit(geo.size)
            VStack(spacing: 14) {
                PreviewStage(mock: mock, size: stage)
                    .frame(width: stage.width, height: stage.height)
                if mock.motion { BlocksBar(mock: mock).transition(.opacity.combined(with: .scale(scale: 0.96))) }
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background(Color.black.opacity(0.001).onTapGesture { mock.selection = .none })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 16:9 inside the room, with air around it and room for the blocks bar when it shows.
    private func fit(_ room: CGSize) -> CGSize {
        let w = max(room.width - 2 * Self.air, 10)
        let h = max(room.height - 2 * Self.air - (mock.motion ? Self.barRoom : 0), 10)
        return w / h > 16 / 9 ? CGSize(width: h * 16 / 9, height: h) : CGSize(width: w, height: w * 9 / 16)
    }
}

enum MockLook {
    static let graphics = Color(red: 0.96, green: 0.47, blue: 0.56)
    static let camera = Color(red: 0.36, green: 0.7, blue: 0.56)

    /// The background the inspector describes: wallpaper, gradient (from, to, hue, angle), colour, image or blur.
    @MainActor @ViewBuilder static func background(_ s: MockSettings) -> some View {
        switch s.choice("bg.mode", "Gradient") {
        case "Wallpaper":
            let w = MockGradients.wallpapers[Int(s.number("bg.wallpaper", 3))]
            LinearGradient(colors: w.2, startPoint: .topLeading, endPoint: .bottomTrailing)
        case "Color": s.color("bg.color", MockGradients.color(0x2E3440))
        case "Image":
            LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.44), Color(red: 0.12, green: 0.14, blue: 0.16)],
                           startPoint: .top, endPoint: .bottom)
        case "Blur": ScreenMock().blur(radius: 24 + s.number("bg.blur", 40) / 4).scaleEffect(1.2)
        default: gradient(s)
        }
    }

    @MainActor private static func gradient(_ s: MockSettings) -> some View {
        let a = s.number("bg.angle", 45) * .pi / 180
        let start = UnitPoint(x: 0.5 - cos(a) / 2, y: 0.5 - sin(a) / 2), end = UnitPoint(x: 0.5 + cos(a) / 2, y: 0.5 + sin(a) / 2)
        return LinearGradient(colors: [s.color("bg.from", MockGradients.color(0x4776E6)), s.color("bg.to", MockGradients.color(0x8E54E9))],
                              startPoint: start, endPoint: end)
            .hueRotation(.degrees(s.number("bg.hue", 0)))
    }
}

/// The composed frame: background, the recording with the inspector's look (zoomed where a zoom runs), the
/// camera, and the building blocks on top.
private struct PreviewStage: View {
    @Bindable var mock: EditorMock
    let size: CGSize

    var body: some View {
        let s = mock.settings, unit = size.width / 1920
        let inset = size.width * s.number("look.padding", 10) / 100
        let radius = s.number("look.radius", 16) * unit * 1.5
        let zoom = mock.zoom(at: mock.time)
        ZStack {
            MockLook.background(s)
                .onTapGesture { mock.selection = .none }
            ScreenMock(windowFrame: s.flag("look.windowFrame"))
                .scaleEffect(zoom?.scale ?? 1, anchor: zoom?.focus ?? .center)
                .animation(.smooth(duration: 0.5), value: zoom?.scale)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .shadow(color: .black.opacity(s.number("look.shadow", 0.3) * 1.6), radius: s.number("look.shadowSize", 24) * unit * 2,
                        y: s.number("look.shadowOffset", 8) * unit * 2)
                .padding(inset)
                .onTapGesture { mock.selection = .none }
            if s.flag("cam.show", true) { CameraBubble(s: s, stage: size) }
            ForEach($mock.blocks) { $block in
                if visible(block) { BlockView(mock: mock, block: $block, stage: size) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func visible(_ b: MockBlock) -> Bool {
        (mock.time >= b.start && mock.time < b.end) || mock.selection == .block(b.id)
    }
}

/// The speaker's camera, placed and shaped by Camera layout.
private struct CameraBubble: View {
    let s: MockSettings
    let stage: CGSize

    var body: some View {
        let side = stage.height * s.number("cam.size", 18) / 100 * 1.4
        let shape = s.choice("cam.shape", "Circle")
        let r = shape == "Circle" ? side / 2 : (shape == "Rounded" ? side * 0.22 : 0)
        let pos = s.choice("cam.position", "Bottom right")
        RoundedRectangle(cornerRadius: r, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.47, blue: 0.42), Color(red: 0.22, green: 0.2, blue: 0.2)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: "person.fill").font(.system(size: side * 0.5)).foregroundStyle(Color.white.opacity(0.35)).offset(y: side * 0.08))
            .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: Alignment(horizontal: pos.hasSuffix("left") ? .leading : .trailing, vertical: pos.hasPrefix("Top") ? .top : .bottom))
            .padding(stage.width * 0.03)
            .allowsHitTesting(false)
    }
}

/// A still that reads as a screen recording: an app window with a Deploy button, logs and a terminal.
struct ScreenMock: View {
    var windowFrame = false
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                Color(white: 0.11)
                if windowFrame { Color(white: 0.2).frame(height: h * 0.05) }
                Color(white: 0.15).frame(width: w * 0.2)
                sidebar(w, h)
                header(w, h)
                logs(w, h)
                terminal(w, h)
            }
        }
    }

    private func line(_ width: CGFloat, _ opacity: Double = 0.14) -> some View {
        Capsule().fill(Color.white.opacity(opacity)).frame(width: width, height: 5)
    }

    private func sidebar(_ w: CGFloat, _ h: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: h * 0.035) {
            ForEach(0..<7, id: \.self) { i in line(w * (i % 3 == 0 ? 0.12 : 0.09), i == 2 ? 0.4 : 0.14) }
        }
        .padding(.leading, w * 0.03).padding(.top, h * 0.1)
    }

    private func header(_ w: CGFloat, _ h: CGFloat) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) { line(w * 0.22, 0.5); line(w * 0.14) }
            Spacer()
            Capsule().fill(Color(red: 0.3, green: 0.74, blue: 0.5))
                .frame(width: w * 0.12, height: h * 0.075)
                .overlay(Text("Deploy").font(.system(size: max(h * 0.035, 6), weight: .semibold)).foregroundStyle(.white))
        }
        .padding(.leading, w * 0.24).padding(.trailing, w * 0.08).padding(.top, h * 0.08)
    }

    private func logs(_ w: CGFloat, _ h: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: h * 0.03) {
            ForEach(0..<6, id: \.self) { i in line(w * [0.4, 0.32, 0.46, 0.28, 0.38, 0.3][i]) }
        }
        .padding(.leading, w * 0.24).padding(.top, h * 0.3)
    }

    private func terminal(_ w: CGFloat, _ h: CGFloat) -> some View {
        let green = Color(red: 0.55, green: 0.85, blue: 0.6)
        return VStack(alignment: .leading, spacing: h * 0.03) {
            line(w * 0.2, 0.5).foregroundStyle(green)
            Capsule().fill(green.opacity(0.7)).frame(width: w * 0.26, height: 5)
            Capsule().fill(green.opacity(0.45)).frame(width: w * 0.16, height: 5)
        }
        .padding(w * 0.025)
        .frame(width: w * 0.36, height: h * 0.26, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.75)))
        .padding(.leading, w * 0.58).padding(.top, h * 0.68)
    }
}

/// A building block in the preview: drag to move, drag the corner to scale; a click selects it for the inspector.
private struct BlockView: View {
    @Bindable var mock: EditorMock
    @Binding var block: MockBlock
    let stage: CGSize
    @State private var dragStart: CGPoint?
    @State private var scaleStart: CGFloat?

    private var selected: Bool { mock.selection == .block(block.id) }
    private var unit: CGFloat { stage.width / 1000 }

    var body: some View {
        face
            .padding(8)
            .overlay { if selected { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.9), lineWidth: 1) } }
            .overlay(alignment: .bottomTrailing) { if selected { handle } }
            .contentShape(Rectangle())
            .position(x: block.center.x * stage.width, y: block.center.y * stage.height)
            .gesture(move)
            .onTapGesture { mock.selection = .block(block.id) }
    }

    @ViewBuilder private var face: some View {
        let s = block.scale * unit
        switch block.kind {
        case .title:
            Text(block.text).font(.system(size: 40 * s, weight: .bold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 12 * s)
        case .callout:
            Text(block.text).font(.system(size: 18 * s, weight: .semibold)).foregroundStyle(.black)
                .padding(.horizontal, 16 * s).padding(.vertical, 9 * s)
                .background(Capsule().fill(Color.white)).shadow(color: .black.opacity(0.3), radius: 10 * s)
        case .spotlight:
            Circle().strokeBorder(Color.white, lineWidth: 3 * s)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .frame(width: 140 * s, height: 140 * s)
                .shadow(color: .white.opacity(0.5), radius: 14 * s)
        case .text:
            Text(block.text).font(.system(size: 20 * s, weight: .medium)).foregroundStyle(.white)
        }
    }

    private var handle: some View {
        Circle().fill(Color.white).frame(width: 10, height: 10).offset(x: 5, y: 5)
            .gesture(DragGesture()
                .onChanged { g in
                    let s0 = scaleStart ?? block.scale
                    scaleStart = s0
                    block.scale = min(max(s0 + (g.translation.width + g.translation.height) / 300, 0.4), 3)
                }
                .onEnded { _ in scaleStart = nil })
            .help("Drag to scale")
    }

    private var move: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                let p0 = dragStart ?? block.center
                dragStart = p0
                mock.selection = .block(block.id)
                block.center = CGPoint(x: min(max(p0.x + g.translation.width / stage.width, 0), 1),
                                       y: min(max(p0.y + g.translation.height / stage.height, 0), 1))
            }
            .onEnded { _ in dragStart = nil }
    }
}

/// The small floating glass bar at the bottom of the preview: building blocks, no drawing tools.
private struct BlocksBar: View {
    @Bindable var mock: EditorMock
    var body: some View {
        HStack(spacing: 2) {
            ForEach(MockBlock.Kind.allCases, id: \.self) { k in
                SlotButton(symbol: k.symbol, label: k.label, help: "Add \(k.label.lowercased()) at the playhead", active: false) { mock.add(k) }
            }
        }
        .padding(.horizontal, Yap.Grid.inset)
        .frame(height: Yap.Grid.bar)
        .fixedSize()
        .glassPanel(radius: Yap.Grid.barRadius, behindWindow: false, sheen: true)
    }
}

