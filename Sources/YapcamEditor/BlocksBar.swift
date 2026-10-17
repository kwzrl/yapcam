import SwiftUI
import YapcamDesign

/// The building blocks that the bar under the preview adds at the playhead.
enum BuildingBlock: String, CaseIterable, Identifiable {
    case title, spotlight, text
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .title: "textformat.size"
        case .spotlight: "scope"
        case .text: "character.cursor.ibeam"
        }
    }
    var help: String {
        switch self {
        case .title: "Add a title at the playhead"
        case .spotlight: "Add a spotlight at the playhead"
        case .text: "Add text at the playhead"
        }
    }
}

extension EditorModel {
    /// Adds a building block at the playhead with the editor's existing functions; each is one undo step.
    func addBlock(_ block: BuildingBlock) {
        switch block {
        case .title: addTitleAtPlayhead()
        case .spotlight: addHighlightAtPlayhead(kind: .spotlight)
        case .text: addText(.annotation)
        }
    }

    /// A large centred annotation without a background: the intro/outro title. Written in one command.
    @discardableResult
    func addTitleAtPlayhead(_ text: String = "Title") -> String? {
        let start = playheadNs, end = min(start + 3_000_000_000, durationNs)
        guard end - start >= minItemNs else { lastError = "Not enough room here."; return nil }
        var t = TextItem.make(.annotation, id: "annotation-" + UUID().uuidString.prefix(8).lowercased(), start: start, end: end, text: text)
        t.rect = [0.1, 0.38, 0.8, 0.24]; t.fontSize = 96; t.background = [0, 0, 0, 0]; t.radius = 0
        writeTextList(.annotation, textItems(.annotation) + [t])
        guard lastError == nil else { return nil }
        selection = .text(.annotation, t.id)
        return t.id
    }
}

/// The small floating glass bar under the preview: building blocks, no drawing tools.
struct BlocksBar: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        HStack(spacing: 2) {
            ForEach(BuildingBlock.allCases) { b in
                SlotButton(symbol: b.symbol, label: b.label, help: b.help, active: false,
                           enabled: !model.clips.isEmpty && model.durationNs > 0) { model.addBlock(b) }
            }
        }
        .padding(.horizontal, Yap.Grid.inset)
        .frame(height: Yap.Grid.bar)
        .fixedSize()
        .glassPanel(radius: Yap.Grid.barRadius, behindWindow: false, sheen: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Building blocks")
    }
}
