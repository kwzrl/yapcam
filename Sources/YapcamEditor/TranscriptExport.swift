import SwiftUI
import AppKit

/// Transcript file formats offered by "Export transcript".
public enum TranscriptFormat: String, CaseIterable, Identifiable, Sendable {
    case srt, vtt, txt
    public var id: String { rawValue }
    public var label: String { switch self { case .srt: "SubRip (.srt)"; case .vtt: "WebVTT (.vtt)"; case .txt: "Plain text (.txt)" } }
    public var fileExtension: String { rawValue }
}

/// Builds subtitle cues and files from transcript words. Times are the EDITED timeline (the words' timeline times after
/// cuts and speed changes), never source time.
public enum TranscriptExporter {
    public struct Cue: Equatable, Sendable { public var startNs: Int64, endNs: Int64; public var text: String }

    /// Groups words into readable lines: a new cue starts after a pause, at 42 characters, or after 6 seconds.
    public static func cues(_ words: [TextItem], maxChars: Int = 42, maxDurationNs: Int64 = 6_000_000_000, pauseNs: Int64 = 800_000_000) -> [Cue] {
        var out: [Cue] = []
        for w in words.sorted(by: { $0.startNs < $1.startNs }) where !w.text.trimmingCharacters(in: .whitespaces).isEmpty {
            let text = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if var last = out.last,
               w.startNs - last.endNs < pauseNs, last.text.count + 1 + text.count <= maxChars, w.endNs - last.startNs <= maxDurationNs {
                last.text += " " + text; last.endNs = max(last.endNs, w.endNs); out[out.count - 1] = last
            } else {
                out.append(Cue(startNs: w.startNs, endNs: max(w.endNs, w.startNs + 1), text: text))
            }
        }
        return out
    }

    static func stamp(_ ns: Int64, comma: Bool) -> String {
        let ms = max(0, ns) / 1_000_000
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, comma ? "," : ".", ms % 1000)
    }

    public static func render(_ words: [TextItem], as format: TranscriptFormat) -> String {
        let cues = Self.cues(words)
        switch format {
        case .srt:
            return cues.enumerated().map { i, c in "\(i + 1)\n\(stamp(c.startNs, comma: true)) --> \(stamp(c.endNs, comma: true))\n\(c.text)\n" }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + cues.map { c in "\(stamp(c.startNs, comma: false)) --> \(stamp(c.endNs, comma: false))\n\(c.text)\n" }.joined(separator: "\n")
        case .txt:
            return cues.map(\.text).joined(separator: "\n") + (cues.isEmpty ? "" : "\n")
        }
    }
}

extension EditorModel {
    public func transcriptText(_ format: TranscriptFormat) -> String { TranscriptExporter.render(transcriptWords, as: format) }

    /// Writes the transcript in `format` to `url` (atomically).
    public func exportTranscript(_ format: TranscriptFormat, to url: URL) {
        do { try transcriptText(format).write(to: url, atomically: true, encoding: .utf8) }
        catch { lastError = "Couldn't export the transcript: \(error.localizedDescription)" }
    }

    /// Save panel for "Export transcript".
    func chooseTranscriptExport(_ format: TranscriptFormat, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName + "." + format.fileExtension
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { exportTranscript(format, to: url) }
    }
}
