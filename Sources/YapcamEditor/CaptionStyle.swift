import SwiftUI

/// Caption look as in the reference: size as a fraction of the output height (0.05–0.125), Dark or Light text,
/// bottom or centered position. Applies to every caption and is remembered for new ones.
public struct CaptionLook: Equatable, Sendable {
    public var size = 0.07           // fraction of the output height
    public var light = false         // false: white text on a dark plate, true: dark text on a light plate
    public var center = false        // false: bottom, true: centered
    public static let sizeRange = 0.05...0.125
    public init() {}
}

extension CaptionLook {
    func apply(to t: TextItem, outputHeight h: Double) -> TextItem {
        var t = t
        t.fontSize = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound) * h
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
    @State private var size = 0.07
    var body: some View {
        let look = model.captionLook
        LabeledContent("Size") {
            HStack {
                Slider(value: $size, in: CaptionLook.sizeRange) { e in if !e { var l = look; l.size = size; model.setCaptionLook(l) } }
                    .accessibilityLabel("Caption size").accessibilityValue(String(format: "%.1f percent of the height", size * 100))
                Text(String(format: "%.1f%%", size * 100)).monospacedDigit().frame(width: 46, alignment: .trailing)
            }
        }
        Picker("Color", selection: Binding(get: { look.light }, set: { v in var l = look; l.light = v; model.setCaptionLook(l) })) {
            Text("Dark").tag(false); Text("Light").tag(true)
        }.pickerStyle(.segmented)
        Picker("Position", selection: Binding(get: { look.center }, set: { v in var l = look; l.center = v; model.setCaptionLook(l) })) {
            Text("Bottom").tag(false); Text("Center").tag(true)
        }.pickerStyle(.segmented)
        Picker("Font", selection: Binding(get: { model.captionTypographyValue("font_family", default: "sans") }, set: { model.setCaptionTypography("font_family", $0) })) {
            Text("Sans").tag("sans"); Text("Serif").tag("serif"); Text("Mono").tag("mono")
        }
        Picker("Reveal", selection: Binding(get: { model.captionTypographyValue("reveal", default: "line") }, set: { model.setCaptionTypography("reveal", $0) })) {
            Text("Whole line").tag("line"); Text("Word by word").tag("word")
        }.pickerStyle(.segmented)
        Picker("Growth", selection: Binding(get: { model.captionTypographyValue("growth", default: "full") }, set: { model.setCaptionTypography("growth", $0) })) {
            Text("Full box").tag("full"); Text("Expanding").tag("expanding"); Text("Centered").tag("centered")
        }
        Picker("Entrance", selection: Binding(get: { model.captionTypographyValue("entrance", default: "appear") }, set: { model.setCaptionTypography("entrance", $0) })) {
            Text("Appear").tag("appear"); Text("Fade").tag("fade"); Text("Slide").tag("slide")
        }
        CaptionLanguageField(model: model)
        .onAppear { size = look.size }
    }
}

/// Caption language tag ("auto" or e.g. "en-US"); core validates the tag, the speech service decides what it can recognise.
struct CaptionLanguageField: View {
    @ObservedObject var model: EditorModel
    @State private var text = "auto"
    var body: some View {
        TextField("Language", text: $text, prompt: Text("auto, en-US, de…"))
            .onSubmit { commit() }
            .onAppear { text = model.captionTypographyValue("language", default: "auto") }
            .accessibilityLabel("Caption language")
    }
    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        model.setCaptionTypography("language", t.isEmpty ? "auto" : t)
        if model.lastError != nil { text = model.captionTypographyValue("language", default: "auto") }
    }
}
