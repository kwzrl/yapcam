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

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
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
            tuning
        }
        .padding(36)
        .onExitCommand(perform: close)
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
            knob("Clarity", \.clarity, 0...1)
            knob("Top light", \.topLight, 0...0.3)
            knob("Bottom light", \.bottomLight, 0...0.3)
            knob("Rim light", \.rim, 0...0.5)
            knob("Warmth", \.warmth, 0...0.3)
            knob("Shadow", \.shadow, 0...0.8)
            HStack {
                Button("Reset") { t.reset() }.buttonStyle(CapsuleButtonStyle(.secondary, height: 28))
                Spacer()
                Button("Copy values") {
                    let s = String(format: "clarity %.2f, topLight %.2f, bottomLight %.2f, rim %.2f, warmth %.2f, shadow %.2f",
                                   t.clarity, t.topLight, t.bottomLight, t.rim, t.warmth, t.shadow)
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
