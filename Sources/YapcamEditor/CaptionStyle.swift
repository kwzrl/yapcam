import SwiftUI
import YapcamDesign

/// Caption look as in the reference: size as a fraction of the output height (0.05–0.125), Dark or Light text,
/// bottom or centered position. Applies to every caption and is remembered for new ones.
public struct CaptionLook: Equatable, Sendable {
    public var size = 0.05           // fraction of the output height (reference default; core caption_defaults ratio .05)
    public var light = false         // false: white text on a dark plate, true: dark text on a light plate
    public var center = false        // false: bottom, true: centered
    public static let sizeRange = 0.05...0.125
    public init() {}
}

extension CaptionLook {
    func apply(to t: TextItem, outputHeight h: Double) -> TextItem {
        var t = t
        let ratio = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        t.fontSize = ratio * h
        t.extraStyle["font_size_ratio"] = .number(ratio)     // core scales with the canvas; the pixel size above is the fallback
        t.color = light ? [0.08, 0.08, 0.08, 1] : [1, 1, 1, 1]
        t.background = light ? [1, 1, 1, 0.88] : [0, 0, 0, 0.65]
        let boxH = max(t.rect[3], 0.12)
        t.rect = [0.1, center ? 0.5 - boxH / 2 : 0.94 - boxH, 0.8, boxH]
        return t
    }
}

extension EditorModel {
    static let captionLookKey = "yapcam.captionLook"
    public var captionLook: CaptionLook {
        get {
            guard let a = defaults.array(forKey: Self.captionLookKey) as? [Double], a.count == 3 else { return CaptionLook() }
            var l = CaptionLook(); l.size = a[0]; l.light = a[1] > 0.5; l.center = a[2] > 0.5; return l
        }
        set {
            defaults.set([newValue.size, newValue.light ? 1 : 0, newValue.center ? 1 : 0], forKey: Self.captionLookKey)
            objectWillChange.send()
        }
    }
    static let captionTypographyKey = "yapcam.captionTypography"
    /// Remembered caption typography (font_family, reveal, growth, entrance, language) for new captions.
    public var captionTypography: [String: String] {
        get { defaults.dictionary(forKey: Self.captionTypographyKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.captionTypographyKey); objectWillChange.send() }
    }
    public func captionTypographyValue(_ key: String, default d: String) -> String {
        if let v = captionTypography[key] { return v }
        if case .string(let s)? = textItems(.caption).first?.extraStyle[key] { return s }
        return d
    }
    /// Applies one typography choice to every caption (one undo step) and remembers it for new captions.
    public func setCaptionTypography(_ key: String, _ value: String) {
        captionTypography[key] = value
        guard !textItems(.caption).isEmpty else { return }
        writeTextList(.caption, textItems(.caption).map { var t = $0; t.extraStyle[key] = .string(value); return t })
    }
    var outputHeight: Double { max(numbers("canvas.output_size").last ?? 1080, 1) }

    /// Remembers the look and applies it to all existing captions as one undo step.
    public func setCaptionLook(_ look: CaptionLook) {
        captionLook = look
        let h = outputHeight
        writeTextList(.caption, textItems(.caption).map { look.apply(to: $0, outputHeight: h) })
    }
}

struct CaptionStyleControls: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        let look = model.captionLook
        CommitSlider(title: "Size", range: CaptionLook.sizeRange, get: { look.size }, commit: { var l = look; l.size = $0; model.setCaptionLook(l) },
                     text: { String(format: "%.1f %%", $0 * 100) }, defaultValue: 0.05)
        ChoiceRow("Color", selection: Binding(get: { look.light }, set: { v in var l = look; l.light = v; model.setCaptionLook(l) }), options: [("Dark", false), ("Light", true)])
        ChoiceRow("Position", selection: Binding(get: { look.center }, set: { v in var l = look; l.center = v; model.setCaptionLook(l) }), options: [("Bottom", false), ("Center", true)])
        typography("Font", "font_family", "sans", [("Sans", "sans"), ("Serif", "serif"), ("Mono", "mono")])
        InspectorMore("Typography") {
            typography("Reveal", "reveal", "line", [("Whole line", "line"), ("Word by word", "word")])
            typography("Growth", "growth", "full", [("Full box", "full"), ("Expanding", "expanding"), ("Centered", "centered")])
            typography("Entrance", "entrance", "appear", [("Appear", "appear"), ("Fade", "fade"), ("Slide", "slide")])
            CaptionLanguageField(model: model)
        }
    }

    private func typography(_ title: String, _ key: String, _ d: String, _ options: [(String, String)]) -> some View {
        ChoiceRow(title, selection: Binding(get: { model.captionTypographyValue(key, default: d) }, set: { model.setCaptionTypography(key, $0) }),
                  options: options)
    }
}

/// Caption language tag ("auto" or e.g. "en-US"); core validates the tag, the speech service decides what it can recognize.
struct CaptionLanguageField: View {
    @ObservedObject var model: EditorModel
    @State private var text = "auto"
    var body: some View {
        HStack(spacing: 8) {
            Text("Language").font(Yap.Font.body).foregroundStyle(Yap.label)
            Spacer(minLength: 8)
            RecessedField("auto, en-US, de…", text: $text, height: 28)
                .frame(width: 130)
                .onSubmit { commit() }
                .accessibilityLabel("Caption language")
        }
        .onAppear { text = model.captionTypographyValue("language", default: "auto") }
    }
    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        model.setCaptionTypography("language", t.isEmpty ? "auto" : t)
        if model.lastError != nil { text = model.captionTypographyValue("language", default: "auto") }
    }
}
