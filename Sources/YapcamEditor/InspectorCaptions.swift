import SwiftUI
import YapcamDesign

// Captions and "Edit by transcript": generating, options, style, the caption list. The transcript text itself is shown in
// the bottom panel (`model.bottomPanel = .transcript`).

struct CaptionSection: View {
    @ObservedObject var model: EditorModel
    @State private var editing = false
    var body: some View {
        let captions = model.textItems(.caption)
        VStack(alignment: .leading, spacing: 0) {
            if case .text(.caption, let id) = model.selection, let t = captions.first(where: { $0.id == id }) {
                SelectedItemGroup(model: model, title: "Caption", span: t.span) { TextControls(model: model, item: t) }
            }
            InspectorGroup(first: true) {
                CaptionGeneration(model: model, count: captions.count)
                InspectorAction("Add caption at playhead", symbol: "plus") { model.addText(.caption) }
                if !model.transcriptWords.isEmpty { InspectorAction("Edit transcript", symbol: "text.cursor") { editing = true } }
            }
            InspectorGroup("Style") { CaptionStyleControls(model: model) }
            if !captions.isEmpty { InspectorGroup("All captions") { CaptionList(model: model, captions: captions) } }
        }
        .sheet(isPresented: $editing) { TranscriptEditSheet(model: model) }
    }
}

/// Generate / regenerate captions from speech, with the recognizer options while there are none yet.
private struct CaptionGeneration: View {
    @ObservedObject var model: EditorModel
    let count: Int
    var body: some View {
        switch model.captionState {
        case .working: InspectorBusy("Transcribing on this Mac…")
        case .failed(let m): InspectorFailure(message: m) { model.captionState = .idle }
        case .idle:
            if count == 0 {
                InspectorAction("Generate captions from speech", symbol: "waveform") { model.generateCaptions() }
            } else {
                InspectorInfo("Captions", "\(count)")
                InspectorRegenerateButton(model: model)
            }
        }
        if count == 0 || model.captionState != .idle { InspectorTranscriptionOptions(model: model) }
    }
}

private struct CaptionList: View {
    @ObservedObject var model: EditorModel
    let captions: [TextItem]
    var body: some View {
        InspectorNote("Click one to edit its text, timing and style.")
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(captions) { c in
                    InspectorListRow(time: formatTimecode(c.startNs), text: c.text, selected: model.selection == .text(.caption, c.id)) {
                        model.selection = .text(.caption, c.id); model.seek(toNs: c.startNs)
                    }
                }
            }
        }
        .frame(maxHeight: 200)
        .padding(.horizontal, -8)
    }
}

/// "Edit by transcript": generating and its options, the clean-up actions, export, and the way to the transcript panel.
struct TranscriptSettingsSection: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        let words = model.transcriptWords
        if words.isEmpty {
            InspectorGroup(first: true) {
                switch model.captionState {
                case .working: InspectorBusy("Transcribing on this Mac…")
                case .failed(let m): InspectorFailure(message: m) { model.captionState = .idle }
                case .idle: InspectorAction("Generate transcript from speech", symbol: "waveform") { model.generateCaptions() }
                }
                InspectorTranscriptionOptions(model: model)
                InspectorNote("The transcript comes from on-device speech recognition of your recording. Words you delete are cut from the video.")
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                InspectorGroup(first: true) { TranscriptEditRows(model: model, wordCount: words.count) }
                InspectorGroup("Transcript options") { TranscriptOptionRows(model: model) }
            }
        }
    }
}

private struct TranscriptEditRows: View {
    @ObservedObject var model: EditorModel
    let wordCount: Int
    var body: some View {
        let pauses = model.pauseCuts(), fillers = model.fillerWordCount
        // The transcript text lives in the bottom panel; this opens it (and, once open, goes back to the timeline).
        let showing = model.bottomPanel == .transcript
        Button { model.bottomPanel = showing ? .timeline : .transcript } label: {
            Label(showing ? "Show timeline" : "Show transcript", systemImage: showing ? "timeline.selection" : "text.quote")
        }
        .buttonStyle(CapsuleButtonStyle(.secondary, height: 28))
        .help(showing ? "Show the timeline again in the bottom panel" : "Show the transcript under the preview; select words and delete them to cut the video")
        InspectorNote("Select words in the transcript and delete them to cut the video.")
        InspectorInfo("Words", "\(wordCount)")
        InspectorAction("Remove \(fillers) filler word\(fillers == 1 ? "" : "s")", symbol: "wand.and.stars") { model.removeFillerWords() }
            .disabled(fillers == 0)
        InspectorAction("Tighten \(pauses.count) pause\(pauses.count == 1 ? "" : "s")", symbol: "arrow.left.and.right") { model.tightenPauses() }
            .disabled(pauses.isEmpty)
        InspectorNote("Pauses over 0.7 s are shortened to 0.25 s. Undo (⌘Z) restores anything cut.")
    }
}

private struct TranscriptOptionRows: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        InspectorTranscriptionOptions(model: model)
        switch model.captionState {
        case .working: InspectorBusy("Transcribing on this Mac…")
        case .failed(let m): InspectorFailure(message: m) { model.captionState = .idle }
        case .idle: InspectorRegenerateButton(model: model)
        }
        Menu {
            ForEach(TranscriptFormat.allCases) { f in Button(f.label) { model.chooseTranscriptExport(f, suggestedName: "Transcript") } }
        } label: {
            Label("Export transcript…", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button).buttonStyle(CapsuleButtonStyle(.secondary, height: 28)).menuIndicator(.hidden).fixedSize()
        InspectorNote("Exported times follow the edited timeline (after cuts and speed changes).")
    }
}

/// Keyterms and language for the next transcription.
struct InspectorTranscriptionOptions: View {
    @ObservedObject var model: EditorModel
    @State private var terms = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keyterms").font(Yap.Font.body).foregroundStyle(Yap.label)
            RecessedField("Names or terms, comma separated", text: $terms, height: 30)
                .onSubmit { model.keytermsText = terms }
                .onChange(of: terms) { _, v in model.keytermsText = v }
                .onAppear { terms = model.keytermsText }
                .accessibilityLabel("Keyterms").help("Words and phrases the speech recognizer should expect")
        }
        ChoiceRow("Language", selection: Binding(get: { model.transcriptionLanguage }, set: { model.transcriptionLanguage = $0 }),
                  options: languages, forceMenu: true)
    }

    private var languages: [(String, String)] {
        let list = EditorWindows.languageProvider?() ?? []
        var o: [(String, String)] = [("Auto", "auto")] + list.map { ($0.name, $0.id) }
        let cur = model.transcriptionLanguage
        if cur != "auto", !list.contains(where: { $0.id == cur }) { o.append((cur, cur)) }
        return o
    }
}

/// "Regenerate transcript" asks first: the new transcript replaces corrected and hidden words.
struct InspectorRegenerateButton: View {
    @ObservedObject var model: EditorModel
    @State private var confirm = false
    var body: some View {
        InspectorAction("Regenerate transcript…", symbol: "arrow.clockwise") { confirm = true }
            .confirmationDialog("Regenerate the transcript?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Regenerate", role: .destructive) { model.regenerateTranscript() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Edits to the transcript (corrected or hidden words) are discarded. Cuts you made stay.") }
    }
}
