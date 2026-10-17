import SwiftUI
import YapcamCore
import YapcamDesign

/// Fixing the transcript text (CAM-33, MKT-037/038): one undo step per edit, never a cut.
public struct WordEdit: Equatable, Sendable { public var id: String; public var text: String; public var hide: Bool }

extension EditorModel {
    /// Maps the edited text of a run of words back onto those words. Common leading and trailing words stay; in the changed middle,
    /// new words replace old ones in order, surplus old words are hidden (not cut), surplus new words join the last middle word.
    public static func wordEdits(old: [TextItem], newText: String) -> [WordEdit] {
        let new = newText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var pre = 0
        while pre < old.count, pre < new.count, old[pre].text == new[pre] { pre += 1 }
        var suf = 0
        while suf < old.count - pre, suf < new.count - pre, old[old.count - 1 - suf].text == new[new.count - 1 - suf] { suf += 1 }
        let oldMid = Array(old[pre..<(old.count - suf)]), newMid = Array(new[pre..<(new.count - suf)])
        guard !oldMid.isEmpty || !newMid.isEmpty else { return [] }
        if oldMid.isEmpty {                        // pure insertion: attach to the neighbouring word
            if pre > 0 { return [WordEdit(id: old[pre - 1].id, text: ([old[pre - 1].text] + newMid).joined(separator: " "), hide: false)] }
            if let first = old.first { return [WordEdit(id: first.id, text: (newMid + [first.text]).joined(separator: " "), hide: false)] }
            return []
        }
        return oldMid.enumerated().map { i, w in
            if i < newMid.count {
                let isLast = i == oldMid.count - 1
                let text = isLast ? newMid[i...].joined(separator: " ") : newMid[i]
                return WordEdit(id: w.id, text: text, hide: false)
            }
            return WordEdit(id: w.id, text: w.text, hide: true)
        }
    }

    /// Applies word edits as a single undo step.
    public func applyWordEdits(_ edits: [WordEdit]) {
        guard !edits.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: edits.map { ($0.id, $0) })
        writeTextList(.caption, textItems(.caption).map { item in
            guard let e = byID[item.id] else { return item }
            var t = item
            if e.text != t.text { t.text = e.text; t.words = [] }
            if e.hide { t.opacity = 0 }
            return t
        })
    }

    /// ⌘⌫: removes the words from the captions only; the video keeps playing through them. One undo step.
    public func hideWords(ids: Set<String>) {
        applyWordEdits(transcriptWords.filter { ids.contains($0.id) }.map { WordEdit(id: $0.id, text: $0.text, hide: true) })
    }

    /// Pause before a word, if long enough to show inline (MKT-038).
    public func pause(before index: Int, minimum: Int64 = 500_000_000) -> Int64? {
        let w = transcriptWords
        guard index > 0, index < w.count else { return nil }
        let gap = w[index].startNs - w[index - 1].endNs
        return gap >= minimum ? gap : nil
    }
    public static func pauseLabel(_ ns: Int64) -> String { String(format: "%.1f s", Double(ns) / 1e9) }
}

/// "Edit transcript": paragraphs as editable text with the pause lengths between them. Return applies a paragraph.
struct TranscriptEditSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Edit transcript").font(Yap.Font.title(18)).foregroundStyle(Yap.title); Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
            InspectorNote("Fix typos here. Press Return to apply a paragraph; the video is not cut. Remove words you want hidden from the captions.")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    let words = model.transcriptWords
                    ForEach(TranscriptParagraphs.group(words), id: \.first!.id) { p in
                        ParagraphEditor(model: model, words: p, pause: words.firstIndex { $0.id == p[0].id }.flatMap { model.pause(before: $0) })
                    }
                }
            }
        }
        .padding(20).frame(width: 560, height: 480)
    }
}

private struct ParagraphEditor: View {
    @ObservedObject var model: EditorModel
    let words: [TextItem]
    let pause: Int64?
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let pause { Text("pause \(EditorModel.pauseLabel(pause))").font(Yap.Font.caption).foregroundStyle(Yap.caption) }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(formatTimecode(words[0].startNs, showFraction: false)).technical().frame(width: 40, alignment: .leading)
                TextField("", text: $text, axis: .vertical).textFieldStyle(.plain).font(.system(size: 14))
                    .onSubmit { model.applyWordEdits(EditorModel.wordEdits(old: words, newText: text)) }
            }
        }
        .onAppear { text = words.map(\.text).joined(separator: " ") }
        .onChange(of: words.map(\.text)) { _, t in text = t.joined(separator: " ") }
    }
}
