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
    /// Hiding keeps the word in the transcript but not in the captions (caption opacity 0); unhiding shows it again.
    public func isHidden(_ w: TextItem) -> Bool { w.opacity <= 0 }
    public func hideWord(id: String) { updateText(.caption, id: id) { $0.opacity = 0 } }
    public func unhideWord(id: String) { updateText(.caption, id: id) { $0.opacity = 1 } }
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
                TranscriptionOptionControls(model: model)
                Text("The transcript comes from on-device speech recognition of your recording. Words you delete are cut from the video.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Section("Transcript") {
                TranscriptionOptionControls(model: model)
                switch model.captionState {
                case .working: HStack { ProgressView().controlSize(.small); Text("Transcribing on this Mac…") }
                case .failed(let m): Text(m).foregroundStyle(.red); Button("Dismiss") { model.captionState = .idle }
                case .idle: RegenerateButton(model: model)
                }
                Menu("Export transcript…") {
                    ForEach(TranscriptFormat.allCases) { f in Button(f.label) { model.chooseTranscriptExport(f, suggestedName: "Transcript") } }
                }
                Text("Exported times follow the edited timeline (after cuts and speed changes).").font(.caption).foregroundStyle(.secondary)
            }
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
                Text(w.text).strikethrough(model.isHidden(w)).foregroundStyle(model.isHidden(w) ? Color.secondary : model.isFiller(w) ? Color.orange : .primary)
                    .onTapGesture(count: 2) { draft = w.text; editing = w.id }
                    .help("Double-click to correct")
            }
            Spacer()
            Button { if model.isHidden(w) { model.unhideWord(id: w.id) } else { model.hideWord(id: w.id) } } label: {
                Image(systemName: model.isHidden(w) ? "eye" : "eye.slash")
            }.buttonStyle(.borderless).help(model.isHidden(w) ? "Show this word in the captions again" : "Hide this word from the captions")
                .accessibilityLabel(model.isHidden(w) ? "Show word in captions" : "Hide word from captions")
            Button { model.deleteWords(ids: [w.id]) } label: { Image(systemName: "scissors") }.buttonStyle(.borderless).help("Cut this word out of the video")
                .accessibilityLabel("Cut word from video")
        }
        .padding(.vertical, 1)
    }
}

/// What the speech recogniser should know: vocabulary hints and the language ("auto" = the recognizer's default).
public struct TranscriptionOptions: Equatable, Sendable {
    public var keyterms: [String] = []
    public var language = "auto"
    public init(keyterms: [String] = [], language: String = "auto") { self.keyterms = keyterms; self.language = language }
}

/// A language the on-device recogniser offers (the app supplies the list; the editor cannot link YapcamCapture).
public struct TranscriptionLanguage: Equatable, Identifiable, Sendable {
    public var id: String, name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

extension EditorModel {
    static let keytermsKey = "yapcam.transcription.keyterms", languageKey = "yapcam.transcription.language"
    /// Comma separated words and phrases (names, product terms) that help recognition; remembered per user.
    public var keytermsText: String {
        get { defaults.string(forKey: Self.keytermsKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.keytermsKey); objectWillChange.send() }
    }
    public var transcriptionLanguage: String {
        get { defaults.string(forKey: Self.languageKey) ?? "auto" }
        set { defaults.set(newValue, forKey: Self.languageKey); objectWillChange.send() }
    }
    public var transcriptionOptions: TranscriptionOptions {
        TranscriptionOptions(keyterms: Self.parseKeyterms(keytermsText), language: transcriptionLanguage)
    }
    static func parseKeyterms(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

/// Keyterms and language for the next transcription.
struct TranscriptionOptionControls: View {
    @ObservedObject var model: EditorModel
    @State private var terms = ""
    var body: some View {
        TextField("Keyterms", text: $terms, prompt: Text("Names or terms, comma separated"))
            .onSubmit { model.keytermsText = terms }
            .onChange(of: terms) { _, v in model.keytermsText = v }
            .onAppear { terms = model.keytermsText }
            .accessibilityLabel("Keyterms").help("Words and phrases the speech recognizer should expect")
        let languages = EditorWindows.languageProvider?() ?? []
        Picker("Language", selection: Binding(get: { model.transcriptionLanguage }, set: { model.transcriptionLanguage = $0 })) {
            Text("Auto").tag("auto")
            ForEach(languages) { Text($0.name).tag($0.id) }
            if model.transcriptionLanguage != "auto", !languages.contains(where: { $0.id == model.transcriptionLanguage }) {
                Text(model.transcriptionLanguage).tag(model.transcriptionLanguage)
            }
        }
    }
}

/// "Regenerate transcript" asks first: the new transcript replaces corrected and hidden words.
struct RegenerateButton: View {
    @ObservedObject var model: EditorModel
    @State private var confirm = false
    var body: some View {
        Button("Regenerate transcript…") { confirm = true }
            .confirmationDialog("Regenerate the transcript?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Regenerate", role: .destructive) { model.regenerateTranscript() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Edits to the transcript (corrected or hidden words) are discarded. Cuts you made stay.") }
    }
}
