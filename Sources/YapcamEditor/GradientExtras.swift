import SwiftUI
import AppKit
import YapcamDesign

/// Own gradient presets (start → end), 8 per row like the reference's grid, plus a hue slider and a randomize button.
enum GradientPresets {
    static let all: [(String, [Double], [Double])] = {
        func c(_ hex: UInt32) -> [Double] { [Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255, 1] }
        return [
            ("Dusk", c(0x4776E6), c(0x8E54E9)), ("Ember", c(0xF7971E), c(0xFF512F)), ("Lagoon", c(0x2BC0E4), c(0x1B4E9B)), ("Meadow", c(0x56AB2F), c(0xA8E063)),
            ("Rose", c(0xEE9CA7), c(0xFFDDE1)), ("Slate", c(0x485563), c(0x29323C)), ("Aurora", c(0x00C9FF), c(0x92FE9D)), ("Plum", c(0x7F00FF), c(0xE100FF)),
            ("Sunset", c(0xFF7E5F), c(0xFEB47B)), ("Ocean", c(0x1CB5E0), c(0x000851)), ("Mint", c(0x0BAB64), c(0x3BB78F)), ("Candy", c(0xFC5C7D), c(0x6A82FB)),
            ("Sand", c(0xD3CCE3), c(0xE9E4F0)), ("Midnight", c(0x232526), c(0x414345)), ("Citrus", c(0xF2994A), c(0xF2C94C)), ("Frost", c(0xC9D6FF), c(0xE2E2E2)),
        ]
    }()
    static func rotateHue(_ rgba: [Double], by degrees: Double) -> [Double] {
        let n = NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        n.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        var nh = (Double(h) * 360 + degrees).truncatingRemainder(dividingBy: 360); if nh < 0 { nh += 360 }
        let out = NSColor(hue: nh / 360, saturation: s, brightness: b, alpha: a).usingColorSpace(.sRGB) ?? n
        return [Double(out.redComponent), Double(out.greenComponent), Double(out.blueComponent), rgba[3]]
    }
    static func hue(_ rgba: [Double]) -> Double {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Double(h) * 360
    }
}

extension EditorModel {
    /// Rotates the hue of both gradient stops together (one undo step).
    public func rotateGradientHue(by degrees: Double) {
        guard abs(degrees) > 0.01 else { return }
        setMany([("canvas.background.color", .array(GradientPresets.rotateHue(color("canvas.background.color"), by: degrees).map { .number($0) })),
                 ("canvas.background.color2", .array(GradientPresets.rotateHue(color("canvas.background.color2"), by: degrees).map { .number($0) }))])
    }
    public func applyGradientPreset(_ i: Int) {
        guard GradientPresets.all.indices.contains(i) else { return }
        let p = GradientPresets.all[i]
        setMany([("canvas.background.kind", .string("gradient")), ("canvas.background.color", .array(p.1.map { .number($0) })), ("canvas.background.color2", .array(p.2.map { .number($0) }))])
    }
    public func randomizeGradient() { applyGradientPreset(Int.random(in: 0..<GradientPresets.all.count)) }
    public func randomizeBackgroundColor() {
        let c = (GradientPresets.all.randomElement() ?? GradientPresets.all[0]).1
        set("canvas.background.color", .array(c.map { .number($0) }))
    }
}

struct GradientExtras: View {
    @ObservedObject var model: EditorModel
    private var hue: Double { GradientPresets.hue(model.color("canvas.background.color")) }
    var body: some View {
        CommitSlider(title: "Hue", range: 0...360, get: { hue },
                     commit: { h in model.rotateGradientHue(by: h.rounded() - hue.rounded()) },      // whole degrees
                     text: { "\(Int($0))°" })
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
            ForEach(Array(GradientPresets.all.enumerated()), id: \.offset) { i, p in preset(i, p) }
        }
        InspectorAction("Random gradient", symbol: "dice") { model.randomizeGradient() }
    }

    private func preset(_ i: Int, _ p: (String, [Double], [Double])) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let on = model.color("canvas.background.color") == p.1 && model.color("canvas.background.color2") == p.2
        return Button { model.applyGradientPreset(i) } label: {
            LinearGradient(colors: [Color(.sRGB, red: p.1[0], green: p.1[1], blue: p.1[2]), Color(.sRGB, red: p.2[0], green: p.2[1], blue: p.2[2])],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(shape).aspectRatio(1, contentMode: .fit)
                .overlay(shape.strokeBorder(Color.white.opacity(on ? 1 : 0.18), lineWidth: on ? 2 : 0.5))
        }
        .buttonStyle(PressStyle()).help(p.0).accessibilityLabel("Gradient \(p.0)")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
