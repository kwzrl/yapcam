import AppKit
import SwiftUI
import YapcamDesign

// The design lab's "Editor" page: the agentic editor layout as a mock-up (no engine, no project).
// Chat column on the left, contextual inspector on the right, building blocks over the preview,
// Timeline / Transcript below. One finished look; the variants differ only in the two open questions:
// how the chat behaves on a narrow window (A always open, B auto-collapse) and what it shows without an agent.

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
    enum Agent: Hashable { case connected, collapsed, empty }
    enum Lower: Hashable { case timeline, transcript }
    enum Selection: Hashable { case none, clip(Int), zoom(Int), suggestion, block(UUID) }
    enum Review { case pending, accepted, rejected }

    static let duration: Double = 134
    /// Variant B hides the chat column below this window width; opening it then floats it over the preview.
    static let autoCollapseWidth: CGFloat = 1500

    static let clips = [MockSpan(start: 0, end: 12.6), MockSpan(start: 12.6, end: 31.8),
                        MockSpan(start: 31.8, end: 88), MockSpan(start: 88, end: 134)]
    static let zooms = [MockSpan(start: 40, end: 47, title: "Deploy click", scale: 2.0, focus: UnitPoint(x: 0.74, y: 0.24)),
                        MockSpan(start: 70, end: 78, title: "Logs", scale: 1.6, focus: UnitPoint(x: 0.5, y: 0.62))]
    static let suggestion = MockSpan(start: 103, end: 110, title: "Terminal output", scale: 1.8, focus: UnitPoint(x: 0.78, y: 0.8))
    static let markers: [Double] = [42, 95]
    static let captions: [MockSpan] = stride(from: 1.0, to: 130, by: 4.3).map { MockSpan(start: $0, end: $0 + 3.7) }
    static let paragraphs = makeTranscript()

    var variant = Variant.open
    var agent = Agent.connected { didSet { chatOpen = agent != .collapsed; chatOverlay = false } }
    var chatOpen = true
    var chatOverlay = false
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
    // Look
    var background = 0
    var padding = 0.08
    var corners = 0.4

    init() {
        let title = MockBlock(kind: .title, text: "Deploy in 60 seconds", start: 0, end: 4.5, center: CGPoint(x: 0.5, y: 0.4))
        blocks = [title]
        titleID = title.id
    }

    var zoomSpans: [MockSpan] { review == .accepted ? Self.zooms + [Self.suggestion] : Self.zooms }

    func zoom(at t: Double) -> MockSpan? { zoomSpans.first { t >= $0.start && t < $0.end } }

    func jump(to t: Double, select s: Selection = .none) {
        time = t; selection = s; lower = .timeline
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

    /// Renders every variant at both sizes, plus the two no-agent states, to `<dir>/editor-*.png`
    /// (layout check only: offscreen renders have no live blur).
    static func snapshot(into dir: URL) async {
        var shots: [(String, CGSize, EditorMock)] = []
        for (v, name) in [(EditorMock.Variant.open, "A"), (.auto, "B")] {
            for s in sizes {
                let m = EditorMock(); m.variant = v
                shots.append(("editor-\(name)-\(Int(s.width))", s, m))
            }
        }
        for (a, name) in [(EditorMock.Agent.collapsed, "collapsed"), (.empty, "empty")] {
            let m = EditorMock(); m.agent = a
            shots.append(("editor-noagent-\(name)", sizes[0], m))
        }
        let selected = EditorMock(); selected.selection = .zoom(0)
        shots.append(("editor-zoom-selected", sizes[0], selected))
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
        window = w
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

/// The page: the editor at window size, the lab strip (page switch, variant, size, agent state) below it.
struct DesignLabEditorPage: View {
    let switchPage: (String) -> Void
    @State private var mock = EditorMock()
    @State private var page = "editor"
    @State private var size = 0
    @State private var actual = CGSize.zero

    var body: some View {
        VStack(spacing: 0) {
            EditorMockView(mock: mock)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { actual = $0 }
            Hairline(axis: .horizontal)
            strip
        }
        .background(Yap.ground)
        .onAppear { EditorLabWindow.resize(to: DesignLabEditor.sizes[size]) }
        .onChange(of: size) { _, new in EditorLabWindow.resize(to: DesignLabEditor.sizes[new]) }
        .onChange(of: page) { _, new in if new != "editor" { switchPage(new); page = "editor" } }
        .onExitCommand { NSApp.terminate(nil) }
    }

    private var strip: some View {
        HStack(spacing: 12) {
            OptionRow(["toolbars", "kit", "editor"], selection: $page) { id, on in
                Text(id.capitalized).font(Yap.Font.label).foregroundStyle(on ? Yap.title : Yap.caption)
            }
            .frame(width: 300).padding(4)
            .glassPanel(radius: Yap.Radius.card + 4, floating: false, behindWindow: false)
            HStack(spacing: 4) {
                SegmentSwitch([(EditorMock.Variant.open, "A Always open"), (.auto, "B Auto-collapse")], selection: $mock.variant)
                    .help("How the chat behaves on a narrow window")
                separator
                SegmentSwitch(DesignLabEditor.sizeTitles, selection: $size)
                Text("\(Int(actual.width)) × \(Int(actual.height))").technical().frame(width: 92)
                    .help("Size of the editor in points")
                separator
                SegmentSwitch([(EditorMock.Agent.connected, "Agent on"), (.collapsed, "Off: collapsed"), (.empty, "Off: empty")],
                              selection: $mock.agent)
                    .help("What the chat shows when no agent is set up")
            }
            .padding(.horizontal, 8).frame(height: 44)
            .glassPanel(radius: Yap.Grid.barRadius, floating: false, behindWindow: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: DesignLabEditor.strip)
    }

    private var separator: some View { Hairline().frame(height: 24).padding(.horizontal, 4) }
}

// MARK: - Editor

struct EditorMockView: View {
    @Bindable var mock: EditorMock
    static let gutter = Yap.Grid.inset
    static let chatWidth: CGFloat = 300
    static let inspectorWidth: CGFloat = 280

    var body: some View {
        GeometryReader { geo in
            let narrow = mock.variant == .auto && geo.size.width < EditorMock.autoCollapseWidth
            VStack(spacing: 0) {
                EditorTopBar(mock: mock, narrow: narrow)
                content(narrow: narrow)
                    .padding([.horizontal, .bottom], Self.gutter)
                    .overlay(alignment: .leading) { overlayChat(narrow: narrow) }
            }
        }
        .background(Yap.ground)
        .task(id: mock.playing) { await play() }
    }

    private func content(narrow: Bool) -> some View {
        HStack(spacing: Self.gutter) {
            if !narrow && mock.chatOpen { ChatColumn(mock: mock).frame(width: Self.chatWidth) }
            VStack(spacing: Self.gutter) {
                PreviewArea(mock: mock)
                TimelinePanel(mock: mock)
            }
            InspectorColumn(mock: mock).frame(width: Self.inspectorWidth)
        }
    }

    /// Variant B on a narrow window: the chat floats over the preview instead of taking its width.
    @ViewBuilder private func overlayChat(narrow: Bool) -> some View {
        if narrow && mock.chatOverlay {
            ChatColumn(mock: mock, floating: true)
                .frame(width: Self.chatWidth)
                .padding(.leading, Self.gutter * 2).padding(.vertical, Self.gutter * 2)
                .padding(.bottom, TimelinePanel.height)
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

/// Title bar row: chat toggle and project name on the left; Undo, Redo and the one white Export capsule on the right.
private struct EditorTopBar: View {
    @Bindable var mock: EditorMock
    let narrow: Bool

    var body: some View {
        HStack(spacing: 2) {
            trafficLights
            SlotButton(symbol: "sidebar.left", label: chatShown ? "Hide chat" : "Show chat", active: chatShown, compact: true) {
                withAnimation(Yap.Motion.select) { narrow ? mock.chatOverlay.toggle() : mock.chatOpen.toggle() }
            }
            Text("Deploy walkthrough").font(Yap.Font.label).foregroundStyle(Yap.label).padding(.leading, 8)
            Text(EditorMock.timecode(EditorMock.duration)).technical().padding(.leading, 6)
            Spacer(minLength: 12)
            SlotButton(symbol: "arrow.uturn.backward", label: "Undo", active: false, compact: true) {}
            SlotButton(symbol: "arrow.uturn.forward", label: "Redo", active: false, compact: true) {}
            Button("Export") {}.buttonStyle(CapsuleButtonStyle(.primary, height: 30)).padding(.leading, 10)
        }
        .padding(.horizontal, 12)
        .frame(height: Yap.Grid.bar)
    }

    private var chatShown: Bool { narrow ? mock.chatOverlay : mock.chatOpen }

    /// Room for the window's own close, minimise and zoom buttons.
    private var trafficLights: some View {
        Color.clear.frame(width: 72, height: 1).accessibilityHidden(true)
    }
}

// MARK: - Chat

private struct ChatColumn: View {
    @Bindable var mock: EditorMock
    var floating = false

    var body: some View {
        Group {
            if mock.agent == .connected { connected } else { ChatEmptyState(mock: mock) }
        }
        .frame(maxHeight: .infinity)
        .columnPanel(floating: floating)
    }

    private var connected: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat").font(Yap.Font.label).foregroundStyle(Yap.title)
                Spacer()
                Text("Claude Code").font(Yap.Font.caption).foregroundStyle(Yap.faint)
            }
            .padding(.horizontal, 16).frame(height: 44)
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

private struct ReviewButtons: View {
    @Bindable var mock: EditorMock
    var height: CGFloat = 26

    var body: some View {
        switch mock.review {
        case .pending:
            HStack(spacing: 6) {
                Button("Accept") { mock.review = .accepted; mock.selection = .zoom(2) }
                    .buttonStyle(CapsuleButtonStyle(.secondary, height: height))
                Button("Reject") { mock.review = .rejected; mock.selection = .none }
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

/// No agent set up: one thought, one action.
private struct ChatEmptyState: View {
    @Bindable var mock: EditorMock
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 26, weight: .regular)).foregroundStyle(Yap.caption)
            Text("Edit by asking").font(.system(size: 15, weight: .semibold)).foregroundStyle(Yap.title)
            Text("Connect Claude Code or Codex. Its changes land here and on the timeline.")
                .font(Yap.Font.body).foregroundStyle(Yap.body).multilineTextAlignment(.center)
                .frame(maxWidth: 220)
            Button("Connect an agent") { mock.agent = .connected }
                .buttonStyle(CapsuleButtonStyle(.secondary, height: 32)).padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

private struct PreviewArea: View {
    @Bindable var mock: EditorMock
    var body: some View {
        GeometryReader { geo in
            let stage = fit(geo.size)
            PreviewStage(mock: mock, size: stage)
                .frame(width: stage.width, height: stage.height)
                .overlay(alignment: .bottom) { BlocksBar(mock: mock).padding(.bottom, 14) }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background(Color.black.opacity(0.001).onTapGesture { mock.selection = .none })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 16:9 inside the room, with a little air around it.
    private func fit(_ room: CGSize) -> CGSize {
        let w = max(room.width - 24, 10), h = max(room.height - 24, 10)
        return w / h > 16 / 9 ? CGSize(width: h * 16 / 9, height: h) : CGSize(width: w, height: w * 9 / 16)
    }
}

private enum MockLook {
    static let backgrounds: [[Color]] = [
        [Color(red: 0.36, green: 0.22, blue: 0.55), Color(red: 0.93, green: 0.48, blue: 0.36)],
        [Color(red: 0.98, green: 0.78, blue: 0.35), Color(red: 0.89, green: 0.42, blue: 0.25)],
        [Color(red: 0.16, green: 0.42, blue: 0.36), Color(red: 0.62, green: 0.78, blue: 0.45)],
        [Color(white: 0.28), Color(white: 0.08)],
        [Color(red: 0.85, green: 0.42, blue: 0.62), Color(red: 0.35, green: 0.18, blue: 0.42)],
    ]
    static func gradient(_ i: Int) -> LinearGradient {
        LinearGradient(colors: backgrounds[i], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static let graphics = Color(red: 0.96, green: 0.47, blue: 0.56)
}

/// The composed frame: background, the recording (zoomed where a zoom runs), the building blocks on top.
private struct PreviewStage: View {
    @Bindable var mock: EditorMock
    let size: CGSize

    var body: some View {
        let inset = size.width * mock.padding
        let zoom = mock.zoom(at: mock.time)
        ZStack {
            MockLook.gradient(mock.background)
                .onTapGesture { mock.selection = .none }
            ScreenMock()
                .scaleEffect(zoom?.scale ?? 1, anchor: zoom?.focus ?? .center)
                .animation(.smooth(duration: 0.5), value: zoom?.scale)
                .clipShape(RoundedRectangle(cornerRadius: 4 + mock.corners * 24, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
                .padding(inset)
                .onTapGesture { mock.selection = .none }
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

/// A still that reads as a screen recording: an app window with a Deploy button, logs and a terminal.
private struct ScreenMock: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                Color(white: 0.11)
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
            Capsule().fill(Color(red: 0.98, green: 0.84, blue: 0.18))
                .frame(width: w * 0.12, height: h * 0.075)
                .overlay(Text("Deploy").font(.system(size: max(h * 0.035, 6), weight: .semibold)).foregroundStyle(.black))
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

// MARK: - Timeline panel

private struct TimelinePanel: View {
    static let height: CGFloat = 238
    @Bindable var mock: EditorMock

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if mock.lower == .timeline { TimelineTracks(mock: mock) } else { TranscriptView(mock: mock) }
            }
            .frame(maxHeight: .infinity)
            Hairline(axis: .horizontal)
            bottomBar
        }
        .frame(height: Self.height)
        .columnPanel()
    }

    private var bottomBar: some View {
        ZStack {
            HStack {
                SegmentSwitch([(EditorMock.Lower.timeline, "Timeline"), (.transcript, "Transcript")], selection: $mock.lower)
                Spacer()
                if mock.lower == .transcript && !mock.selectedWords.isEmpty {
                    Button("Cut \(mock.selectedWords.count) words") { mock.cutSelection() }
                        .buttonStyle(CapsuleButtonStyle(.secondary, height: 26))
                }
            }
            transport
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button { mock.playing.toggle() } label: { Image(systemName: mock.playing ? "pause.fill" : "play.fill") }
                .buttonStyle(CircleButtonStyle(size: 30))
                .accessibilityLabel(mock.playing ? "Pause" : "Play")
            HStack(spacing: 4) {
                Text(EditorMock.timecode(mock.time, fraction: true)).technical()
                Text("/ " + EditorMock.timecode(EditorMock.duration, fraction: true)).font(Yap.Font.technical).foregroundStyle(Yap.faint)
            }
        }
    }
}

/// Ruler with markers, then only the tracks that hold something: Video, Zoom, Graphics, Captions and the
/// recorded Audio (no camera in this take, so no Camera track).
private struct TimelineTracks: View {
    @Bindable var mock: EditorMock
    static let lane: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let px = geo.size.width / EditorMock.duration
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Ruler(mock: mock, px: px)
                    VideoLane(mock: mock, px: px)
                    ZoomLane(mock: mock, px: px)
                    GraphicsLane(mock: mock, px: px)
                    CaptionLane(px: px)
                    AudioLane().frame(height: Self.lane)
                }
                Rectangle().fill(Color.white).frame(width: 1.5).offset(x: mock.time * px)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
    }
}

/// Timecodes along the top (yellow), markers on it; click or drag to move the playhead.
private struct Ruler: View {
    @Bindable var mock: EditorMock
    let px: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(stride(from: 0.0, to: EditorMock.duration, by: 15)), id: \.self) { t in
                Text(EditorMock.timecode(t)).font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Yap.technical.opacity(0.75)).offset(x: t * px + 3)
                Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 6).offset(x: t * px, y: 14)
            }
            ForEach(EditorMock.markers, id: \.self) { m in
                Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(Yap.label)
                    .offset(x: m * px - 2, y: 10).help("Marker at \(EditorMock.timecode(m))")
            }
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            mock.time = min(max(g.location.x / px, 0), EditorMock.duration)
        })
    }
}

/// One item on a lane: content colour, white outline when selected, dashed while only suggested.
private struct LaneItem: View {
    let start: Double
    let end: Double
    let px: CGFloat
    let fill: AnyShapeStyle
    var label = ""
    var labelColor = Color.white
    var selected = false
    var dashed = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let width = max((end - start) * px - 2, 3)
        shape.fill(fill)
            .overlay { if dashed { shape.strokeBorder(Yap.zoom, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) } }
            .overlay { if selected { shape.strokeBorder(Color.white, lineWidth: 2) } }
            .overlay(alignment: .leading) {
                // Only where it fits: a cut-off label reads as noise.
                if width >= CGFloat(label.count) * 6 + 12 { labelText }
            }
            .brightness(hover ? 0.08 : 0)
            .frame(width: width, height: TimelineTracks.lane)
            .clipShape(shape)
            .offset(x: start * px + 1)
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
            .help(label)
    }

    private var labelText: some View {
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(labelColor)
                    .lineLimit(1).padding(.horizontal, 6)
    }
}

private struct Lane<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ZStack(alignment: .leading) { content }
            .frame(maxWidth: .infinity, minHeight: TimelineTracks.lane, maxHeight: TimelineTracks.lane, alignment: .leading)
    }
}

private struct VideoLane: View {
    @Bindable var mock: EditorMock
    let px: CGFloat
    var body: some View {
        Lane {
            ForEach(Array(EditorMock.clips.enumerated()), id: \.offset) { i, c in
                LaneItem(start: c.start, end: c.end, px: px,
                         fill: AnyShapeStyle(LinearGradient(colors: [Yap.clipTop, Yap.clipBottom], startPoint: .top, endPoint: .bottom)),
                         label: "Clip \(i + 1)", labelColor: .black.opacity(0.7), selected: mock.selection == .clip(i)) {
                    mock.jump(to: c.start, select: .clip(i))
                }
            }
        }
    }
}

private struct ZoomLane: View {
    @Bindable var mock: EditorMock
    let px: CGFloat
    var body: some View {
        Lane {
            ForEach(Array(mock.zoomSpans.enumerated()), id: \.offset) { i, z in
                LaneItem(start: z.start, end: z.end, px: px, fill: AnyShapeStyle(Yap.zoom),
                         label: String(format: "%.1f×", z.scale), selected: mock.selection == .zoom(i)) {
                    mock.jump(to: z.start, select: .zoom(i))
                }
            }
            if mock.review == .pending { suggestion }
        }
    }

    /// The agent's suggestion lies dashed on its track; accept or reject right beside it.
    private var suggestion: some View {
        let s = EditorMock.suggestion
        return HStack(spacing: 4) {
            LaneItem(start: 0, end: s.end - s.start, px: px, fill: AnyShapeStyle(Yap.zoom.opacity(0.18)),
                     label: String(format: "%.1f×", s.scale), labelColor: Yap.label,
                     selected: mock.selection == .suggestion, dashed: true) { mock.jump(to: s.start, select: .suggestion) }
            mini("checkmark", "Accept suggestion") { mock.review = .accepted; mock.selection = .zoom(2) }
            mini("xmark", "Reject suggestion") { mock.review = .rejected; mock.selection = .none }
        }
        .offset(x: s.start * px)
    }

    private func mini(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(CircleButtonStyle(size: 20))
            .help(label).accessibilityLabel(label)
    }
}

private struct GraphicsLane: View {
    @Bindable var mock: EditorMock
    let px: CGFloat
    var body: some View {
        Lane {
            ForEach(mock.blocks) { b in
                LaneItem(start: b.start, end: b.end, px: px, fill: AnyShapeStyle(MockLook.graphics),
                         label: b.kind.label, selected: mock.selection == .block(b.id)) {
                    mock.jump(to: b.start, select: .block(b.id))
                }
            }
        }
    }
}

private struct CaptionLane: View {
    let px: CGFloat
    var body: some View {
        Lane {
            ForEach(Array(EditorMock.captions.enumerated()), id: \.offset) { _, c in
                LaneItem(start: c.start, end: c.end, px: px, fill: AnyShapeStyle(Color.white.opacity(0.16))) {}
            }
        }
    }
}

private struct AudioLane: View {
    var body: some View {
        Canvas { ctx, size in
            let bars = Int(size.width / 3)
            for i in 0..<max(bars, 1) {
                let h = max(size.height * Self.level(Double(i)), 2)
                let r = CGRect(x: CGFloat(i) * 3, y: (size.height - h) / 2, width: 1.5, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: 0.75), with: .color(.white.opacity(0.35)))
            }
        }
        .help("Audio")
    }

    private static func level(_ x: Double) -> CGFloat {
        let slow = sin(x * 0.37) * 0.6, swell = sin(x * 0.11 + 1) * 0.3, grain = sin(x * 1.7) * 0.1
        return CGFloat(abs(slow + swell + grain))
    }
}

// MARK: Transcript

/// The second view of the timeline: select words and press Delete to cut; filler words are dotted.
private struct TranscriptView: View {
    @Bindable var mock: EditorMock
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(EditorMock.paragraphs, id: \.time) { p in paragraph(p.time, p.words) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .scrollIndicators(.never)
        .focusable().focusEffectDisabled().focused($focused)
        .onDeleteCommand { mock.cutSelection() }
        .onAppear { focused = true }
    }

    private func paragraph(_ t: Double, _ words: [MockWord]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button { mock.jump(to: t) } label: { Text(EditorMock.timecode(t)).technical() }
                .buttonStyle(.plain).frame(width: 36, alignment: .leading)
            FlowLayout {
                ForEach(words) { w in WordChip(mock: mock, word: w) }
            }
        }
    }
}

private struct WordChip: View {
    @Bindable var mock: EditorMock
    let word: MockWord
    @State private var hover = false

    var body: some View {
        let selected = mock.selectedWords.contains(word.id), cut = mock.cutWords.contains(word.id)
        Text(word.text)
            .font(.system(size: 14))
            .foregroundStyle(cut ? Yap.faint : (word.filler ? Yap.caption : Yap.label))
            .strikethrough(cut, color: Yap.faint)
            .underline(word.filler && !cut, pattern: .dot, color: Yap.caption)
            .padding(.horizontal, 2).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.24 : (hover ? 0.08 : 0))))
            .onHover { hover = $0 }
            .onTapGesture { mock.tapWord(word.id, extend: NSEvent.modifierFlags.contains(.shift)) }
            .help(word.filler ? "Filler word" : "")
    }
}

/// Lays words out in lines like text.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? 600, subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews)
        for (v, p) in zip(subviews, rows.points) {
            v.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + lineSpacing; line = 0 }
            points.append(CGPoint(x: x, y: y))
            x += s.width + spacing; widest = max(widest, x); line = max(line, s.height)
        }
        return (points, widest, y + line)
    }
}

// MARK: - Inspector

/// One panel, no icon bar: Look without a selection, otherwise only what the selected element has.
private struct InspectorColumn: View {
    @Bindable var mock: EditorMock

    var body: some View {
        ScrollView {
            content.padding(.horizontal, 10).padding(.bottom, 14)
        }
        .scrollIndicators(.never)
        .id(mock.selection)
        .frame(maxHeight: .infinity)
        .columnPanel()
    }

    @ViewBuilder private var content: some View {
        switch mock.selection {
        case .none: LookInspector(mock: mock)
        case .clip(let i): ClipInspector(mock: mock, index: i)
        case .zoom(let i): ZoomInspector(mock: mock, span: mock.zoomSpans[min(i, mock.zoomSpans.count - 1)])
        case .suggestion: SuggestionInspector(mock: mock)
        case .block(let id):
            if let i = mock.blocks.firstIndex(where: { $0.id == id }) { BlockInspector(mock: mock, block: $mock.blocks[i]) }
        }
    }
}

private struct InspectorHeader: View {
    @Bindable var mock: EditorMock
    let title: String
    var detail = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Yap.title)
            if !detail.isEmpty { Text(detail).technical() }
            Spacer(minLength: 0)
            if mock.selection != .none {
                SlotButton(symbol: "xmark", label: "Back to Look", active: false, compact: true) { mock.selection = .none }
            }
        }
        .padding(.leading, 8).frame(height: 44)
    }
}

private struct LookInspector: View {
    @Bindable var mock: EditorMock
    @State private var open: Set<String> = ["Background", "Frame"]
    @State private var shadow = 0.5
    @State private var format = "16:9"
    @State private var cursor = 0.4
    @State private var smooth = "On"
    @State private var volume = 0.8
    @State private var keys = "Off"
    @State private var preset = "Default"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            InspectorHeader(mock: mock, title: "Look")
            section("Background", value: "") { swatches }
            section("Frame", value: format) { frame }
            section("Cursor", value: String(format: "%.1f×", 1 + cursor * 2)) { cursorControls }
            section("Camera", value: "None") {
                Text("This take has no camera.").font(Yap.Font.body).foregroundStyle(Yap.faint)
            }
            section("Audio", value: String(format: "%.0f %%", volume * 100)) {
                ValueSlider("Volume", value: String(format: "%.0f %%", volume * 100), amount: $volume)
            }
            section("Key overlay", value: keys) {
                SegmentSwitch([("Off", "Off"), ("Shortcuts", "Shortcuts"), ("All", "All keys")], selection: $keys, height: 26)
            }
            section("Presets", value: preset, last: true) { presets }
        }
    }

    private func section<C: View>(_ title: String, value: String, last: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 4) {
            DisclosureSection(title, value: value, open: Binding(get: { open.contains(title) },
                                                                 set: { if $0 { open.insert(title) } else { open.remove(title) } })) {
                VStack(alignment: .leading, spacing: 14) { content() }
            }
            if !last { Hairline(axis: .horizontal).padding(.horizontal, 8) }
        }
    }

    private var swatches: some View {
        HStack(spacing: 8) {
            ForEach(MockLook.backgrounds.indices, id: \.self) { i in
                let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
                Button { mock.background = i } label: {
                    MockLook.gradient(i).clipShape(shape)
                        .overlay { if mock.background == i { shape.strokeBorder(Color.white, lineWidth: 2) } }
                        .frame(width: 38, height: 28)
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Background \(i + 1)")
                .accessibilityAddTraits(mock.background == i ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var frame: some View {
        ValueSlider("Padding", value: String(format: "%.0f %%", mock.padding * 100),
                    amount: Binding(get: { mock.padding / 0.2 }, set: { mock.padding = $0 * 0.2 }))
        ValueSlider("Corners", value: String(format: "%.0f pt", 4 + mock.corners * 24), amount: $mock.corners)
        ValueSlider("Shadow", value: String(format: "%.0f %%", shadow * 100), amount: $shadow)
        ValueChoice("Format", items: [("16:9", "16:9"), ("4:3", "4:3"), ("1:1", "1:1"), ("9:16", "9:16")], selection: $format)
    }

    @ViewBuilder private var cursorControls: some View {
        ValueSlider("Size", value: String(format: "%.1f×", 1 + cursor * 2), amount: $cursor)
        ValueChoice("Smooth movement", items: [("Off", "Off"), ("On", "On")], selection: $smooth)
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 12) {
            SegmentSwitch([("Default", "Default"), ("Tutorial", "Tutorial"), ("Minimal", "Minimal")], selection: $preset, height: 26)
            Button("Save as preset") {}.buttonStyle(CapsuleButtonStyle(.secondary, height: 28))
        }
    }
}

private struct ZoomInspector: View {
    @Bindable var mock: EditorMock
    let span: MockSpan
    @State private var scale = 0.33
    @State private var focus = "cursor"
    @State private var ease = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            InspectorHeader(mock: mock, title: "Zoom", detail: "\(EditorMock.timecode(span.start)) – \(EditorMock.timecode(span.end))")
            Group {
                ValueSlider("Scale", value: String(format: "%.1f×", 1 + scale * 3), amount: $scale)
                ValueChoice("Focus", items: [("cursor", "Follow cursor"), ("fixed", "Fixed point")], selection: $focus)
                ValueSlider("Ease", value: String(format: "%.1f s", 0.2 + ease), amount: $ease)
                Button("Delete zoom") {}.buttonStyle(CapsuleButtonStyle(.secondary, height: 28))
            }
            .padding(.horizontal, 8)
        }
        .onAppear { scale = (span.scale - 1) / 3 }
    }
}

private struct SuggestionInspector: View {
    @Bindable var mock: EditorMock
    @State private var scale = (EditorMock.suggestion.scale - 1) / 3

    var body: some View {
        let s = EditorMock.suggestion
        VStack(alignment: .leading, spacing: 16) {
            InspectorHeader(mock: mock, title: "Suggested zoom", detail: "\(EditorMock.timecode(s.start)) – \(EditorMock.timecode(s.end))")
            Group {
                Text("From Claude Code: zoom on the terminal output.").font(Yap.Font.body).foregroundStyle(Yap.body)
                ValueSlider("Scale", value: String(format: "%.1f×", 1 + scale * 3), amount: $scale)
                ReviewButtons(mock: mock, height: 28)
            }
            .padding(.horizontal, 8)
        }
    }
}

private struct ClipInspector: View {
    @Bindable var mock: EditorMock
    let index: Int
    @State private var speed = 0.25
    @State private var volume = 1.0

    var body: some View {
        let c = EditorMock.clips[index]
        VStack(alignment: .leading, spacing: 16) {
            InspectorHeader(mock: mock, title: "Clip \(index + 1)", detail: "\(EditorMock.timecode(c.start)) – \(EditorMock.timecode(c.end))")
            Group {
                ValueSlider("Speed", value: String(format: "%.2g×", 0.5 + speed * 2), amount: $speed)
                ValueSlider("Volume", value: String(format: "%.0f %%", volume * 100), amount: $volume)
                Button("Split at playhead") {}.buttonStyle(CapsuleButtonStyle(.secondary, height: 28))
            }
            .padding(.horizontal, 8)
        }
    }
}

private struct BlockInspector: View {
    @Bindable var mock: EditorMock
    @Binding var block: MockBlock
    @State private var style = "Bold"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            InspectorHeader(mock: mock, title: block.kind.label, detail: String(format: "%.1f s", block.end - block.start))
            Group {
                if block.kind != .spotlight {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Text").font(Yap.Font.body).foregroundStyle(Yap.label)
                        RecessedField("Text", text: $block.text, height: 32)
                    }
                }
                ValueChoice("Style", items: [("Bold", "Bold"), ("Quiet", "Quiet"), ("Outline", "Outline")], selection: $style)
                ValueSlider("Size", value: String(format: "%.0f %%", block.scale * 100),
                            amount: Binding(get: { (block.scale - 0.4) / 2.6 }, set: { block.scale = 0.4 + $0 * 2.6 }))
                Text("Drag it in the preview to move it.").font(Yap.Font.caption).foregroundStyle(Yap.faint)
            }
            .padding(.horizontal, 8)
        }
    }
}
