import SwiftUI

struct InspectorView: View {
    @ObservedObject var model: EditorModel
    // Slider drags are committed on release so one drag = one undo step.
    @State private var padding: Double = 48
    @State private var radius: Double = 12
    @State private var shadow: Double = 0.4
    @State private var background: Color = Color(hex: "#1F2937")

    var body: some View {
        Form {
            if let z = model.selectedZoom {
                Section("Zoom") {
                    LabeledContent("Start") { Text(formatTimecode(z.startNs)).monospacedDigit() }
                    LabeledContent("Duration") { Text(formatTimecode(z.endNs - z.startNs)).monospacedDigit() }
                    LabeledContent("Scale") {
                        HStack {
                            Slider(value: Binding(get: { z.scale }, set: { model.setZoomScale(id: z.id, $0) }), in: 1...6)
                            Text(String(format: "%.1f×", z.scale)).monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                    Button("Delete zoom", role: .destructive) { model.deleteSelection() }
                }
            }
            Section("Background") {
                ColorPicker("Color", selection: $background, supportsOpacity: false)
                    .onChange(of: background) { _, c in model.setCanvasString("canvas.background", c.hexString) }
            }
            Section("Frame") {
                slider("Padding", $padding, 0...200, path: "canvas.padding", unit: "pt")
                slider("Corner radius", $radius, 0...48, path: "canvas.radius", unit: "pt")
                slider("Shadow", $shadow, 0...1, path: "canvas.shadow", unit: "")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: syncFromModel)
        .onChange(of: model.revision) { _, _ in syncFromModel() }
    }

    private func syncFromModel() {
        let c = model.canvas
        padding = c.padding; radius = c.cornerRadius; shadow = c.shadow; background = Color(hex: c.backgroundColorHex)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, path: String, unit: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range) { editing in if !editing { model.setCanvasNumber(path, value.wrappedValue) } }
                Text(unit.isEmpty ? String(format: "%.2f", value.wrappedValue) : "\(Int(value.wrappedValue)) \(unit)")
                    .monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count != 6 { s = "000000" }
        let v = UInt32(s, radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
