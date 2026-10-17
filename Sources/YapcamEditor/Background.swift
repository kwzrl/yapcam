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
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).accessibilityLabel("Background type")
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
                NumberRow(model: model, title: "Background blur", path: "canvas.background.blur", range: 0...100, format: "%.0f", defaultValue: model.factoryDefault(backgroundBlur: true))
            }
            PaddingRow(model: model)
            NumberRow(model: model, title: "Rounded corners", path: "canvas.radius", range: 0...128, unit: "pt", format: "%.0f", defaultValue: model.factoryDefault(radius: true))
            InsetRows(model: model)
            ShadowRows(model: model)
            NumberRow(model: model, title: "Texture", path: "canvas.background.noise", range: 0...1, defaultValue: 0)
            ToggleRow(model: model, title: "Window frame", path: "canvas.window_chrome")
            ScreenQualityRows(model: model)
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
            InsetOriginRows(model: model)
        }
    }
}

/// Moves the inset border toward an edge (`canvas.inset_origin` [x, y] in -1…1; 0 = centered).
struct InsetOriginRows: View {
    @ObservedObject var model: EditorModel
    @State private var x = 0.0
    @State private var y = 0.0
    private func current() -> (Double, Double) { let v = model.numbers("canvas.inset_origin"); return (v.first ?? 0, v.count > 1 ? v[1] : 0) }
    private func commit() { model.set("canvas.inset_origin", .array([.number(x), .number(y)])) }
    var body: some View {
        LabeledContent("Border position, left ↔ right") {
            Slider(value: $x, in: -1...1) { e in if !e { commit() } }.accessibilityLabel("Inset border horizontal position")
        }
        LabeledContent("Border position, top ↔ bottom") {
            Slider(value: $y, in: -1...1) { e in if !e { commit() } }.accessibilityLabel("Inset border vertical position")
        }
        if x != 0 || y != 0 { Button("Center the border") { x = 0; y = 0; commit() }.buttonStyle(.borderless) }
        Color.clear.frame(height: 0)
            .onAppear { (x, y) = current() }
            .onChange(of: model.revision) { _, _ in (x, y) = current() }
    }
}

/// Spatial clean-up and upscaling of the recording (`canvas.screen_quality`; off unless chosen).
struct ScreenQualityRows: View {
    @ObservedObject var model: EditorModel
    private var enabled: Bool { if case .object? = model.value("canvas.screen_quality") { true } else { false } }
    var body: some View {
        Toggle("Improve screen quality", isOn: Binding(get: { enabled }, set: { model.set("canvas.screen_quality", $0 ? .object([:]) : .null) }))
        if enabled {
            NumberRow(model: model, title: "Improvement", path: "canvas.screen_quality.improve_quality", range: 0...1, defaultValue: 0.5)
            PickerRow(model: model, title: "Upscaling", path: "canvas.screen_quality.upscaling", options: [("Off", "off"), ("Fast", "fast"), ("Quality", "quality")])
            Text("Smooths noise and banding and resamples small recordings; it is not an AI enhancement.").font(.caption).foregroundStyle(.secondary)
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

/// Padding: a percentage of the shorter canvas edge in new projects (`canvas.padding_ratio`), output pixels in older ones.
struct PaddingRow: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        if model.usesPaddingRatio {
            NumberRow(model: model, title: "Padding", path: "canvas.padding_ratio", range: 0...0.25, unit: "%", format: "%.0f", scale: 100, defaultValue: 0.10)
        } else {
            NumberRow(model: model, title: "Padding", path: "canvas.padding", range: 0...200, unit: "pt", format: "%.0f", defaultValue: 48)
        }
    }
}

/// Shadow: Classic (size, intensity, distance) or Directional (intensity, distance, angle, blur) when core stores a style.
struct ShadowRows: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        if model.hasShadowStyle {
            Picker("Shadow", selection: Binding(get: { model.string("canvas.shadow.style", default: "classic") }, set: { model.set("canvas.shadow.style", string: $0) })) {
                Text("Classic").tag("classic"); Text("Directional").tag("directional")
            }.pickerStyle(.segmented)
        }
        NumberRow(model: model, title: "Shadow intensity", path: "canvas.shadow.opacity", range: 0...0.6, defaultValue: 0.3)
        if model.hasShadowStyle && model.string("canvas.shadow.style") == "directional" {
            NumberRow(model: model, title: "Distance", path: "canvas.shadow.distance", range: 0...100, unit: "pt", format: "%.0f", defaultValue: 25)
            NumberRow(model: model, title: "Angle", path: "canvas.shadow.angle_deg", range: 0...180, unit: "°", format: "%.0f", defaultValue: 45)
            NumberRow(model: model, title: "Blur", path: "canvas.shadow.blur", range: 0...30, format: "%.0f", defaultValue: 20)
        } else {
            NumberRow(model: model, title: "Shadow size", path: "canvas.shadow.radius", range: 0...80, unit: "pt", format: "%.0f", defaultValue: 24)
            NumberRow(model: model, title: "Shadow distance", path: "canvas.shadow.offset_y", range: 0...48, unit: "pt", format: "%.0f", defaultValue: 8)
        }
    }
}

extension EditorModel {
    /// Core's factory-default revision of this project (0 = created before the reference defaults).
    public var defaultsRevision: Int { Int(number("defaults_revision", default: 0)) }
    public var usesPaddingRatio: Bool { if case .number? = value("canvas.padding_ratio") { true } else { false } }
    public var hasShadowStyle: Bool { if case .string? = value("canvas.shadow.style") { true } else { false } }
    public var usesCursorPoints: Bool { if case .number? = value("cursor.size_points") { true } else { false } }
    /// Reset targets follow the project's defaults revision (new projects: corners 16, background blur 0, motion blur 1).
    func factoryDefault(radius: Bool = false, backgroundBlur: Bool = false) -> Double {
        if radius { return defaultsRevision >= 1 ? 16 : 18 }
        if backgroundBlur { return defaultsRevision >= 1 ? 0 : 24 }
        return 0
    }
    var factoryMotionBlur: Double { defaultsRevision >= 1 ? 1 : 0 }
}
