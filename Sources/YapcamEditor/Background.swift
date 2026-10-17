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
            PillPicker(selection: Binding(get: { effectiveMode }, set: { newMode in choose(newMode) }),
                       options: Mode.allCases.map { ($0.rawValue, $0) }, accessibilityTitle: "Background type")
            switch effectiveMode {
            case .wallpaper: WallpaperBrowser(model: model)
            case .gradient:
                ColorRow(model: model, title: "From", path: "canvas.background.color")
                ColorRow(model: model, title: "To", path: "canvas.background.color2")
                GradientExtras(model: model)
                NumberRow(model: model, title: "Angle", path: "canvas.background.angle_deg", range: 0...360, unit: "°", format: "%.0f", defaultValue: 45)
            case .color:
                ColorRow(model: model, title: "Color", path: "canvas.background.color")
                Button { model.randomizeBackgroundColor() } label: { Label("Random colour", systemImage: "dice") }.buttonStyle(.borderless)
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
            NumberRow(model: model, title: "Rounded corners", path: "canvas.radius", range: 0...128, unit: "pt", format: "%.0f", defaultValue: model.factoryDefault(radius: true), snaps: [0, 12, 16, 20, 26])
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

/// Inset border: toggle (restores the last-used inset, else size 4 / 25 % grey), size 0.125–24, colour with opacity, 2-D origin pad.
struct InsetRows: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        Toggle("Inset border", isOn: Binding(get: { model.number("canvas.inset") > 0 }, set: { model.setInsetEnabled($0) }))
        if model.number("canvas.inset") > 0 {
            NumberRow(model: model, title: "Inset size", path: "canvas.inset", range: EditorModel.insetRange, unit: "pt", format: "%.2f", defaultValue: EditorModel.insetFallback.size)
            ColorRow(model: model, title: "Inset color", path: "canvas.inset_color", opacity: true)
            InsetOriginPad(model: model)
        }
    }
}

extension EditorModel {
    static let insetRange = 0.125...24.0
    static let insetFallback = (size: 4.0, color: [0.533, 0.533, 0.533, 0.25])
    /// Turning it off remembers size and colour; turning it on restores them (or the fallback), in one undo step.
    public func setInsetEnabled(_ on: Bool) {
        if !on {
            let size = number("canvas.inset"), color = self.color("canvas.inset_color")
            if size > 0 { lastInset = (size, color) }
            set("canvas.inset", number: 0); return
        }
        let r = lastInset ?? Self.insetFallback
        setMany([("canvas.inset", .number(r.size)), ("canvas.inset_color", .array(r.color.map { .number($0) }))])
    }
}

/// 16:9 pad: drag the dot to weight the border toward a side (`canvas.inset_origin`, −1…1 each); previews while dragging, one undo step on release.
struct InsetOriginPad: View {
    @ObservedObject var model: EditorModel
    @State private var dot: CGPoint?              // −1…1 while dragging
    private func current() -> CGPoint { let v = model.numbers("canvas.inset_origin"); return CGPoint(x: v.first ?? 0, y: v.count > 1 ? v[1] : 0) }
    var body: some View {
        SliderRow("Border position") {
            GeometryReader { g in
                let p = dot ?? current()
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(EditorTheme.control)
                    RoundedRectangle(cornerRadius: 6).strokeBorder(EditorTheme.hairline)
                    Path { path in
                        path.move(to: CGPoint(x: g.size.width / 2, y: 4)); path.addLine(to: CGPoint(x: g.size.width / 2, y: g.size.height - 4))
                        path.move(to: CGPoint(x: 4, y: g.size.height / 2)); path.addLine(to: CGPoint(x: g.size.width - 4, y: g.size.height / 2))
                    }.stroke(EditorTheme.hairline, lineWidth: 1)
                    Circle().fill(Color.accentColor).frame(width: 12, height: 12)
                        .position(x: (p.x + 1) / 2 * g.size.width, y: (p.y + 1) / 2 * g.size.height)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in dot = CGPoint(x: min(max(v.location.x / g.size.width * 2 - 1, -1), 1), y: min(max(v.location.y / g.size.height * 2 - 1, -1), 1)) }
                    .onEnded { _ in if let d = dot { dot = nil; model.set("canvas.inset_origin", .array([.number(d.x), .number(d.y)])) } })
            }
            .aspectRatio(16.0 / 9, contentMode: .fit).frame(maxWidth: 150)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Border position")
        .accessibilityValue(String(format: "%.0f percent across, %.0f percent down", (current().x + 1) * 50, (current().y + 1) * 50))
        .accessibilityAdjustableAction { dir in
            let c = current(), step = dir == .increment ? 0.25 : -0.25
            model.set("canvas.inset_origin", .array([.number(min(max(c.x + step, -1), 1)), .number(c.y)]))
        }
        if current() != .zero { Button("Center the border") { model.set("canvas.inset_origin", .array([.number(0), .number(0)])) }.buttonStyle(.borderless) }
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
        let categories = ["all", "favourites"] + (Array(NSOrderedSet(array: all.map(\.category))) as? [String] ?? [])
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(categories, id: \.self) { c in
                    Button { category = c } label: { if c == "favourites" { Label("Favourites", systemImage: "star.fill").labelStyle(.titleAndIcon) } else { Text(c.capitalized) } }
                        .buttonStyle(.plain).font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(category == c ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07), in: Capsule())
                        .accessibilityAddTraits(category == c ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 8)], spacing: 8) {
            ForEach(all.filter { category == "all" || (category == "favourites" ? model.favouriteWallpapers.contains($0.id) : $0.category == category) }) { w in
                Button { model.applyWallpaper(id: w.id) } label: {
                    WallpaperThumb(model: model, info: w, busy: model.wallpaperBusy == w.id, selected: model.selectedWallpaperID == w.id)
                }
                .buttonStyle(.plain).disabled(model.wallpaperBusy != nil)
                .help(w.title).accessibilityLabel("Wallpaper \(w.title)")
                .contextMenu { Button(model.favouriteWallpapers.contains(w.id) ? "Remove from favourites" : "Add to favourites") { model.toggleFavouriteWallpaper(w.id) } }
                .accessibilityAction(named: model.favouriteWallpapers.contains(w.id) ? "Remove from favourites" : "Add to favourites") { model.toggleFavouriteWallpaper(w.id) }
                .accessibilityAddTraits(model.selectedWallpaperID == w.id ? [.isButton, .isSelected] : .isButton)
            }
        }
        if category == "favourites" && model.favouriteWallpapers.isEmpty { Text("Right-click a wallpaper to add it here.").font(.caption).foregroundStyle(.secondary) }
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
            LabeledPills("Shadow", selection: Binding(get: { model.string("canvas.shadow.style", default: "classic") }, set: { model.set("canvas.shadow.style", string: $0) }), options: [("Classic", "classic"), ("Directional", "directional")])
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
