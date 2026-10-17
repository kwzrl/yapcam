import AppKit
import SwiftUI
import YapcamDesign

/// `Yapcam --design-lab`: the glass kit over the real desktop, with live tuning. Mock-ups only, no engine.
@MainActor enum DesignLab {
    private static var window: NSWindow?

    /// Renders the lab over the desktop picture to `<dir>/design-lab.png` (no live blur in offscreen renders) and quits.
    static func snapshot(into dir: URL) {
        let size = CGSize(width: 1180, height: 760)
        let wallpaper = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }.flatMap { NSImage(contentsOf: $0) }
        let root = ZStack {
            if let wallpaper { Image(nsImage: wallpaper).resizable().scaledToFill().blur(radius: 30) } else { Color(white: 0.2) }
            DesignLabView(close: {})
        }
        .frame(width: size.width, height: size.height).clipped().yapWindow()
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host; w.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "design-lab.png"))
            }
            NSApp.terminate(nil)
        }
    }

    static func show() {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 760),
                         styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        w.makeGlassHost()
        w.isMovableByWindowBackground = true
        w.title = "Design Lab"
        w.contentView = NSHostingView(rootView: DesignLabView(close: { NSApp.terminate(nil) }).yapWindow())
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window = w
    }
}

private struct DesignLabView: View {
    let close: () -> Void
    @State private var t = GlassTuning.shared
    @State private var source = "display"
    @State private var after = "project"
    @State private var tab = "look"
    @State private var scale = 0.35
    @State private var menuOpen = true
    @State private var page = "toolbars"
    @State private var barSource = SourceMode.display

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 28) {
                pageSwitch
                if page == "kit" { kit } else { toolbarCompare }
            }
            tuning
        }
        .padding(36)
        .onExitCommand(perform: close)
    }

    private var pageSwitch: some View {
        OptionRow(["toolbars", "kit"], selection: $page) { id, on in
            Text(id == "kit" ? "Kit" : "Toolbars").font(Yap.Font.label).foregroundStyle(on ? Yap.title : Yap.caption)
        }
        .frame(width: 220)
        .padding(4)
        .glassPanel(radius: Yap.Radius.card + 4)
    }

    // MARK: toolbar (variant B, chosen 2026-10-17; A and C dropped)

    private var toolbarCompare: some View {
        VStack(alignment: .leading, spacing: 36) {
            variant("B  Toolbar", "rounded rectangle, concentric platters, hairlines, record beside") {
                OrbitBar(source: $barSource, labels: true, rounded: true)
            }
        }
    }

    private func variant<Bar: View>(_ title: String, _ note: String, @ViewBuilder _ bar: () -> Bar) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(title).font(Yap.Font.label).foregroundStyle(Yap.title)
                Text(note).font(Yap.Font.caption).foregroundStyle(Yap.caption)
            }
            bar()
        }
    }

    // MARK: kit

    private var kit: some View {
        VStack(alignment: .leading, spacing: 28) {
            toolbar
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Button { menuOpen.toggle() } label: { Image(systemName: "ellipsis") }
                        .buttonStyle(CircleButtonStyle(active: menuOpen))
                    if menuOpen {
                        GlassMenu(caption: "What happens when\na recording stops",
                                  items: [("project", "Open the editor"), ("copy", "Export and copy"), ("save", "Export and save")],
                                  selection: $after)
                            .frame(width: 260)
                            .glassPanel(radius: Yap.Radius.card + 6, lift: 0.04)
                    }
                }
                widget
            }
            inspector
        }
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(CircleButtonStyle(size: 30))
            OptionRow(["display", "window", "area"], selection: $source) { id, on in
                ToolCell(symbol: ["display": "display", "window": "macwindow", "area": "rectangle.dashed"][id]!, title: id.capitalized, on: on)
            }
            .frame(width: 240)
            FadingHairline().frame(height: 44)
            ToolCell(symbol: "video.slash", title: "No camera", on: false).frame(width: 84)
            ToolCell(symbol: "mic", title: "MacBook Mic", on: false).frame(width: 96)
            ToolCell(symbol: "speaker.wave.2", title: "System", on: false).frame(width: 70)
            FadingHairline().frame(height: 44)
            RecordDot().padding(.horizontal, 10)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .glassPanel(radius: 30)
    }

    // MARK: quick export widget

    private var widget: some View {
        let r: CGFloat = Yap.Radius.panel, inset: CGFloat = 14
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: Yap.concentric(r, inset: inset), style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.25, blue: 0.4), Color(red: 0.5, green: 0.3, blue: 0.25)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 150, height: 94)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Recording").font(Yap.Font.title(17)).foregroundStyle(Yap.title)
                    Text("0:42 · 1080p · 48 MB").technical().lineLimit(1)
                    Text("Ready to edit or export.").font(Yap.Font.body).foregroundStyle(Yap.body)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("Copy") {}.buttonStyle(CapsuleButtonStyle(.secondary, height: 30))
                Button("Save…") {}.buttonStyle(CapsuleButtonStyle(.secondary, height: 30))
                Spacer()
                Button("Edit") {}.buttonStyle(CapsuleButtonStyle(.primary, height: 30)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(inset)
        .frame(width: 380)
        .glassPanel(radius: r)
    }

    // MARK: inspector sample

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 20) {
            OptionRow(["look", "overlays", "cursor", "camera", "audio"], selection: $tab) { id, on in
                VStack(spacing: 5) {
                    Image(systemName: ["look": "paintbrush", "overlays": "square.on.square", "cursor": "cursorarrow", "camera": "video", "audio": "waveform"][id]!)
                        .font(.system(size: 15, weight: .medium)).frame(height: 18)
                    Text(id.capitalized).font(Yap.Font.caption)
                }
                .foregroundStyle(on ? Yap.title : Yap.caption)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Zoom scale").font(Yap.Font.label).foregroundStyle(Yap.label)
                    Spacer()
                    Text(String(format: "%.1f×", 1 + scale * 3)).technical()
                }
                PillSlider(value: $scale)
                Text("Click in the preview to set the focus point.").font(Yap.Font.body).foregroundStyle(Yap.body)
            }
            HStack {
                Text("0:01.00").technical()
                Text("/ 0:05.00").font(Yap.Font.technical).foregroundStyle(Yap.faint)
                Spacer()
                Button {} label: { Image(systemName: "play.fill") }.buttonStyle(CircleButtonStyle(active: true, size: 34))
            }
        }
        .padding(22)
        .frame(width: 420)
        .glassPanel(radius: Yap.Radius.panel)
    }

    // MARK: tuning

    private var tuning: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Glass").font(Yap.Font.title(20)).foregroundStyle(Yap.title)
            knob("Glass body", \.body, 0...1)
            knob("Top light", \.topLight, 0...0.3)
            knob("Bottom light", \.bottomLight, 0...0.3)
            knob("Rim light", \.rim, 0...0.5)
            knob("Warmth", \.warmth, 0...0.3)
            knob("Shadow", \.shadow, 0...0.8)
            knob("Sheen (B, C)", \.sheen, 0...0.4)
            HStack {
                Button("Reset") { t.reset() }.buttonStyle(CapsuleButtonStyle(.secondary, height: 28))
                Spacer()
                Button("Copy values") {
                    let s = String(format: "body %.2f, topLight %.2f, bottomLight %.2f, rim %.2f, warmth %.2f, shadow %.2f, sheen %.2f",
                                   t.body, t.topLight, t.bottomLight, t.rim, t.warmth, t.shadow, t.sheen)
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
                }.buttonStyle(CapsuleButtonStyle(.secondary, height: 28))
            }
        }
        .padding(22)
        .frame(width: 280)
        .glassPanel(radius: Yap.Radius.panel)
    }

    private func knob(_ title: String, _ key: ReferenceWritableKeyPath<GlassTuning, Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(Yap.Font.label).foregroundStyle(Yap.label)
                Spacer()
                Text(String(format: "%.2f", t[keyPath: key])).technical()
            }
            PillSlider(value: Binding(get: { t[keyPath: key] }, set: { t[keyPath: key] = $0 }), in: range, trackHeight: 18)
        }
    }
}

private struct ToolCell: View {
    let symbol: String, title: String, on: Bool
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(height: 20)
            Text(title).font(Yap.Font.caption).lineLimit(1)
        }
        .foregroundStyle(on ? Yap.title : Yap.label)
        .padding(.vertical, 2)
    }
}

/// The only coloured chrome: record.
private struct RecordDot: View {
    @State private var hover = false
    var body: some View {
        Circle().fill(Yap.record)
            .frame(width: 22, height: 22)
            .padding(6)
            .background(Circle().fill(Color.white.opacity(hover ? 0.14 : 0.08)))
            .onHover { hover = $0 }
            .accessibilityLabel("Start recording")
    }
}

// MARK: - Toolbar variants

private enum LabDevices {
    struct Item: Identifiable { let id: String; let line: String; let title: String; var on = true }
    static let all = [
        Item(id: "camera", line: "video.slash", title: "No camera", on: false),
        Item(id: "mic", line: "mic", title: "MacBook Mic"),
        Item(id: "audio", line: "speaker.wave.2", title: "System audio"),
    ]
}

/// B and C, after the visionOS tab bar: a platter marks the selection, hairlines between the groups,
/// record sits beside the bar on its own glass. `rounded` = rounded rectangle (B), otherwise capsule (C).
private struct OrbitBar: View {
    @Binding var source: SourceMode
    let labels: Bool
    let rounded: Bool
    static let height: CGFloat = 54
    static let inset: CGFloat = 6
    static let radius: CGFloat = 16

    private var barRadius: CGFloat { rounded ? Self.radius : Self.height / 2 }

    var body: some View {
        HStack(spacing: 12) {
            bar
            RecordSatellite(size: Self.height, radius: barRadius)
        }
    }

    private var separator: some View {
        Hairline().frame(height: 30).padding(.horizontal, 5)
    }

    private var bar: some View {
        HStack(spacing: 2) {
            Button {} label: { Image(systemName: "xmark") }
                .buttonStyle(CircleButtonStyle(active: true, size: 22))
                .frame(width: OrbitCell.size, height: OrbitCell.size)
            separator
            ForEach(SourceMode.toolbarModes) { m in
                OrbitCell(symbol: m.symbol, label: m.title, labels: labels, rounded: rounded, selected: source == m) { source = m }
            }
            separator
            ForEach(LabDevices.all) { d in
                OrbitCell(symbol: d.line, label: d.title, labels: labels, rounded: rounded, dim: !d.on) {}
            }
            separator
            OrbitCell(symbol: "film", label: "Edit", labels: labels, rounded: rounded) {}
            OrbitCell(symbol: "folder", label: "Library", labels: labels, rounded: rounded) {}
            OrbitCell(symbol: "gearshape", label: "Settings", labels: labels, rounded: rounded) {}
        }
        .padding(.horizontal, Self.inset)
        .frame(height: Self.height)
        .glassPanel(radius: barRadius, sheen: true)
    }
}

/// One slot in the orbit bar, concentric with it: capsule/circle, or a rounded rectangle when the bar is one.
private struct OrbitCell: View {
    static let size: CGFloat = OrbitBar.height - 2 * OrbitBar.inset
    let symbol: String
    let label: String
    let labels: Bool
    let rounded: Bool
    var selected = false
    var dim = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(selected ? Yap.title : (dim ? Yap.caption : Yap.label))
                .frame(minWidth: Self.size, minHeight: Self.size, maxHeight: Self.size)
                .background(shape.fill(Color.white.opacity(selected ? 0.24 : 0.08))
                    .opacity(selected || hover ? 1 : 0).scaleEffect(selected || hover ? 1 : 0.9)
                    .animation(selected || hover ? .snappy(duration: 0.14) : .smooth(duration: 0.3), value: selected || hover))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: rounded ? Yap.concentric(OrbitBar.radius, inset: OrbitBar.inset) : Self.size / 2,
                         style: .continuous)
    }

    @ViewBuilder private var content: some View {
        if labels {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 16, weight: .regular)).frame(height: 19)
                Text(label).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 12)
        } else {
            Image(systemName: symbol).font(.system(size: 18, weight: .light))
        }
    }
}

/// Record on its own glass beside the bar (the slot of the search button in visionOS), same corner as the bar.
private struct RecordSatellite: View {
    let size: CGFloat
    let radius: CGFloat
    @State private var hover = false

    var body: some View {
        Circle().fill(Yap.record)
            .frame(width: size * 0.36, height: size * 0.36)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(hover ? 0.08 : 0)))
            .glassPanel(radius: radius, sheen: true)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hover = $0 }
            .help("Start recording")
            .accessibilityLabel("Start recording")
    }
}
