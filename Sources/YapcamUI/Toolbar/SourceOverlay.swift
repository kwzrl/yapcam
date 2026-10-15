import AppKit
import SwiftUI

// MARK: - Pure geometry / hit testing (unit-tested)

enum OverlayGeometry {
    /// A rectangle in global CG coordinates (top-left origin) → local top-left coordinates on `screenFrame`
    /// (an AppKit frame, bottom-left origin). `primaryMaxY` is the top edge of the primary display in AppKit coordinates.
    static func localRect(cg r: CGRect, screenFrame f: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: r.minX - f.minX, y: r.minY - (primaryMaxY - f.maxY), width: r.width, height: r.height)
    }

    /// AppKit mouse location (bottom-left origin) → global CG point (top-left origin).
    static func cgPoint(fromAppKit p: CGPoint, primaryMaxY: CGFloat) -> CGPoint { CGPoint(x: p.x, y: primaryMaxY - p.y) }
}

struct WindowRow: Equatable {
    var id: UInt32
    var pid: Int32
    var layer: Int
    var app: String
    var title: String
    var bounds: CGRect          // global CG coordinates
}

enum WindowHit {
    /// Topmost recordable window under `point`. `rows` must be ordered front to back (as CGWindowList returns them).
    static func pick(from rows: [WindowRow], at point: CGPoint, excludingPID: Int32) -> WindowRow? {
        rows.first { $0.layer == 0 && $0.pid != excludingPID && $0.bounds.width >= 80 && $0.bounds.height >= 60 && $0.bounds.contains(point) }
    }

    static func onScreenRows() -> [WindowRow] {
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return info.compactMap { d in
            guard let id = d[kCGWindowNumber as String] as? UInt32,
                  let pid = d[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = (d[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return nil }
            return WindowRow(id: id, pid: pid, layer: d[kCGWindowLayer as String] as? Int ?? 0,
                             app: d[kCGWindowOwnerName as String] as? String ?? "App",
                             title: d[kCGWindowName as String] as? String ?? "", bounds: bounds)
        }
    }
}

// MARK: - The card: what will be recorded + Start recording

struct SourceCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let start: () -> Void
    @EnvironmentObject var settings: AppSettings
    @Environment(\.contrastOpacity) private var contrast

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 1) {
                Button(action: start) {
                    Text("Start recording").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .frame(minWidth: 150, minHeight: 34)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 9, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous).fill(Color.red))
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                .accessibilityLabel("Start recording")
                Menu {
                    Picker("Frame rate", selection: $settings.maxFPS) { Text("60 fps").tag(60); Text("30 fps").tag(30) }
                    Picker("Countdown", selection: $settings.countdown) { Text("No countdown").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5) }
                    Toggle("Record system audio", isOn: $settings.systemAudio)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 34)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 9, topTrailingRadius: 9, style: .continuous).fill(Color.red.opacity(0.88)))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Recording options")
            }
            Text("Esc to cancel").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(18)
        .panelSurface(cornerRadius: 16)
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }
}

// MARK: - SwiftUI roots hosted in the overlay windows

@MainActor final class SourceOverlayModel: ObservableObject {
    enum Kind { case display, window }
    let kind: Kind
    @Published var activeDisplayID: UInt32 = 0
    @Published var hover: WindowRow?
    init(kind: Kind) { self.kind = kind }
}

/// Dimmed display with the card centered on the display under the cursor.
struct DisplayOverlayRoot: View {
    let display: DisplayInfo
    @ObservedObject var model: SourceOverlayModel
    let start: (UInt32) -> Void
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            if model.activeDisplayID == display.id {
                SourceCard(symbol: "display", title: display.name,
                           subtitle: "\(Int(display.pixelSize.width))×\(Int(display.pixelSize.height)) · \(settings.maxFPS) fps",
                           start: { start(display.id) })
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose display to record")
    }
}

/// Highlights the window under the cursor (tinted fill + outline) with the card inside it.
struct WindowOverlayRoot: View {
    let screenFrame: CGRect
    let primaryMaxY: CGFloat
    @ObservedObject var model: SourceOverlayModel
    let start: (UInt32) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)          // catches the mouse everywhere on this display
            if let w = model.hover {
                let r = OverlayGeometry.localRect(cg: w.bounds, screenFrame: screenFrame, primaryMaxY: primaryMaxY)
                if r.intersects(CGRect(origin: .zero, size: screenFrame.size)) {
                    Rectangle().fill(Color.accentColor.opacity(0.22))
                        .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 3))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                    SourceCard(symbol: "macwindow", title: w.title.isEmpty ? w.app : w.title,
                               subtitle: "\(w.app) · \(Int(w.bounds.width))×\(Int(w.bounds.height))",
                               start: { start(w.id) })
                        .position(x: r.midX, y: r.midY)
                }
            } else {
                Text("Move the pointer over a window").font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 8).panelSurface(cornerRadius: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let w = model.hover { start(w.id) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose window to record")
    }
}

// MARK: - Controller

private final class OverlayWindow: NSWindow {
    var onEscape: (() -> Void)?
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screen.frame, display: false)
    }
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) } }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Click a source button → this overlay → Start recording. Display and window overlays live here;
/// the area overlay is `AreaSelector`.
@MainActor final class SourceOverlay {
    static let shared = SourceOverlay()
    private var windows: [OverlayWindow] = []
    private var model: SourceOverlayModel?
    private var timer: Timer?
    var isActive: Bool { !windows.isEmpty }
    private var primaryMaxY: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    func show(_ kind: SourceOverlayModel.Kind) {
        hide()
        AreaSelector.shared.cancelForTesting()
        let m = SourceOverlayModel(kind: kind)
        model = m
        let settings = AppSettings.shared
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let info = Displays.info(for: id) else { continue }
            let w = OverlayWindow(screen: screen)
            w.onEscape = { [weak self] in self?.hide() }
            let root: AnyView
            switch kind {
            case .display:
                root = AnyView(DisplayOverlayRoot(display: info, model: m, start: { [weak self] id in self?.startDisplay(id) }).environmentObject(settings))
            case .window:
                root = AnyView(WindowOverlayRoot(screenFrame: screen.frame, primaryMaxY: primaryMaxY, model: m, start: { [weak self] id in self?.startWindow(id) }).environmentObject(settings))
            }
            w.contentView = NSHostingView(rootView: root)
            RecordingController.shared.engine.registerExcluded(w)
            windows.append(w)
            w.orderFrontRegardless()
        }
        NSApp.activate()
        windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKeyAndOrderFront(nil) ?? windows.first?.makeKeyAndOrderFront(nil)
        track()
        timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.track() } }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        for w in windows { RecordingController.shared.engine.unregisterExcluded(w); w.orderOut(nil) }
        windows = []
        model = nil
    }

    /// Follow the pointer: the card moves to the display under it; the highlight to the window under it.
    private func track() {
        guard let m = model else { return }
        let p = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }), let id = screen.displayID, m.activeDisplayID != id { m.activeDisplayID = id }
        if m.kind == .window {
            let cg = OverlayGeometry.cgPoint(fromAppKit: p, primaryMaxY: primaryMaxY)
            let hit = WindowHit.pick(from: WindowHit.onScreenRows(), at: cg, excludingPID: ProcessInfo.processInfo.processIdentifier)
            if hit != m.hover { m.hover = hit }
        }
    }

    private func startDisplay(_ id: UInt32) {
        let s = AppSettings.shared
        s.displayID = id; s.sourceMode = .display
        hide(); beginSoon()
    }

    private func startWindow(_ id: UInt32) {
        let s = AppSettings.shared
        s.windowID = id; s.sourceMode = .window
        hide(); beginSoon()
    }

    /// Let the overlay windows leave the screen before the countdown/recording begins.
    private func beginSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { RecordingController.shared.begin() } }

    // MARK: Test hooks (self-tests drive the same Start path the button uses)

    func startForTesting(display id: UInt32? = nil, windowRow: WindowRow? = nil) {
        guard let m = model else { return }
        switch m.kind {
        case .display: startDisplay(id ?? m.activeDisplayID)
        case .window: if let w = windowRow ?? m.hover { startWindow(w.id) }
        }
    }

    func setHoverForTesting(_ row: WindowRow?) { model?.hover = row }
    var windowCountForTesting: Int { windows.count }
}
