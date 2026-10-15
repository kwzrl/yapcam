import SwiftUI
import UniformTypeIdentifiers

/// "Background" inspector panel: Wallpaper | Gradient | Color | Image | Blur, then the frame sliders.
struct BackgroundPanel: View {
    @ObservedObject var model: EditorModel
    enum Mode: String, CaseIterable, Identifiable {
        case wallpaper = "Wallpaper", gradient = "Gradient", color = "Color", image = "Image", blur = "Blur"
        var id: String { rawValue }
    }
    @State private var mode: Mode?

    private var kind: String { model.string("canvas.background.kind", default: "solid") }
    private var effectiveMode: Mode {
        if let mode { return mode }
        switch kind {
        case "gradient": return model.selectedWallpaperID == nil ? .gradient : .wallpaper
        case "image": return model.selectedWallpaperID == nil ? .image : .wallpaper
        case "blurred_screen": return .blur
        default: return .color
        }
    }

    var body: some View {
        Section {
            Picker("Background type", selection: Binding(get: { effectiveMode }, set: { newMode in choose(newMode) })) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().accessibilityLabel("Background type")
            switch effectiveMode {
            case .wallpaper: WallpaperBrowser(model: model)
            case .gradient:
                ColorRow(model: model, title: "From", path: "canvas.background.color")
                ColorRow(model: model, title: "To", path: "canvas.background.color2")
                NumberRow(model: model, title: "Angle", path: "canvas.background.angle_deg", range: 0...360, unit: "°", format: "%.0f", defaultValue: 45)
            case .color:
                ColorRow(model: model, title: "Color", path: "canvas.background.color")
                HexField(model: model, path: "canvas.background.color")
            case .image:
                Button("Choose image…") { chooseImage() }
                Text(kind == "image" && model.selectedWallpaperID == nil ? "An image is used as the background." : "Pick a picture to use behind the screen.")
                    .font(.caption).foregroundStyle(.secondary)
            case .blur:
                Text("The recording itself, blurred, fills the background.").font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Look") {
            if effectiveMode == .blur || kind == "blurred_screen" {
                NumberRow(model: model, title: "Background blur", path: "canvas.background.blur", range: 0...80, format: "%.0f", defaultValue: 24)
            }
            NumberRow(model: model, title: "Padding", path: "canvas.padding", range: 0...200, unit: "pt", format: "%.0f", defaultValue: 48)
            NumberRow(model: model, title: "Rounded corners", path: "canvas.radius", range: 0...128, unit: "pt", format: "%.0f", defaultValue: 18)
            InsetRows(model: model)
            NumberRow(model: model, title: "Shadow size", path: "canvas.shadow.radius", range: 0...80, unit: "pt", format: "%.0f", defaultValue: 24)
            NumberRow(model: model, title: "Shadow intensity", path: "canvas.shadow.opacity", range: 0...0.6, defaultValue: 0.3)
            NumberRow(model: model, title: "Shadow distance", path: "canvas.shadow.offset_y", range: 0...48, unit: "pt", format: "%.0f", defaultValue: 8)
            NumberRow(model: model, title: "Texture", path: "canvas.background.noise", range: 0...1, defaultValue: 0)
            ToggleRow(model: model, title: "Window frame", path: "canvas.window_chrome")
        }
    }

    private func choose(_ m: Mode) {
        mode = m
        switch m {
        case .gradient: if kind != "gradient" { model.set("canvas.background.kind", string: "gradient") }
        case .color: if kind != "solid" { model.set("canvas.background.kind", string: "solid") }
        case .blur: if kind != "blurred_screen" { model.set("canvas.background.kind", string: "blurred_screen") }
        case .wallpaper, .image: break
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.importBackgroundImage(url) }
    }
}

struct InsetRows: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        Toggle("Inset border", isOn: Binding(get: { model.number("canvas.inset") > 0 }, set: { model.set("canvas.inset", number: $0 ? 4 : 0) }))
        if model.number("canvas.inset") > 0 {
            NumberRow(model: model, title: "Inset width", path: "canvas.inset", range: 1...24, unit: "pt", format: "%.0f", defaultValue: 4)
            ColorRow(model: model, title: "Inset color", path: "canvas.inset_color", opacity: true)
        }
    }
}

/// #RRGGBB entry for a color setting; commits on Return.
struct HexField: View {
    @ObservedObject var model: EditorModel
    let path: String
    @State private var text = ""
    var body: some View {
        TextField("Hex", text: $text).font(.system(.body, design: .monospaced))
            .onSubmit { if let c = Self.parse(text) { model.set(path, color: c) } else { text = Self.format(model.color(path)) } }
            .onAppear { text = Self.format(model.color(path)) }
            .onChange(of: model.revision) { _, _ in text = Self.format(model.color(path)) }
            .accessibilityLabel("Hex color")
    }
    static func format(_ c: [Double]) -> String {
        String(format: "#%02X%02X%02X", Int((c[0] * 255).rounded()), Int((c[1] * 255).rounded()), Int((c[2] * 255).rounded()))
    }
    static func parse(_ s: String) -> [Double]? {
        var t = s.trimmingCharacters(in: .whitespaces); if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        return [Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255, 1]
    }
}

/// Category chips and a thumbnail grid of the original wallpapers, plus "Pick random".
struct WallpaperBrowser: View {
    @ObservedObject var model: EditorModel
    @State private var category = "all"
    var body: some View {
        let all = model.wallpapers
        let categories = ["all"] + (Array(NSOrderedSet(array: all.map(\.category))) as? [String] ?? [])
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(categories, id: \.self) { c in
                    Button(c.capitalized) { category = c }
                        .buttonStyle(.plain).font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(category == c ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07), in: Capsule())
                        .accessibilityAddTraits(category == c ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 8)], spacing: 8) {
            ForEach(all.filter { category == "all" || $0.category == category }) { w in
                Button { model.applyWallpaper(id: w.id) } label: {
                    WallpaperThumb(model: model, info: w, busy: model.wallpaperBusy == w.id, selected: model.selectedWallpaperID == w.id)
                }
                .buttonStyle(.plain).disabled(model.wallpaperBusy != nil)
                .help(w.title).accessibilityLabel("Wallpaper \(w.title)")
                .accessibilityAddTraits(model.selectedWallpaperID == w.id ? [.isButton, .isSelected] : .isButton)
            }
        }
        Button { model.applyRandomWallpaper() } label: { Label("Pick random", systemImage: "dice") }
            .disabled(model.wallpaperBusy != nil)
    }
}
