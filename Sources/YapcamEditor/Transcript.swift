import SwiftUI

/// Words of the transcript are the caption records. Deleting words cuts the video; hiding only removes the caption.
/// Fillers that are not real words in any language we match; used when the transcript language is unknown ("auto") and as the base list.
public let fillerWords: Set<String> = ["um", "uh", "uhm", "umm", "erm", "hm", "hmm", "mm", "mhm", "äh", "ähm", "öh"]
/// Extra fillers per language. Ambiguous tokens stay out of other languages: "er" ("he") and "eh" ("anyway") are real German words.
public let languageFillers: [String: Set<String>] = ["en": ["er", "ah"], "de": []]

/// The filler words for a language tag ("en-US", "de_DE", "auto"): the base list plus that language's extras.
public func fillerWords(forLanguage tag: String) -> Set<String> {
    let lang = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "auto"
    // Only the recognized-as-English list may treat "er"/"ah" as filler; other languages get the base list.
    return fillerWords.union(languageFillers[lang] ?? [])
}

extension EditorModel {
    public var transcriptWords: [TextItem] { textItems(.caption).sorted { $0.startNs < $1.startNs } }

    private func normalized(_ t: String) -> String {
        t.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }
    /// Language of the transcript: the captions' own tag when set, else the language chosen for transcription ("auto" if neither).
    public var transcriptLanguage: String {
        for w in transcriptWords { if case .string(let l)? = w.extraStyle["language"], l != "auto" { return l } }
        return transcriptionLanguage
    }
    public func isFiller(_ w: TextItem) -> Bool { fillerWords(forLanguage: transcriptLanguage).contains(normalized(w.text)) }

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

/// What the speech recognizer should know: vocabulary hints and the language ("auto" = the recognizer's default).
public struct TranscriptionOptions: Equatable, Sendable {
    public var keyterms: [String] = []
    public var language = "auto"
    public init(keyterms: [String] = [], language: String = "auto") { self.keyterms = keyterms; self.language = language }
}

/// A language the on-device recognizer offers (the app supplies the list; the editor cannot link YapcamCapture).
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
