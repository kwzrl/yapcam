import AppKit
import SwiftUI
import YapcamDesign

// The docked bottom panel of the editor (approved lab look, 2026-10-17): a 40-pt head row (transport, tools, the
// Timeline / Transcript switch), then the timeline or the transcript of the same edit. On `Yap.dock`, a hairline on
// top, no card, no corners, no shadow. The window places it from the left edge to the inspector.

/// Bottom slot of the editor window: switches between the timeline and the transcript on `model.bottomPanel`.
public struct BottomPanelView: View {
    @ObservedObject var model: EditorModel
    var topHairline: Bool
    @State private var transcriptSelection = Set<String>()

    /// `topHairline`: the 1-px separator from the stage above; pass false when the window draws it itself.
    public init(model: EditorModel, topHairline: Bool = true) {
        self.model = model; self.topHairline = topHairline
    }

    public var body: some View {
        VStack(spacing: 0) {
            if topHairline { Hairline(axis: .horizontal, opacity: Yap.dockHairline) }
            TransportBar(model: model, transcriptSelection: $transcriptSelection)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Yap.dock)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch model.bottomPanel {
        case .timeline: TimelineView(model: model)
        case .transcript: TranscriptBottomView(model: model, selection: $transcriptSelection)
        }
    }

    /// Height for the panel: head row plus the tracks it needs, about a third of the window at most, so the stage
    /// keeps its air. The same in both modes, so switching to the transcript never jumps.
    public static func preferredHeight(model: EditorModel, windowHeight: CGFloat) -> CGFloat {
        let tracks = TimelineLayout(lanes: model.visibleLanes).totalHeight + 10
        return TransportBar.height + 1 + min(max(tracks, 150), max(windowHeight * 0.30, 190))
    }
}

// MARK: - Transcript in the bottom panel

/// Paragraphs of the transcript: a new one after a long pause, or after a sentence once a paragraph is long enough.
enum TranscriptParagraphs {
    static func group(_ words: [TextItem], pauseNs: Int64 = 1_000_000_000, sentenceWords: Int = 25, maxWords: Int = 80) -> [[TextItem]] {
        var out: [[TextItem]] = [], current: [TextItem] = []
        for w in words {
            if let last = current.last {
                let pause = w.startNs - last.endNs > pauseNs
                let sentence = current.count >= sentenceWords && last.text.last.map { ".!?".contains($0) } == true
                if pause || sentence || current.count >= maxWords { out.append(current); current = [] }
            }
            current.append(w)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// Word selection like text: a click selects one word, ⇧-click extends from the anchor, ⌘-click toggles one.
struct TranscriptSelection: Equatable {
    var ids = Set<String>()
    var anchor: String?

    mutating func click(_ id: String, in order: [String], extend: Bool, toggle: Bool) {
        if toggle {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
        } else if extend, let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: id) {
            ids = Set(order[min(i, j)...max(i, j)])
        } else {
            ids = [id]; anchor = id
        }
    }
}

/// The transcript of the edit: paragraphs with yellow timecodes, filler words dotted, hidden words struck through.
/// Click a word to jump there; select words and press Delete (or "Cut") to cut them from the video.
struct TranscriptBottomView: View {
    @ObservedObject var model: EditorModel
    @Binding var selection: Set<String>
    @State private var anchor: String?
    @FocusState private var focused: Bool

    var body: some View {
        let words = model.transcriptWords
        Group {
            if words.isEmpty { empty } else { transcript(words) }
        }
        .onChange(of: model.revision) { _, _ in
            let alive = Set(model.transcriptWords.map(\.id))
            if !selection.isSubset(of: alive) { selection.formIntersection(alive) }
        }
    }

    private func transcript(_ words: [TextItem]) -> some View {
        let order = words.map(\.id)
        let filler = fillerWords(forLanguage: model.transcriptLanguage)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(TranscriptParagraphs.group(words), id: \.first!.id) { p in
                    TranscriptParagraphRow(model: model, words: p, filler: filler, selection: selection) { id, extend, toggle in
                        var s = TranscriptSelection(ids: selection, anchor: anchor)
                        s.click(id, in: order, extend: extend, toggle: toggle)
                        selection = s.ids; anchor = s.anchor; focused = true
                        if !extend && !toggle, let w = words.first(where: { $0.id == id }) { model.seek(toNs: w.startNs) }
                    }
                }
            }
            .padding(.leading, TimelineLook.namesColumn - 36).padding(.trailing, 16).padding(.vertical, 12)
        }
        .scrollIndicators(.automatic)
        .focusable().focusEffectDisabled().focused($focused)
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard !selection.isEmpty else { return .ignored }
            model.deleteWords(ids: selection); selection = []
            return .handled
        }
        .onKeyPress(.escape) {
            guard !selection.isEmpty else { return .ignored }
            selection = []; return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript")
    }

    @ViewBuilder private var empty: some View {
        VStack(spacing: 10) {
            switch model.captionState {
            case .working:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Transcribing on this Mac…").font(Yap.Font.body).foregroundStyle(Yap.body) }
            case .failed(let m):
                Text(m).font(Yap.Font.body).foregroundStyle(Yap.body).multilineTextAlignment(.center)
                Button("Dismiss") { model.captionState = .idle }.buttonStyle(CapsuleButtonStyle(.secondary, height: 26))
            case .idle:
                Text("No transcript yet").font(Yap.Font.body).foregroundStyle(Yap.caption)
                Button("Generate transcript") { model.generateCaptions() }
                    .buttonStyle(CapsuleButtonStyle(.secondary, height: 28))
                    .help("On-device speech recognition. Words you delete are cut from the video.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One paragraph: its timecode (click to jump) and the words flowing like text.
private struct TranscriptParagraphRow: View {
    @ObservedObject var model: EditorModel
    let words: [TextItem]
    let filler: Set<String>
    let selection: Set<String>
    let click: (String, _ extend: Bool, _ toggle: Bool) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button { model.seek(toNs: words[0].startNs) } label: {
                Text(formatTimecode(words[0].startNs, showFraction: false)).technical()
            }
            .buttonStyle(.plain).frame(width: 36, alignment: .leading)
            .help("Jump to \(formatTimecode(words[0].startNs))")
            WordFlow {
                ForEach(words) { w in
                    WordChip(model: model, word: w, filler: isFiller(w), selected: selection.contains(w.id), click: click)
                }
            }
        }
    }

    private func isFiller(_ w: TextItem) -> Bool {
        filler.contains(w.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
    }
}

private struct WordChip: View {
    let model: EditorModel
    let word: TextItem
    let filler: Bool
    let selected: Bool
    let click: (String, _ extend: Bool, _ toggle: Bool) -> Void
    @State private var hover = false

    var body: some View {
        let hidden = word.opacity <= 0
        Text(word.text)
            .font(.system(size: 14))
            .foregroundStyle(hidden ? Yap.faint : (filler ? Yap.caption : Yap.label))
            .strikethrough(hidden, color: Yap.faint)
            .underline(filler && !hidden, pattern: .dot, color: Yap.caption)
            .padding(.horizontal, 2).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.24 : (hover ? 0.08 : 0))))
            .contentShape(Rectangle())
            .onHover { on in withAnimation(Yap.Motion.hover(on)) { hover = on } }
            .onTapGesture {
                let f = NSEvent.modifierFlags
                click(word.id, f.contains(.shift), f.contains(.command))
            }
            .contextMenu {
                Button("Cut from video") { model.deleteWords(ids: [word.id]) }
                Button(hidden ? "Show in captions" : "Hide from captions") {
                    if hidden { model.unhideWord(id: word.id) } else { model.hideWord(id: word.id) }
                }
            }
            .help(filler ? "Filler word" : formatTimecode(word.startNs))
            .accessibilityLabel(word.text)
            .accessibilityValue(filler ? "filler word" : (hidden ? "hidden from captions" : ""))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: "Cut from video") { model.deleteWords(ids: [word.id]) }
    }
}

/// Lays words out in lines like text.
struct WordFlow: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = Self.arrange(width: proposal.width ?? 600, sizes: subviews.map { $0.sizeThatFits(.unspecified) }, spacing: spacing, lineSpacing: lineSpacing)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = Self.arrange(width: bounds.width, sizes: subviews.map { $0.sizeThatFits(.unspecified) }, spacing: spacing, lineSpacing: lineSpacing)
        for (v, p) in zip(subviews, rows.points) {
            v.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    /// Positions of items of the given sizes, wrapped at `width` (pure, for tests).
    static func arrange(width: CGFloat, sizes: [CGSize], spacing: CGFloat = 0, lineSpacing: CGFloat = 3) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in sizes {
            if x > 0 && x + s.width > width { x = 0; y += line + lineSpacing; line = 0 }
            points.append(CGPoint(x: x, y: y))
            x += s.width + spacing; widest = max(widest, x); line = max(line, s.height)
        }
        return (points, widest, y + line)
    }
}
