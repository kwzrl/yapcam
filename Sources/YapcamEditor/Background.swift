import SwiftUI
import UniformTypeIdentifiers
import YapcamDesign

/// "Background" inspector panel: Wallpaper | Gradient | Color | Image | Blur, then the look of the frame.
struct BackgroundPanel: View {
    @ObservedObject var model: EditorModel
    enum Mode: String, CaseIterable, Identifiable {
        case wallpaper = "Wallpaper", gradient = "Gradient", color = "Color", image = "Image", blur = "Blur"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .wallpaper: "photo"; case .gradient: "square.bottomhalf.filled"; case .color: "paintpalette"
            case .image: "photo.badge.plus"; case .blur: "aqi.medium"
            }
        }
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
        VStack(alignment: .leading, spacing: 0) {
            InspectorGroup(first: true) {
                typePicker
                modeContent
            }
            InspectorGroup("Look") { LookRows(model: model, blur: [.blur, .wallpaper, .image].contains(effectiveMode) || kind == "blurred_screen", screenBlur: effectiveMode == .blur || kind == "blurred_screen") }
        }
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Type").font(Yap.Font.body).foregroundStyle(Yap.label)
                Spacer()
                Text(effectiveMode.rawValue).font(Yap.Font.body).foregroundStyle(Yap.caption)
            }
            HStack(spacing: 2) {
                ForEach(Mode.allCases) { m in
                    SlotButton(symbol: m.symbol, label: m.rawValue, active: effectiveMode == m, compact: true) { choose(m) }
                }
            }
            .padding(.horizontal, -4)
            .accessibilityElement(children: .contain).accessibilityLabel("Background type")
        }
    }

    @ViewBuilder private var modeContent: some View {
        switch effectiveMode {
        case .wallpaper: WallpaperBrowser(model: model)
        case .gradient:
            ColorRow(model: model, title: "From", path: "canvas.background.color")
            ColorRow(model: model, title: "To", path: "canvas.background.color2")
            GradientExtras(model: model)
            NumberRow(model: model, title: "Angle", path: "canvas.background.angle_deg", range: 0...360, unit: "°", format: "%.0f", defaultValue: 45)
        case .color:
            ColorRow(model: model, title: "Color", path: "canvas.background.color")
            InspectorAction("Random color", symbol: "dice") { model.randomizeBackgroundColor() }
        case .image:
            InspectorAction("Choose image…", symbol: "photo.badge.plus") { chooseImage() }
            InspectorNote(kind == "image" && model.selectedWallpaperID == nil ? "An image is used as the background." : "Pick a picture to use behind the screen.")
        case .blur:
            InspectorNote("The recording itself, blurred, fills the background.")
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

/// The frame around the recording: format, padding, corners, shadow, inset border; texture, window frame and quality behind "More".
private struct LookRows: View {
    @ObservedObject var model: EditorModel
    let blur: Bool
    var screenBlur = true         // false: wallpaper / image backgrounds, which start unblurred
    var body: some View {
        ChoiceRow("Format", selection: Binding(get: { AspectPreset(rawValue: model.string("canvas.aspect", default: "source")) ?? .auto },
                                               set: { model.setAspect($0) }),
                  options: AspectPreset.allCases.map { ($0.label, $0) }, forceMenu: true)
        if blur {
            NumberRow(model: model, title: "Background blur", path: "canvas.background.blur", range: 0...100, format: "%.0f", defaultValue: screenBlur ? model.factoryDefault(backgroundBlur: true) : 0)
        }
        PaddingRow(model: model)
        NumberRow(model: model, title: "Rounded corners", path: "canvas.radius", range: 0...128, unit: "pt", format: "%.0f", defaultValue: model.factoryDefault(radius: true), snaps: [0, 12, 16, 20, 26])
        ShadowRows(model: model)
        InsetRows(model: model)
        InspectorMore {
            NumberRow(model: model, title: "Texture", path: "canvas.background.noise", range: 0...1, defaultValue: 0)
            ToggleRow(model: model, title: "Window frame", path: "canvas.window_chrome")
            ScreenQualityRows(model: model)
        }
    }
}

/// Inset border: toggle (restores the last-used inset, else size 4 / 25 % gray), size 0.125–24, color with opacity, 2-D origin pad.
struct InsetRows: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        SwitchRow("Inset border", isOn: Binding(get: { model.number("canvas.inset") > 0 }, set: { model.setInsetEnabled($0) }))
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
    /// Turning it off remembers size and color; turning it on restores them (or the fallback), in one undo step.
    public func setInsetEnabled(_ on: Bool) {
        if !on {
            let size = number("canvas.inset"), color = self.color("canvas.inset_color")
            if size > 0 { lastInset = (size, color) }
            set("canvas.inset", number: 0); return
        }
        // Restore the last use; else the reference's 4 px / 25 % gray. A color the user already stored (not core's factory
        // black-50% or the older white) is kept; only the factory values are replaced.
        let stored = color("canvas.inset_color")
        let isFactory = stored == [0, 0, 0, 0.5] || stored == [1, 1, 1, 1] || stored.allSatisfy { $0 == 0 }
        let r = lastInset ?? (Self.insetFallback.size, isFactory ? Self.insetFallback.color : stored)
        setMany([("canvas.inset", .number(r.size)), ("canvas.inset_color", .array(r.color.map { .number($0) }))])
    }
}

/// 16:9 pad: drag the dot to weight the border toward a side (`canvas.inset_origin`, −1…1 each); previews while dragging, one undo step on release.
struct InsetOriginPad: View {
    @ObservedObject var model: EditorModel
    @State private var dot: CGPoint?              // −1…1 while dragging
    private func current() -> CGPoint { let v = model.numbers("canvas.inset_origin"); return CGPoint(x: v.first ?? 0, y: v.count > 1 ? v[1] : 0) }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Border position").font(Yap.Font.body).foregroundStyle(Yap.label)
            Spacer(minLength: 8)
            pad
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Border position")
        .accessibilityValue(String(format: "%.0f percent across, %.0f percent down", (current().x + 1) * 50, (current().y + 1) * 50))
        .accessibilityAdjustableAction { dir in
            let c = current(), step = dir == .increment ? 0.25 : -0.25
            model.set("canvas.inset_origin", .array([.number(min(max(c.x + step, -1), 1)), .number(c.y)]))
        }
        if current() != .zero { InspectorAction("Center the border") { model.set("canvas.inset_origin", .array([.number(0), .number(0)])) } }
    }

    private var pad: some View {
        GeometryReader { g in
            let p = dot ?? current()
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Yap.recess)
                Path { path in
                    path.move(to: CGPoint(x: g.size.width / 2, y: 4)); path.addLine(to: CGPoint(x: g.size.width / 2, y: g.size.height - 4))
                    path.move(to: CGPoint(x: 4, y: g.size.height / 2)); path.addLine(to: CGPoint(x: g.size.width - 4, y: g.size.height / 2))
                }.stroke(Color.white.opacity(Yap.dockHairline), lineWidth: 1)
                Circle().fill(Color.white).frame(width: 12, height: 12)
                    .shadow(color: .white.opacity(0.3), radius: 6)
                    .position(x: (p.x + 1) / 2 * g.size.width, y: (p.y + 1) / 2 * g.size.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in if let d = PointerMath.pad(v.location, in: g.size) { dot = d } }
                .onEnded { _ in if let d = dot { dot = nil; model.set("canvas.inset_origin", .array([.number(d.x), .number(d.y)])) } })
        }
        .frame(width: 128, height: 72)
    }
}

/// Spatial clean-up and upscaling of the recording (`canvas.screen_quality`; off unless chosen).
struct ScreenQualityRows: View {
    @ObservedObject var model: EditorModel
    private var enabled: Bool { if case .object? = model.value("canvas.screen_quality") { true } else { false } }
    var body: some View {
        SwitchRow("Improve screen quality", isOn: Binding(get: { enabled }, set: { model.set("canvas.screen_quality", $0 ? .object([:]) : .null) }))
        if enabled {
            NumberRow(model: model, title: "Improvement", path: "canvas.screen_quality.improve_quality", range: 0...1, defaultValue: 0.5)
            PickerRow(model: model, title: "Upscaling", path: "canvas.screen_quality.upscaling", options: [("Off", "off"), ("Fast", "fast"), ("Quality", "quality")])
            InspectorNote("Smooths noise and banding and resamples small recordings; it is not an AI enhancement.")
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

/// Category switch and a thumbnail grid of the original wallpapers, plus "Pick random".
struct WallpaperBrowser: View {
    @ObservedObject var model: EditorModel
    @State private var category = "all"
    var body: some View {
        let all = model.wallpapers
        let categories = ["all", "favorites"] + (Array(NSOrderedSet(array: all.map(\.category))) as? [String] ?? [])
        ScrollView(.horizontal, showsIndicators: false) {
            SegmentSwitch(categories.map { (id: $0, title: $0.capitalized) }, selection: $category, height: 26)
        }
        .padding(.horizontal, -4)
        .accessibilityLabel("Wallpaper category")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(all.filter { category == "all" || (category == "favorites" ? model.favoriteWallpapers.contains($0.id) : $0.category == category) }) { w in
                thumb(w)
            }
        }
        if category == "favorites" && model.favoriteWallpapers.isEmpty { InspectorNote("Right-click a wallpaper to add it here.") }
        InspectorAction("Pick random", symbol: "dice") { model.applyRandomWallpaper() }
            .disabled(model.wallpaperBusy != nil)
    }

    private func thumb(_ w: WallpaperInfo) -> some View {
        let favorite = model.favoriteWallpapers.contains(w.id)
        return Button { model.applyWallpaper(id: w.id) } label: {
            WallpaperThumb(model: model, info: w, busy: model.wallpaperBusy == w.id, selected: model.selectedWallpaperID == w.id, favorite: favorite)
        }
        .buttonStyle(PressStyle()).disabled(model.wallpaperBusy != nil)
        .help(w.title).accessibilityLabel("Wallpaper \(w.title)")
        .contextMenu { Button(favorite ? "Remove from favorites" : "Add to favorites") { model.toggleFavoriteWallpaper(w.id) } }
        .accessibilityAction(named: favorite ? "Remove from favorites" : "Add to favorites") { model.toggleFavoriteWallpaper(w.id) }
        .accessibilityAddTraits(model.selectedWallpaperID == w.id ? [.isButton, .isSelected] : .isButton)
    }
}

struct WallpaperThumb: View {
    @ObservedObject var model: EditorModel
    let info: WallpaperInfo
    let busy: Bool
    var selected = false
    var favorite = false
    @State private var image: CGImage?
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        ZStack {
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(16.0 / 10, contentMode: .fill) }
            else { Rectangle().fill(Color.white.opacity(0.06)) }
            if busy { ProgressView().controlSize(.small).tint(Yap.label) }
        }
        .aspectRatio(16.0 / 10, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(selected ? 1 : 0.15), lineWidth: selected ? 2 : 0.5))
        .overlay(alignment: .topTrailing) {
            if favorite { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.white).padding(4).shadow(radius: 2) }
        }
        .task { image = await model.project.wallpaperThumbnail(id: info.id) }
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
            ChoiceRow("Shadow", selection: Binding(get: { model.string("canvas.shadow.style", default: "classic") }, set: { model.set("canvas.shadow.style", string: $0) }), options: [("Classic", "classic"), ("Directional", "directional")])
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
