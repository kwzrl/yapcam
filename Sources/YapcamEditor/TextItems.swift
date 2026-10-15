import Foundation
import CoreGraphics
import YapcamCore

public enum TextKind: String, CaseIterable, Sendable {
    case annotation, reaction, caption
    var path: String { "canvas." + (self == .annotation ? "annotations" : self == .reaction ? "reactions" : "captions") }
    var label: String { switch self { case .annotation: "Text"; case .reaction: "Reaction"; case .caption: "Caption" } }
}

/// Annotation / reaction / caption record (core `canvas.annotations|reactions|captions`).
public struct CaptionWord: Equatable, Sendable { public var text: String; public var startNs: Int64, endNs: Int64 }

public struct TextItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: TextKind
    public var startNs: Int64, endNs: Int64
    public var text: String
    public var rect: [Double]
    public var space: String
    public var fontSize: Double
    public var color: [Double], background: [Double]
    public var radius: Double, opacity: Double
    /// Style members the editor does not edit directly (font_family, reveal, growth, entrance, language, …), kept verbatim.
    public var extraStyle: [String: JSONValue] = [:]
    /// Caption word timing from core (absolute timeline ns); rescaled when the caption is retimed, dropped when its text changes.
    public var words: [CaptionWord] = []
    var parsedSpan: TimeSpan?
    public var span: TimeSpan { TimeSpan(startNs: startNs, endNs: endNs) }

    public static func make(_ kind: TextKind, id: String, start: Int64, end: Int64, text: String) -> TextItem {
        var t = TextItem(id: id, kind: kind, startNs: start, endNs: end, text: text, rect: [0.1, 0.75, 0.8, 0.15], space: "canvas",
                         fontSize: 36, color: [1, 1, 1, 1], background: [0, 0, 0, 0.65], radius: 12, opacity: 1)
        switch kind {
        case .annotation: break
        case .reaction: t.rect = [0.42, 0.3, 0.16, 0.28]; t.fontSize = 120; t.background = [0, 0, 0, 0]
        case .caption: t.rect = [0.1, 0.82, 0.8, 0.12]; t.fontSize = 40
        }
        return t
    }
}

public let reactionGlyphs = ["👍", "🎉", "❤️", "😂", "👏", "🔥", "😮", "✅"]

extension EditorModel {
    private func nums(_ v: JSONValue?) -> [Double] {
        if case .array(let a)? = v { return a.compactMap { if case .number(let d) = $0 { d } else { nil } } }
        return []
    }
    private func num(_ v: JSONValue?, _ d: Double) -> Double { if case .number(let x)? = v { x } else { d } }

    public func textItems(_ kind: TextKind) -> [TextItem] {
        guard case .array(let rows)? = value(kind.path) else { return [] }
        let base = TextItem.make(kind, id: "", start: 0, end: 0, text: "")
        return rows.compactMap { row in
            guard case .object(let o) = row, case .string(let id)? = o["id"], case .number(let a)? = o["tl_start_ns"],
                  case .number(let b)? = o["tl_end_ns"], case .string(let text)? = o["text"] else { return nil }
            var t = base; t.id = id; t.startNs = Int64(a); t.endNs = Int64(b); t.text = text
            let r = nums(o["rect"]); if r.count == 4 { t.rect = r }
            if case .string(let s)? = o["space"] { t.space = s }
            if case .object(let st)? = o["style"] {
                t.fontSize = num(st["font_size"], 36)
                let c = nums(st["color"]), bg = nums(st["background"])
                if c.count == 4 { t.color = c }; if bg.count == 4 { t.background = bg }
                t.radius = num(st["radius"], 12); t.opacity = num(st["opacity"], 1)
                let known: Set<String> = ["font_size", "color", "background", "radius", "opacity"]
                t.extraStyle = st.filter { !known.contains($0.key) }
            }
            if case .array(let ws)? = o["words"] {
                t.words = ws.compactMap { w in
                    guard case .object(let wo) = w, case .string(let s)? = wo["text"], case .number(let a)? = wo["tl_start_ns"],
                          case .number(let b)? = wo["tl_end_ns"] else { return nil }
                    return CaptionWord(text: s, startNs: Int64(a), endNs: Int64(b))
                }
            }
            t.parsedSpan = TimeSpan(startNs: t.startNs, endNs: t.endNs)
            return t
        }
    }
    public var allText: [TextItem] { TextKind.allCases.flatMap { textItems($0) } }
    public func textItem(key: String) -> TextItem? { allText.first { Self.textKey($0) == key } }
    public static func textKey(_ t: TextItem) -> String { "text:\(t.kind.rawValue):\(t.id)" }

    private func json(_ t: TextItem) -> JSONValue {
        func arr(_ a: [Double]) -> JSONValue { .array(a.map { .number($0) }) }
        var style = t.extraStyle
        for (k, v) in ["font_size": JSONValue.number(t.fontSize), "color": arr(t.color), "background": arr(t.background),
                       "radius": .number(t.radius), "opacity": .number(t.opacity)] { style[k] = v }
        var o: [String: JSONValue] = ["id": .string(t.id), "tl_start_ns": .number(Double(t.startNs)), "tl_end_ns": .number(Double(t.endNs)),
                                      "text": .string(t.text), "rect": arr(t.rect), "space": .string(t.space), "style": .object(style)]
        if t.kind == .caption, !t.words.isEmpty { o["words"] = .array(rescaled(t).map { w in
            .object(["text": .string(w.text), "tl_start_ns": .number(Double(w.startNs)), "tl_end_ns": .number(Double(w.endNs))]) }) }
        return .object(o)
    }
    /// Word timing follows the caption when it is moved or resized (linear, integer arithmetic like core's retiming).
    private func rescaled(_ t: TextItem) -> [CaptionWord] {
        guard let old = t.parsedSpan, old.durationNs > 0, old != TimeSpan(startNs: t.startNs, endNs: t.endNs) else { return t.words }
        let newLen = t.endNs - t.startNs
        func map(_ x: Int64) -> Int64 { t.startNs + Int64((Double(x - old.startNs) * Double(newLen) / Double(old.durationNs)).rounded()) }
        return t.words.map { CaptionWord(text: $0.text, startNs: map($0.startNs), endNs: max(map($0.endNs), map($0.startNs) + 1)) }
    }
    private func writeText(_ kind: TextKind, _ items: [TextItem]) { set(kind.path, .array(items.map(json))) }
    func writeTextList(_ kind: TextKind, _ items: [TextItem]) { writeText(kind, items) }

    @discardableResult
    public func addText(_ kind: TextKind, text: String? = nil) -> String? {
        let start = playheadNs, end = min(start + (kind == .reaction ? 2_000_000_000 : 3_000_000_000), durationNs)
        guard end - start >= minItemNs else { lastError = "Not enough room here."; return nil }
        var t = TextItem.make(kind, id: "\(kind.rawValue)-" + UUID().uuidString.prefix(8).lowercased(), start: start, end: end,
                              text: text ?? (kind == .annotation ? "Your text" : kind == .caption ? "Caption" : "👍"))
        if kind == .caption {
            t = captionLook.apply(to: t, outputHeight: outputHeight)
            for (k, v) in captionTypography { t.extraStyle[k] = .string(v) }
        }
        writeText(kind, textItems(kind) + [t])
        guard lastError == nil else { return nil }
        selection = .text(kind, t.id); return t.id
    }
    public func updateText(_ kind: TextKind, id: String, _ change: (inout TextItem) -> Void) {
        writeText(kind, textItems(kind).map {
            var t = $0
            if t.id == id { change(&t); if t.text != $0.text { t.words = [] } }       // corrected text no longer matches its word timing
            return t
        })
    }
    public func removeText(_ kind: TextKind, id: String) { writeText(kind, textItems(kind).filter { $0.id != id }) }

    // MARK: rect drag (one command per gesture)

    public func previewTextRect(key: String, rect: [Double]) {
        let w = min(max(rect[2], 0.02), 1), h = min(max(rect[3], 0.02), 1)
        textRectPreview = (key, [min(max(rect[0], 0), 1 - w), min(max(rect[1], 0), 1 - h), w, h])
    }
    public func commitTextRect() {
        guard let p = textRectPreview else { return }
        textRectPreview = nil
        guard let cur = textItem(key: p.key), cur.rect != p.rect else { return }
        updateText(cur.kind, id: cur.id) { $0.rect = p.rect }
    }
    public func displayedRect(of t: TextItem) -> [Double] {
        if let p = textRectPreview, p.key == Self.textKey(t) { return p.rect }
        return t.rect
    }

    // MARK: captions from speech

    /// Imports a transcript (recording/transcript.json, or the app's on-device transcriber) as captions.
    public func generateCaptions() {
        guard captionState != .working else { return }
        guard let source = captionSource else { captionState = .failed("Speech transcription isn't available in this build."); return }
        captionState = .working
        let started = revision
        captionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await source()
                guard !isClosed, !Task.isCancelled else { return }
                guard revision == started else { captionState = .failed("The timeline changed while transcribing; try again."); return }
                try project.importTranscript(data)
                noteExternalEdit()
                captionState = .idle
            } catch { if !isClosed { captionState = .failed(error.localizedDescription) } }
        }
    }
    public func waitForCaptions() async { await captionTask?.value }
}
