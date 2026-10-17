import AppKit
import SwiftUI
import YapcamDesign

// The full inspector of today's editor (Sources/YapcamEditor/Inspector.swift) in the glass look: the icon rail
// picks one of the ten sections, every setting is there; a selected element adds its own settings on top.
// Mock-up: values live in `MockSettings`, the preview reads the ones it can show.

// MARK: - Settings

@MainActor @Observable final class MockSettings {
    var numbers: [String: Double] = [:]
    var flags: [String: Bool] = [:]
    var choices: [String: String] = [:]
    var colors: [String: Color] = [:]

    func number(_ k: String, _ d: Double) -> Double { numbers[k] ?? d }
    func flag(_ k: String, _ d: Bool = false) -> Bool { flags[k] ?? d }
    func choice(_ k: String, _ d: String) -> String { choices[k] ?? d }
    func color(_ k: String, _ d: Color) -> Color { colors[k] ?? d }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case background, cursor, cameraLayout, cameraStyle, captions, transcript, audio, keys, animations, extras
    var id: Self { self }
    var title: String {
        switch self {
        case .background: return "Background"
        case .cursor: return "Cursor"
        case .cameraLayout: return "Camera layout"
        case .cameraStyle: return "Camera style"
        case .captions: return "Captions"
        case .transcript: return "Edit by transcript"
        case .audio: return "Audio"
        case .keys: return "Keyboard shortcuts"
        case .animations: return "Animations"
        case .extras: return "Text, regions & intro/outro"
        }
    }
    var symbol: String {
        switch self {
        case .background: return "photo.on.rectangle.angled"
        case .cursor: return "cursorarrow"
        case .cameraLayout: return "rectangle.inset.filled.and.person.filled"
        case .cameraStyle: return "person.crop.rectangle"
        case .captions: return "captions.bubble"
        case .transcript: return "text.quote"
        case .audio: return "speaker.wave.2"
        case .keys: return "command"
        case .animations: return "point.topleft.down.curvedto.point.bottomright.up"
        case .extras: return "textformat"
        }
    }
    /// ⌘1 … ⌘0, in rail order.
    var shortcut: String { String((Self.allCases.firstIndex(of: self)! + 1) % 10) }
}

enum MockGradients {
    /// The editor's own gradient presets (GradientExtras.swift), start → end.
    static let all: [(String, UInt32, UInt32)] = [
        ("Dusk", 0x4776E6, 0x8E54E9), ("Ember", 0xF7971E, 0xFF512F), ("Lagoon", 0x2BC0E4, 0x1B4E9B), ("Meadow", 0x56AB2F, 0xA8E063),
        ("Rose", 0xEE9CA7, 0xFFDDE1), ("Slate", 0x485563, 0x29323C), ("Aurora", 0x00C9FF, 0x92FE9D), ("Plum", 0x7F00FF, 0xE100FF),
        ("Sunset", 0xFF7E5F, 0xFEB47B), ("Ocean", 0x1CB5E0, 0x000851), ("Mint", 0x0BAB64, 0x3BB78F), ("Candy", 0xFC5C7D, 0x6A82FB),
        ("Sand", 0xD3CCE3, 0xE9E4F0), ("Midnight", 0x232526, 0x414345), ("Citrus", 0xF2994A, 0xF2C94C), ("Frost", 0xC9D6FF, 0xE2E2E2),
    ]
    static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    /// Stand-ins for the wallpaper library: (title, category, colours).
    static let wallpapers: [(String, String, [Color])] = [
        ("Dune", "Nature", [color(0xE8B07A), color(0x8A4B2F)]), ("Fjord", "Nature", [color(0x5D7C8C), color(0x1E2B33)]),
        ("Moss", "Nature", [color(0x7FA36B), color(0x2E4A2B)]), ("Ember", "Abstract", [color(0xFF7E5F), color(0x6A2C70)]),
        ("Haze", "Abstract", [color(0xD6A4E0), color(0x4B3C6E)]), ("Ink", "Abstract", [color(0x3A3A48), color(0x0E0E14)]),
        ("Peach", "Gradient", [color(0xFFC3A0), color(0xFFAFBD)]), ("Lime", "Gradient", [color(0xD4FC79), color(0x96E6A1)]),
        ("Plum", "Gradient", [color(0xB06AB3), color(0x4568DC)]),
    ]
}

// MARK: - Column

/// Docked at the right edge, full height: the icon rail, a hairline, the section (or the selected element).
struct InspectorColumn: View {
    @Bindable var mock: EditorMock
    static let railWidth: CGFloat = Yap.Grid.bar

    var body: some View {
        HStack(spacing: 0) {
            rail
            Hairline()
            ScrollView {
                content.padding(.horizontal, 12).padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            .id(mock.selection == .none ? AnyHashable(mock.tab) : AnyHashable(mock.selection))
        }
        .frame(maxHeight: .infinity)
        .background(Yap.dock)
    }

    private var rail: some View {
        VStack(spacing: 2) {
            ForEach(InspectorTab.allCases) { t in
                SlotButton(symbol: t.symbol, label: t.title, help: "\(t.title) (⌘\(t.shortcut))",
                           active: mock.tab == t && mock.selection == .none, compact: true) { mock.show(t) }
            }
            Spacer(minLength: 0)
        }
        .padding(Yap.Grid.inset)
        .frame(width: Self.railWidth)
    }

    @ViewBuilder private var content: some View {
        switch mock.selection {
        case .none: SectionContent(mock: mock, s: mock.settings)
        case .clip(let i): ClipInspector(mock: mock, s: mock.settings, index: i)
        case .zoom(let i): ZoomInspector(mock: mock, s: mock.settings, span: mock.zoomSpans[min(i, mock.zoomSpans.count - 1)])
        case .suggestion: SuggestionInspector(mock: mock)
        case .layout(let i): LayoutInspector(mock: mock, s: mock.settings, index: i)
        case .block(let id):
            if let i = mock.blocks.firstIndex(where: { $0.id == id }) { BlockInspector(mock: mock, block: $mock.blocks[i]) }
        }
    }
}

private struct SectionContent: View {
    @Bindable var mock: EditorMock
    let s: MockSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(mock: mock, title: mock.tab.title)
            switch mock.tab {
            case .background: BackgroundSection(s: s)
            case .cursor: CursorSection(s: s)
            case .cameraLayout: CameraLayoutSection(mock: mock, s: s)
            case .cameraStyle: CameraStyleSection(s: s)
            case .captions: CaptionsSection(s: s)
            case .transcript: TranscriptSection(mock: mock, s: s)
            case .audio: AudioSection(s: s)
            case .keys: KeysSection(s: s)
            case .animations: AnimationsSection(s: s)
            case .extras: ExtrasSection(mock: mock, s: s)
            }
        }
    }
}

struct InspectorHeader: View {
    @Bindable var mock: EditorMock
    let title: String
    var detail = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Yap.title).lineLimit(1)
            if !detail.isEmpty { Text(detail).technical().lineLimit(1) }
            Spacer(minLength: 0)
            if mock.selection != .none {
                SlotButton(symbol: "xmark", label: "Done", help: "Back to \(mock.tab.title) (Esc)", active: false, compact: true) {
                    mock.selection = .none
                }
            }
        }
        .frame(height: Yap.Grid.cell + 4)
    }
}

// MARK: - Rows bound to the settings

/// A group of settings under a quiet caption; groups are separated by a hairline.
private struct SettingsGroup<Content: View>: View {
    let title: String
    var first = false
    @ViewBuilder let content: Content

    init(_ title: String, first: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title; self.first = first; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !first { Hairline(axis: .horizontal).padding(.bottom, 2) }
            if !title.isEmpty { Text(title).font(Yap.Font.caption).foregroundStyle(Yap.caption) }
            content
        }
        .padding(.bottom, 16)
    }
}

/// Fine-tuning stays folded until asked for.
private struct More<Content: View>: View {
    var title = "More"
    @ViewBuilder let content: Content
    @State private var open = false

    var body: some View {
        DisclosureSection(title, open: $open) {
            VStack(alignment: .leading, spacing: 14) { content }
        }
        .padding(.horizontal, -8)
    }
}

private struct Num: View {
    let s: MockSettings
    let title: String
    let key: String
    let range: ClosedRange<Double>
    let format: String
    let initial: Double

    init(_ s: MockSettings, _ title: String, _ key: String, _ range: ClosedRange<Double>, _ format: String, _ initial: Double) {
        self.s = s; self.title = title; self.key = key; self.range = range; self.format = format; self.initial = initial
    }

    var body: some View {
        let span = range.upperBound - range.lowerBound
        ValueSlider(title, value: String(format: format, s.number(key, initial)),
                    amount: Binding(get: { (s.number(key, initial) - range.lowerBound) / span },
                                    set: { s.numbers[key] = range.lowerBound + $0 * span }))
    }
}

private struct Flag: View {
    let s: MockSettings
    let title: String
    let key: String
    let initial: Bool

    init(_ s: MockSettings, _ title: String, _ key: String, _ initial: Bool = false) {
        self.s = s; self.title = title; self.key = key; self.initial = initial
    }

    var body: some View {
        SwitchRow(title, isOn: Binding(get: { s.flag(key, initial) }, set: { s.flags[key] = $0 }))
    }
}

/// Few short choices: a segment switch; more: the system menu.
private struct Pick: View {
    let s: MockSettings
    let title: String
    let key: String
    let options: [String]
    let initial: String

    init(_ s: MockSettings, _ title: String, _ key: String, _ options: [String], _ initial: String) {
        self.s = s; self.title = title; self.key = key; self.options = options; self.initial = initial
    }

    var body: some View {
        let binding = Binding(get: { s.choice(key, initial) }, set: { s.choices[key] = $0 })
        if options.count <= 4 && options.joined().count <= 26 {
            ValueChoice(title, items: options.map { ($0, $0) }, selection: binding)
        } else {
            ChoiceMenuRow(title, options: options, selection: binding)
        }
    }
}

private struct Swatch: View {
    let s: MockSettings
    let title: String
    let key: String
    let initial: Color

    init(_ s: MockSettings, _ title: String, _ key: String, _ initial: Color) {
        self.s = s; self.title = title; self.key = key; self.initial = initial
    }

    var body: some View {
        ColorSwatchRow(title, color: Binding(get: { s.color(key, initial) }, set: { s.colors[key] = $0 }))
    }
}

private struct Info: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        HStack {
            Text(title).font(Yap.Font.body).foregroundStyle(Yap.label)
            Spacer()
            Text(value).technical()
        }
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Yap.Font.caption).foregroundStyle(Yap.faint).fixedSize(horizontal: false, vertical: true)
    }
}

private struct Action: View {
    let title: String
    var symbol: String?
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void = {}) {
        self.title = title; self.symbol = symbol; self.action = action
    }

    var body: some View {
        Button(action: action) {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
        .buttonStyle(CapsuleButtonStyle(.secondary, height: 28))
    }
}

// MARK: - Background

private struct BackgroundSection: View {
    let s: MockSettings
    static let modes: [(String, String)] = [("Wallpaper", "photo"), ("Gradient", "square.bottomhalf.filled"), ("Color", "paintpalette"),
                                            ("Image", "photo.badge.plus"), ("Blur", "aqi.medium")]

    var body: some View {
        let mode = s.choice("bg.mode", "Gradient")
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("", first: true) {
                typePicker(mode)
                switch mode {
                case "Wallpaper": WallpaperBrowser(s: s)
                case "Color": colorMode
                case "Image": imageMode
                case "Blur": blurMode
                default: GradientMode(s: s)
                }
            }
            LookGroup(s: s)
        }
    }

    private func typePicker(_ mode: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Type").font(Yap.Font.body).foregroundStyle(Yap.label)
                Spacer()
                Text(mode).font(Yap.Font.body).foregroundStyle(Yap.caption)
            }
            HStack(spacing: 2) {
                ForEach(Self.modes, id: \.0) { m in
                    SlotButton(symbol: m.1, label: m.0, active: mode == m.0, compact: true) { s.choices["bg.mode"] = m.0 }
                }
            }
            .padding(.horizontal, -4)
        }
    }

    @ViewBuilder private var colorMode: some View {
        Swatch(s, "Color", "bg.color", MockGradients.color(0x2E3440))
        Action("Random color", symbol: "dice") {
            s.colors["bg.color"] = MockGradients.color(MockGradients.all.randomElement()!.1)
        }
    }

    @ViewBuilder private var imageMode: some View {
        Action("Choose image…")
        Note("Pick a picture to use behind the screen.")
    }

    @ViewBuilder private var blurMode: some View {
        Note("The recording itself, blurred, fills the background.")
        Num(s, "Background blur", "bg.blur", 0...100, "%.0f", 40)
    }
}

private struct GradientMode: View {
    let s: MockSettings

    var body: some View {
        Swatch(s, "From", "bg.from", MockGradients.color(0x4776E6))
        Swatch(s, "To", "bg.to", MockGradients.color(0x8E54E9))
        Num(s, "Hue", "bg.hue", 0...360, "%.0f°", 0)
        presets
        Action("Random gradient", symbol: "dice") { apply(Int.random(in: 0..<MockGradients.all.count)) }
        Num(s, "Angle", "bg.angle", 0...360, "%.0f°", 45)
    }

    private var presets: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
            ForEach(MockGradients.all.indices, id: \.self) { i in
                let p = MockGradients.all[i], shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                Button { apply(i) } label: {
                    LinearGradient(colors: [MockGradients.color(p.1), MockGradients.color(p.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .clipShape(shape).aspectRatio(1, contentMode: .fit)
                        .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                }
                .buttonStyle(PressStyle()).help(p.0).accessibilityLabel("Gradient \(p.0)")
            }
        }
    }

    private func apply(_ i: Int) {
        let p = MockGradients.all[i]
        s.colors["bg.from"] = MockGradients.color(p.1); s.colors["bg.to"] = MockGradients.color(p.2); s.numbers["bg.hue"] = 0
    }
}

private struct WallpaperBrowser: View {
    let s: MockSettings
    @State private var category = "All"

    var body: some View {
        SegmentSwitch(["All", "Favorites", "Nature", "Abstract", "Gradient"].map { ($0, $0) }, selection: $category, height: 26)
            .padding(.horizontal, -4)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(MockGradients.wallpapers.indices.filter(shown), id: \.self) { i in thumb(i) }
        }
        if category == "Favorites" { Note("Right-click a wallpaper to add it here.") }
        Action("Pick random", symbol: "dice") { s.numbers["bg.wallpaper"] = Double(Int.random(in: 0..<MockGradients.wallpapers.count)) }
    }

    private func shown(_ i: Int) -> Bool {
        category == "All" || MockGradients.wallpapers[i].1 == category
    }

    private func thumb(_ i: Int) -> some View {
        let w = MockGradients.wallpapers[i], on = Int(s.number("bg.wallpaper", 3)) == i
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return Button { s.numbers["bg.wallpaper"] = Double(i) } label: {
            LinearGradient(colors: w.2, startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(shape).aspectRatio(16 / 10, contentMode: .fit)
                .overlay(shape.strokeBorder(Color.white.opacity(on ? 1 : 0.15), lineWidth: on ? 2 : 0.5))
        }
        .buttonStyle(PressStyle()).help(w.0).accessibilityLabel("Wallpaper \(w.0)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct LookGroup: View {
    let s: MockSettings

    var body: some View {
        SettingsGroup("Look") {
            ChoiceMenuRow("Format", options: ["Auto", "Wide 16:9", "Square 1:1", "Classic 4:3", "Vertical 9:16", "Tall 3:4", "Portrait 4:5"],
                          selection: Binding(get: { s.choice("look.format", "Wide 16:9") }, set: { s.choices["look.format"] = $0 }))
            Num(s, "Padding", "look.padding", 0...25, "%.0f %%", 10)
            Num(s, "Rounded corners", "look.radius", 0...128, "%.0f pt", 16)
            Pick(s, "Shadow", "look.shadowStyle", ["Classic", "Directional"], "Classic")
            Num(s, "Shadow intensity", "look.shadow", 0...0.6, "%.2f", 0.3)
            shadowRest
            Flag(s, "Inset border", "look.inset")
            if s.flag("look.inset") { inset }
            More { more }
        }
    }

    @ViewBuilder private var shadowRest: some View {
        if s.choice("look.shadowStyle", "Classic") == "Directional" {
            Num(s, "Distance", "look.shadowDistance", 0...100, "%.0f pt", 25)
            Num(s, "Angle", "look.shadowAngle", 0...180, "%.0f°", 45)
            Num(s, "Blur", "look.shadowBlur", 0...30, "%.0f", 20)
        } else {
            Num(s, "Shadow size", "look.shadowSize", 0...80, "%.0f pt", 24)
            Num(s, "Shadow distance", "look.shadowOffset", 0...48, "%.0f pt", 8)
        }
    }

    @ViewBuilder private var inset: some View {
        Num(s, "Inset size", "look.insetSize", 0.125...24, "%.2f pt", 4)
        Swatch(s, "Inset color", "look.insetColor", Color(white: 0.53))
        Pick(s, "Border position", "look.insetOrigin", ["Center", "Top", "Bottom"], "Center")
    }

    @ViewBuilder private var more: some View {
        Num(s, "Texture", "look.noise", 0...1, "%.2f", 0)
        Flag(s, "Window frame", "look.windowFrame")
        Flag(s, "Improve screen quality", "look.quality")
        if s.flag("look.quality") {
            Num(s, "Improvement", "look.improve", 0...1, "%.2f", 0.5)
            Pick(s, "Upscaling", "look.upscaling", ["Off", "Fast", "Quality"], "Off")
            Note("Smooths noise and banding and resamples small recordings; it is not an AI enhancement.")
        }
    }
}

// MARK: - Cursor

private struct CursorSection: View {
    let s: MockSettings
    static let speeds = ["Slow", "Mellow", "Quick", "Rapid"]

    var body: some View {
        SettingsGroup("Appearance", first: true) {
            Flag(s, "Hide cursor", "cursor.hidden")
            Num(s, "Size", "cursor.size", 16...128, "%.0f px", 48)
            Num(s, "Smoothing", "cursor.smoothing", 0...1, "%.2f", 0.6)
            Pick(s, "Movement speed", "cursor.speed", Self.speeds, "Mellow")
            Flag(s, "Hide when idle", "cursor.idle")
            if s.flag("cursor.idle") { Num(s, "Idle after", "cursor.idleAfter", 0.5...5, "%.1f s", 2) }
            ChoiceMenuRow("Click effect", options: ["None", "Ripple", "Ring", "Pulse"],
                          selection: Binding(get: { s.choice("cursor.click", "Ripple") }, set: { s.choices["cursor.click"] = $0 }))
            More { more }
        }
    }

    @ViewBuilder private var more: some View {
        Flag(s, "Always use the default arrow", "cursor.default")
        Num(s, "Rotate cursor", "cursor.rotation", -180...180, "%.0f°", 0)
        Pick(s, "Rotate while moving", "cursor.rotationMode", ["Static", "Tilt"], "Static")
        Flag(s, "Remove tiny shakes", "cursor.shakes", true)
        Flag(s, "Reduce cursor-type flicker", "cursor.flicker", true)
        Flag(s, "Loop cursor to start", "cursor.loop")
        ChoiceMenuRow("Cursor style", options: ["Original", "macOS", "Minimal", "Touch"],
                      selection: Binding(get: { s.choice("cursor.style", "Original") }, set: { s.choices["cursor.style"] = $0 }))
        Num(s, "Motion blur", "cursor.blur", 0...1, "%.2f", 0.4)
        Num(s, "Spotlight radius", "cursor.spotlight", 0...600, "%.0f px", 0)
    }
}

// MARK: - Camera

private struct CameraLayoutSection: View {
    @Bindable var mock: EditorMock
    let s: MockSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("", first: true) {
                Flag(s, "Show camera", "cam.show", true)
                ChoiceMenuRow("Position", options: ["Bottom right", "Bottom left", "Top right", "Top left"],
                              selection: Binding(get: { s.choice("cam.position", "Bottom right") }, set: { s.choices["cam.position"] = $0 }))
                Num(s, "Size", "cam.size", 5...50, "%.0f %%", 18)
                Num(s, "Size while zoomed", "cam.sizeZoomed", 5...50, "%.0f %%", 12)
                Pick(s, "Shape", "cam.shape", ["Circle", "Rounded", "Square"], "Circle")
                More { more }
            }
            SettingsGroup("Layout over time") {
                Action("Add layout at playhead") { mock.selection = .layout(0) }
                Note("Outside layout sections the default camera settings apply.")
            }
        }
    }

    @ViewBuilder private var more: some View {
        Num(s, "Edge softness", "cam.soft", 0...1, "%.2f", 0)
        Num(s, "Edge inset", "cam.inset", 0...80, "%.0f pt", 24)
        Flag(s, "Flip sides", "cam.flip")
        Flag(s, "Padded", "cam.padded", true)
        Flag(s, "Avoid empty area", "cam.avoid")
        if s.flag("cam.avoid") { Num(s, "After silence of", "cam.silence", 1...10, "%.0f s", 3) }
    }
}

private struct CameraStyleSection: View {
    let s: MockSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Color", first: true) {
                Num(s, "Intensity", "camStyle.intensity", 0...1, "%.2f", 0.5)
                Num(s, "Warmth", "camStyle.warmth", -1...1, "%.2f", 0)
                Num(s, "Background pop", "camStyle.pop", 0...1, "%.2f", 0)
                Num(s, "Contrast", "camStyle.contrast", -1...1, "%.2f", 0)
                Num(s, "Color intensity", "camStyle.saturation", -1...1, "%.2f", 0)
                More { more }
            }
            SettingsGroup("Shape") {
                Num(s, "Corner radius", "camStyle.radius", 0...100, "%.0f %%", 50)
                Num(s, "Opacity", "camStyle.opacity", 0...1, "%.2f", 1)
                Num(s, "Shadow", "camStyle.shadow", 0...1, "%.2f", 0.3)
                Action("Crop camera…")
            }
        }
    }

    @ViewBuilder private var more: some View {
        Num(s, "Sharpen", "camStyle.sharpen", 0...1, "%.2f", 0)
        Num(s, "Grain", "camStyle.grain", 0...1, "%.2f", 0)
        Num(s, "Background blur", "camStyle.bgBlur", 0...1, "%.2f", 0)
        Flag(s, "Mirror", "camStyle.mirror", true)
        Flag(s, "Follow face (framing)", "camStyle.face")
        Flag(s, "Remove background", "camStyle.removeBg")
    }
}

// MARK: - Captions, transcript

private struct CaptionsSection: View {
    let s: MockSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("", first: true) {
                if s.flag("captions.done", true) {
                    Info("Captions", "\(EditorMock.captions.count)")
                    Action("Generate again from speech")
                } else {
                    Action("Generate captions from speech") { s.flags["captions.done"] = true }
                }
                Action("Add caption at playhead")
            }
            SettingsGroup("Style") {
                Num(s, "Size", "captions.size", 2...12, "%.1f %%", 5)
                Pick(s, "Position", "captions.position", ["Bottom", "Top"], "Bottom")
                Num(s, "Words per line", "captions.words", 2...12, "%.0f", 6)
                Swatch(s, "Text", "captions.color", .white)
                Swatch(s, "Background", "captions.background", Color(white: 0.08))
                More { Num(s, "Corner radius", "captions.radius", 0...24, "%.0f px", 8) }
            }
        }
    }
}

private struct TranscriptSection: View {
    @Bindable var mock: EditorMock
    let s: MockSettings

    var body: some View {
        SettingsGroup("", first: true) {
            Note("Select words in the transcript and delete them to cut the video.")
            Action("Open transcript", symbol: "text.quote") { mock.lower = .transcript }
            Info("Filler words", "\(EditorMock.fillerCount)")
            Action("Remove filler words") { mock.cutFillers() }
            Action("Find silent parts…")
        }
    }
}

// MARK: - Audio

private struct AudioSection: View {
    let s: MockSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Background audio", first: true) {
                ValueRow(symbol: "music.note", title: "Lo-fi morning", value: "2:41") {}
                HStack(spacing: 6) {
                    Action("Add file…")
                    Action("Library", symbol: "folder")
                }
                Flag(s, "Mute background audio", "audio.musicMuted")
            }
            SettingsGroup("Microphone") {
                Flag(s, "Mute", "audio.micMuted")
                Num(s, "Volume", "audio.micGain", -48...12, "%.0f dB", 0)
                Flag(s, "Keep stereo microphone", "audio.stereo")
                Flag(s, "Clean up voice", "audio.cleanup", true)
                if s.flag("audio.cleanup", true) { More(title: "Voice") { voice } }
            }
            SettingsGroup("System audio") {
                Flag(s, "Mute", "audio.systemMuted")
                Num(s, "Volume", "audio.systemGain", -48...12, "%.0f dB", -6)
            }
            SettingsGroup("Click sounds") {
                Flag(s, "Play a sound on clicks", "audio.clicks")
                if s.flag("audio.clicks") {
                    Pick(s, "Sound", "audio.clickSound", ["Soft", "Crisp"], "Soft")
                    Num(s, "Volume", "audio.clickGain", -48...12, "%.0f dB", -12)
                }
            }
            SettingsGroup("Automatic edits") { Action("Find silent parts…") }
        }
    }

    @ViewBuilder private var voice: some View {
        ChoiceMenuRow("Voice preset", options: ["Natural", "Podcast", "Broadcast", "Custom"],
                      selection: Binding(get: { s.choice("audio.preset", "Natural") }, set: { s.choices["audio.preset"] = $0 }))
        Num(s, "Noise reduction", "audio.nr", 0...60, "%.0f dB", 18)
        Num(s, "Noise gate", "audio.gate", -70 ... -15, "%.0f dB", -50)
        Num(s, "Low cut", "audio.lowcut", 20...300, "%.0f Hz", 80)
        Num(s, "Compression", "audio.comp", 1...10, "%.1f:1", 3)
        Flag(s, "Even out loudness", "audio.loudness", true)
        if s.flag("audio.loudness", true) { Num(s, "Target loudness", "audio.lufs", -36 ... -10, "%.0f LUFS", -16) }
    }
}

// MARK: - Keys

private struct KeysSection: View {
    let s: MockSettings

    var body: some View {
        SettingsGroup("Key overlay", first: true) {
            Flag(s, "Show typed keys", "keys.on", true)
            if s.flag("keys.on", true) {
                Flag(s, "Show single-key presses", "keys.single")
                Num(s, "Stays visible", "keys.duration", 0.3...4, "%.1f s", 1)
                Pick(s, "Position", "keys.position", ["Bottom", "Center", "Top"], "Bottom")
                Num(s, "Size", "keys.size", 7.5...25, "%.1f %%", 10)
                More(title: "Style") { style }
            }
        }
    }

    @ViewBuilder private var style: some View {
        Swatch(s, "Text", "keys.color", .white)
        Swatch(s, "Background", "keys.background", Color(white: 0.1))
        Num(s, "Corner radius", "keys.radius", 0...48, "%.0f px", 12)
        Num(s, "Opacity", "keys.opacity", 0...1, "%.2f", 0.9)
        Note("Hidden shortcuts: ⌘Tab, ⌘Space. Right-click a key on the timeline to hide it.")
    }
}

// MARK: - Animations

private struct AnimationsSection: View {
    let s: MockSettings
    static let speeds = ["Slow", "Mellow", "Quick", "Rapid"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Preset", first: true) {
                SegmentSwitch(["Focused", "Smooth", "Medium", "Rapid"].map { ($0, $0) },
                              selection: Binding(get: { s.choice("anim.preset", "Smooth") }, set: { s.choices["anim.preset"] = $0 }), height: 26)
                    .padding(.horizontal, -4)
            }
            SettingsGroup("Zooms") {
                Flag(s, "Automatic zooms", "anim.auto", true)
                Flag(s, "Follow cursor while zoomed", "anim.follow", true)
                Pick(s, "Transition speed", "anim.speed", Self.speeds, "Mellow")
                ChoiceMenuRow("Screen animation", options: ["Smooth", "Spring", "Linear"],
                              selection: Binding(get: { s.choice("anim.style", "Smooth") }, set: { s.choices["anim.style"] = $0 }))
                Flag(s, "Start animation early", "anim.early")
                Num(s, "Default zoom level", "anim.level", 1...4, "%.1f×", 2)
            }
            SettingsGroup("Motion blur") {
                Num(s, "Motion blur", "anim.blur", 0...1, "%.2f", 1)
            }
        }
    }
}

// MARK: - Extras

private struct ExtrasSection: View {
    @Bindable var mock: EditorMock
    let s: MockSettings
    static let reactions = ["👍", "🎉", "❤️", "😂", "🔥", "👀"]
    static let intros = ["None", "Fade in", "Zoom in", "Slide from left", "Slide from right", "Slide from top", "Slide from bottom"]
    static let outros = ["None", "Fade out", "Zoom out", "Slide from left", "Slide from right", "Slide from top", "Slide from bottom"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Masks and highlights", first: true) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], alignment: .leading, spacing: 6) {
                    Action("Highlight", symbol: "highlighter")
                    Action("Spotlight", symbol: "scope")
                    Action("Blur mask", symbol: "aqi.medium")
                    Action("Cover mask", symbol: "rectangle.fill")
                }
            }
            SettingsGroup("Text and reactions") {
                Action("Add text at playhead", symbol: "textformat") { mock.add(.text) }
                HStack(spacing: 4) {
                    ForEach(Self.reactions, id: \.self) { g in
                        Button(g) {}.buttonStyle(CircleButtonStyle(size: 32)).accessibilityLabel("Add reaction \(g)")
                    }
                }
                Note("Drag the text box in the preview to place it.")
            }
            SettingsGroup("Intro and outro") {
                intro
            }
        }
    }

    @ViewBuilder private var intro: some View {
        ChoiceMenuRow("Intro", options: Self.intros, selection: Binding(get: { s.choice("intro", "None") }, set: { s.choices["intro"] = $0 }))
        if s.choice("intro", "None") != "None" { Num(s, "Intro length", "introLength", 0.2...3, "%.1f s", 0.8) }
        ChoiceMenuRow("Outro", options: Self.outros, selection: Binding(get: { s.choice("outro", "None") }, set: { s.choices["outro"] = $0 }))
        if s.choice("outro", "None") != "None" { Num(s, "Outro length", "outroLength", 0.2...3, "%.1f s", 0.8) }
    }
}

// MARK: - Selected elements

private struct ZoomInspector: View {
    @Bindable var mock: EditorMock
    let s: MockSettings
    let span: MockSpan

    var body: some View {
        let k = "zoom.\(Int(span.start))."
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(mock: mock, title: "Zoom", detail: "\(EditorMock.timecode(span.start)) – \(EditorMock.timecode(span.end))")
            SettingsGroup("", first: true) {
                Pick(s, "Type", k + "type", ["Auto", "Manual"], "Manual")
                Pick(s, "Style", k + "style", ["Classic", "Glass loupe"], "Classic")
                Num(s, "Zoom level", k + "scale", 1...4, "%.1f×", span.scale)
                Info("Focus", String(format: "%.0f %%, %.0f %%", span.focus.x * 100, span.focus.y * 100))
                Note("Click in the preview to set the focus point.")
                Flag(s, "Instant animation", k + "instant")
                Flag(s, "Enabled", k + "enabled", true)
            }
            SettingsGroup("") {
                Action("Apply this level to all other zooms")
                HStack(spacing: 6) {
                    Action("Duplicate")
                    Action("Delete zoom")
                }
                Note("Keys: A auto · M manual · D disable · ⌘D duplicate · 1–9 level · ⌫ remove")
            }
        }
    }
}

private struct ClipInspector: View {
    @Bindable var mock: EditorMock
    let s: MockSettings
    let index: Int

    var body: some View {
        let c = EditorMock.clips[index], k = "clip.\(index)."
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(mock: mock, title: "Clip \(index + 1)", detail: "\(EditorMock.timecode(c.start)) – \(EditorMock.timecode(c.end))")
            SettingsGroup("", first: true) {
                ChoiceMenuRow("Speed", options: ["0.25×", "0.5×", "0.75×", "1× (normal)", "1.25×", "1.5×", "2×", "3×", "4×"],
                              selection: Binding(get: { s.choice(k + "speed", "1× (normal)") }, set: { s.choices[k + "speed"] = $0 }))
                Action("Apply this speed to all clips")
                Num(s, "Microphone volume", k + "mic", -48...12, "%.0f dB", 0)
                Num(s, "System audio volume", k + "system", -48...12, "%.0f dB", 0)
                Flag(s, "Hide the cursor in this part", k + "hideCursor")
                Flag(s, "Smooth cursor movement off", k + "smoothOff")
                Info("Length", EditorMock.timecode(c.end - c.start, fraction: true))
            }
            SettingsGroup("") {
                Action("Reset trim")
                Action("Reset all trims and cuts")
                Action("Delete clip")
            }
        }
    }
}

private struct LayoutInspector: View {
    @Bindable var mock: EditorMock
    let s: MockSettings
    let index: Int

    var body: some View {
        let l = EditorMock.layouts[min(index, EditorMock.layouts.count - 1)], k = "layout.\(index)."
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(mock: mock, title: "Camera layout", detail: "\(EditorMock.timecode(l.start)) – \(EditorMock.timecode(l.end))")
            SettingsGroup("", first: true) {
                ChoiceMenuRow("Layout", options: ["Default", "Overlay", "Camera only", "Screen only", "Cutout", "Split"],
                              selection: Binding(get: { s.choice(k + "mode", l.title) }, set: { s.choices[k + "mode"] = $0 }))
                Flag(s, "Enabled", k + "enabled", true)
                Action("Remove layout") { mock.selection = .none }
            }
        }
    }
}

private struct SuggestionInspector: View {
    @Bindable var mock: EditorMock

    var body: some View {
        let s = EditorMock.suggestion
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(mock: mock, title: "Suggested zoom", detail: "\(EditorMock.timecode(s.start)) – \(EditorMock.timecode(s.end))")
            SettingsGroup("", first: true) {
                Text("From Claude Code: zoom on the terminal output.").font(Yap.Font.body).foregroundStyle(Yap.body)
                Info("Zoom level", String(format: "%.1f×", s.scale))
                ReviewButtons(mock: mock, height: 28)
            }
        }
    }
}

private struct BlockInspector: View {
    @Bindable var mock: EditorMock
    @Binding var block: MockBlock
    @State private var style = "Bold"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(mock: mock, title: block.kind.label, detail: String(format: "%.1f s", block.end - block.start))
            SettingsGroup("", first: true) {
                if block.kind != .spotlight {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Text").font(Yap.Font.body).foregroundStyle(Yap.label)
                        RecessedField("Text", text: $block.text, height: 32)
                    }
                }
                ValueChoice("Style", items: [("Bold", "Bold"), ("Quiet", "Quiet"), ("Outline", "Outline")], selection: $style)
                ValueSlider("Size", value: String(format: "%.0f %%", block.scale * 100),
                            amount: Binding(get: { (block.scale - 0.4) / 2.6 }, set: { block.scale = 0.4 + $0 * 2.6 }))
                Note("Drag it in the preview to move it.")
            }
        }
    }
}
