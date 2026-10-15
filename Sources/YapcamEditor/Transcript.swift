import SwiftUI

/// Words of the transcript are the caption records. Deleting words cuts the video; hiding only removes the caption.
public let fillerWords: Set<String> = ["um", "uh", "uhm", "umm", "er", "erm", "ah", "hm", "hmm", "mm", "mhm", "äh", "ähm", "öh", "eh"]

extension EditorModel {
    public var transcriptWords: [TextItem] { textItems(.caption).sorted { $0.startNs < $1.startNs } }

    private func normalized(_ t: String) -> String {
        t.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }
    public func isFiller(_ w: TextItem) -> Bool { fillerWords.contains(normalized(w.text)) }

    /// Merge overlapping/adjacent spans so each stretch of video is cut once.
    static func merged(_ spans: [TimeSpan]) -> [TimeSpan] {
        var out: [TimeSpan] = []
        for s in spans.sorted(by: { $0.startNs < $1.startNs }) {
            if var last = out.last, s.startNs <= last.endNs { last.endNs = max(last.endNs, s.endNs); out[out.count - 1] = last } else { out.append(s) }
        }
        return out
    }

    /// Cuts the given stretches out of the timeline in one undo step (later stretches first so coordinates stay valid).
    func cut(_ spans: [TimeSpan]) {
        let ranges = Self.merged(spans).filter { $0.durationNs > 0 }
        guard !ranges.isEmpty else { return }
        guard ranges.reduce(0, { $0 + $1.durationNs }) < durationNs else { lastError = "That would remove the whole recording."; return }
        perform(.batch(ranges.reversed().map { .deleteRange(startNs: $0.startNs, endNs: $0.endNs) }))
    }

    public func deleteWords(ids: Set<String>) { cut(transcriptWords.filter { ids.contains($0.id) }.map(\.span)) }
    public func hideWord(id: String) { removeText(.caption, id: id) }
    public func correctWord(id: String, text: String) { updateText(.caption, id: id) { $0.text = text } }

    public var fillerWordCount: Int { transcriptWords.filter(isFiller).count }
    /// Removes every filler word from the video (one undo step).
    public func removeFillerWords() { cut(transcriptWords.filter(isFiller).map(\.span)) }

    /// Pauses longer than `longerThan` between words are cut down to `keep`.
    public func pauseCuts(longerThan: Int64 = 700_000_000, keep: Int64 = 250_000_000) -> [TimeSpan] {
        let w = transcriptWords
        return zip(w, w.dropFirst()).compactMap { a, b in
            b.startNs - a.endNs > longerThan ? TimeSpan(startNs: a.endNs + keep, endNs: b.startNs) : nil
        }
    }
    public func tightenPauses(longerThan: Int64 = 700_000_000, keep: Int64 = 250_000_000) { cut(pauseCuts(longerThan: longerThan, keep: keep)) }
}

/// "Edit by transcript": delete / hide / correct words, remove filler words, tighten pauses.
struct TranscriptPanel: View {
    @ObservedObject var model: EditorModel
    @State private var selected = Set<String>()
    @State private var editing: String?
    @State private var draft = ""

    var body: some View {
        let words = model.transcriptWords
        if words.isEmpty {
            Section("Transcript") {
                switch model.captionState {
                case .working: HStack { ProgressView().controlSize(.small); Text("Transcribing on this Mac…") }
                case .failed(let m): Text(m).foregroundStyle(.red); Button("Dismiss") { model.captionState = .idle }
                case .idle: Button("Generate transcript from speech") { model.generateCaptions() }
                }
                Text("The transcript comes from on-device speech recognition of your recording. Words you delete are cut from the video.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Section("Clean up") {
                Button("Remove filler words (\(model.fillerWordCount))") { model.removeFillerWords() }.disabled(model.fillerWordCount == 0)
                let pauses = model.pauseCuts()
                Button("Tighten pauses (\(pauses.count))") { model.tightenPauses() }.disabled(pauses.isEmpty)
                Text("Pauses over 0.7 s are shortened to 0.25 s. Undo (⌘Z) restores anything cut.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Words") {
                HStack {
                    Button("Delete selected (\(selected.count))") { model.deleteWords(ids: selected); selected = [] }.disabled(selected.isEmpty)
                    Button("Clear") { selected = [] }.disabled(selected.isEmpty)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(words) { w in row(w) }
                    }
                }.frame(maxHeight: 320)
            }
        }
    }

    private func row(_ w: TextItem) -> some View {
        HStack(spacing: 6) {
            Button { if selected.contains(w.id) { selected.remove(w.id) } else { selected.insert(w.id) }; model.seek(toNs: w.startNs) } label: {
                Image(systemName: selected.contains(w.id) ? "checkmark.square.fill" : "square").foregroundStyle(selected.contains(w.id) ? Color.accentColor : .secondary)
            }.buttonStyle(.plain).accessibilityLabel(selected.contains(w.id) ? "Deselect word" : "Select word")
            Text(formatTimecode(w.startNs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            if editing == w.id {
                TextField("Word", text: $draft).onSubmit { model.correctWord(id: w.id, text: draft); editing = nil }
            } else {
                Text(w.text).strikethrough(false).foregroundStyle(model.isFiller(w) ? Color.orange : .primary)
                    .onTapGesture(count: 2) { draft = w.text; editing = w.id }
                    .help("Double-click to correct")
            }
            Spacer()
            Button { model.hideWord(id: w.id) } label: { Image(systemName: "eye.slash") }.buttonStyle(.borderless).help("Hide this word from the captions")
                .accessibilityLabel("Hide word")
            Button { model.deleteWords(ids: [w.id]) } label: { Image(systemName: "scissors") }.buttonStyle(.borderless).help("Cut this word out of the video")
                .accessibilityLabel("Cut word from video")
        }
        .padding(.vertical, 1)
    }
}
