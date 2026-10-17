import Foundation
import Speech
import YapcamCapture
import YapcamEditor

/// Connects the editor's Keyterms field and Language picker (AUD-10) to capture's on-device transcription.
enum TranscriptionWiring {
    /// (package, locale identifier, keyterms) → transcript JSON. Injected in tests.
    typealias Transcribe = @Sendable (URL, String, [String]) async throws -> Data

    static let live: Transcribe = { package, locale, keyterms in
        if TranscriptionService.authorizationState == .notDetermined {
            try await TranscriptionService.requestAuthorization()
        }
        let transcript = try await TranscriptionService().transcribe(package: package, localeIdentifier: locale, keyterms: keyterms)
        if let text = partialNotice(for: transcript.warnings) {
            await MainActor.run { RecordingController.shared.alert = AppAlert(title: "Captions may be incomplete", message: text) }
        }
        return try JSONEncoder().encode(transcript)
    }

    /// What to tell the user when speech recognition skipped parts (nil when it processed everything).
    static func partialNotice(for warnings: [TranscriptionWarning]) -> String? {
        guard !warnings.isEmpty else { return nil }
        let first = warnings.first!.message
        let more = warnings.count > 1 ? " (and \(warnings.count - 1) more)" : ""
        return "Some parts of the recording could not be turned into text: \(first)\(more). The captions that were found are kept; you can run Generate captions again or edit the text by hand."
    }

    /// "Auto" means the language the Mac is set to; anything else is the chosen locale as is.
    static func localeIdentifier(for language: String, system: String = Locale.current.identifier) -> String {
        language.isEmpty || language == "auto" ? system : language
    }

    /// Blank entries are dropped and repeats removed; order is kept.
    static func cleanKeyterms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func transcribe(package: URL, options: TranscriptionOptions, using run: Transcribe,
                           system: String = Locale.current.identifier) async throws -> Data {
        try await run(package, localeIdentifier(for: options.language, system: system), cleanKeyterms(options.keyterms))
    }

    /// The picker's list: every locale the recogniser supports, by display name.
    static func languages(from locales: [Locale], display: Locale = .current) -> [TranscriptionLanguage] {
        var seen = Set<String>()
        return locales.compactMap { l -> TranscriptionLanguage? in
            let id = l.identifier
            guard seen.insert(id).inserted else { return nil }
            return TranscriptionLanguage(id: id, name: display.localizedString(forIdentifier: id) ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
