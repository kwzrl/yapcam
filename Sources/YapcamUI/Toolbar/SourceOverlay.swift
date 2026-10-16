import AppKit
import SwiftUI

// MARK: - Pure geometry / hit testing (unit-tested)

enum OverlayGeometry {
    /// A rectangle in global CG coordinates (top-left origin) → local top-left coordinates on `screenFrame`
    /// (an AppKit frame, bottom-left origin). `primaryMaxY` is the top edge of the primary display in AppKit coordinates.
    static func localRect(cg r: CGRect, screenFrame f: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: r.minX - f.minX, y: r.minY - (primaryMaxY - f.maxY), width: r.width, height: r.height)
    }

    /// A display's frame in global CG coordinates (top-left origin).
    static func cgFrame(of f: CGRect, primaryMaxY: CGFloat) -> CGRect { CGRect(x: f.minX, y: primaryMaxY - f.maxY, width: f.width, height: f.height) }

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
    static func pick(from rows: [WindowRow], at point: CGPoint, excludingPID: Int32, ignoring: Set<UInt32> = []) -> WindowRow? {
        rows.first { $0.layer == 0 && $0.pid != excludingPID && !ignoring.contains($0.id) && $0.bounds.width >= 80 && $0.bounds.height >= 60 && $0.bounds.contains(point) }
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

// MARK: - Window actions through Accessibility (resize presets, bring to front)

enum WindowAX {
    enum Preset: String, CaseIterable, Identifiable {
        case wide = "16:9", standard = "4:3", tall = "9:16", wide1610 = "16:10", square = "1:1"
        var id: String { rawValue }
        var ratio: CGFloat {
            switch self { case .wide: 16.0 / 9; case .standard: 4.0 / 3; case .tall: 9.0 / 16; case .wide1610: 16.0 / 10; case .square: 1 }
        }
    }

    /// "1280x720", "1280 × 720" or "1280,720" → a size within 150…8192 per side; nil when it isn't two numbers.
    static func parseSize(_ text: String) -> CGSize? {
        let parts = text.lowercased().replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: ",", with: "x")
            .split(separator: "x").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w >= 150, h >= 150, w <= 8192, h <= 8192 else { return nil }
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    /// New size for a window of `size` that has the preset's aspect ratio, keeping its width where it fits
    /// in `limit` (the display) and shrinking otherwise. Never below 150 pt.
    static func fit(_ size: CGSize, preset: Preset, limit: CGSize) -> CGSize {
        var w = size.width, h = w / preset.ratio
        if h > limit.height { h = limit.height; w = h * preset.ratio }
        if w > limit.width { w = limit.width; h = w / preset.ratio }
        return CGSize(width: max(150, w.rounded()), height: max(150, h.rounded()))
    }

    private static func axWindow(pid: Int32, matching bounds: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let wins = value as? [AXUIElement] else { return nil }
        for w in wins {
            var p: CFTypeRef?, sz: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
                  AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sz) == .success else { continue }
            var pos = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &pos); AXValueGetValue(sz as! AXValue, .cgSize, &size)
            if abs(pos.x - bounds.minX) < 3, abs(pos.y - bounds.minY) < 3, abs(size.width - bounds.width) < 3, abs(size.height - bounds.height) < 3 { return w }
        }
        return nil
    }

    /// Resizes the window; false when Accessibility isn't granted or the window can't be found/resized.
    static func resize(pid: Int32, bounds: CGRect, to size: CGSize) -> Bool {
        guard AXIsProcessTrusted(), let w = axWindow(pid: pid, matching: bounds) else { return false }
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) == .success
    }

    static func raise(pid: Int32, bounds: CGRect) {
        NSRunningApplication(processIdentifier: pid)?.activate()
        if AXIsProcessTrusted(), let w = axWindow(pid: pid, matching: bounds) { AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
    }
}

// MARK: - The card: what will be recorded + Start recording

struct SourceCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let start: () -> Void
    var extras: (() -> AnyView)? = nil
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
                if let extras { extras() }
            }
            HStack(spacing: 1) {
                Button(action: start) {
                    Text(settings.afterRecording.recordLabel).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .frame(minWidth: 150, minHeight: 34)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 9, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous).fill(Color.red))
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                .accessibilityLabel("Start recording")
                Menu {
                    Picker("Frame rate", selection: $settings.maxFPS) { Text("60 fps").tag(60); Text("30 fps").tag(30) }
                    Picker("Countdown", selection: $settings.countdown) { Text("No countdown").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5); Text("10 seconds").tag(10) }
                    Picker("System audio", selection: $settings.systemAudioChoice) { ForEach(SystemAudioChoice.allCases) { Text($0.title).tag($0) } }
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
    @Published var notice: String?
    /// Windows the user chose to ignore for this overlay session (they are skipped when pointing).
    @Published var ignored: Set<UInt32> = []
    var onAdjustAsArea: ((CGRect, UInt32) -> Void)?
    var onRecordDisplay: ((UInt32) -> Void)?
    init(kind: Kind) { self.kind = kind }

    func resize(_ w: WindowRow, to preset: WindowAX.Preset, in limit: CGSize) {
        let size = WindowAX.fit(w.bounds.size, preset: preset, limit: limit)
        if !WindowAX.resize(pid: w.pid, bounds: w.bounds, to: size) {
            notice = AXIsProcessTrusted() ? "This window can't be resized." : "Allow Accessibility for Yapcam to resize windows."
        }
    }

    func resize(_ w: WindowRow, toSize size: CGSize) {
        if !WindowAX.resize(pid: w.pid, bounds: w.bounds, to: size) {
            notice = AXIsProcessTrusted() ? "This window can't be resized." : "Allow Accessibility for Yapcam to resize windows."
        }
    }

    func promptSize(_ w: WindowRow) {
        // The overlay covers the display above modal-panel level: step it aside while the prompt is up.
        guard let text = SourceOverlay.shared.loweredWhile({
            Prompt.text(title: "Window size", message: "Width × height in points, for example 1280x720",
                        initial: "\(Int(w.bounds.width))x\(Int(w.bounds.height))")
        }) else { return }
        guard let size = WindowAX.parseSize(text) else { notice = "Enter two numbers between 150 and 8192, like 1280x720."; return }
        resize(w, toSize: size)
    }

    func saveSize(of w: WindowRow) {
        let t = "\(Int(w.bounds.width))x\(Int(w.bounds.height))"
        var list = AppSettings.shared.savedWindowSizes
        list.removeAll { $0 == t }; list.insert(t, at: 0)
        AppSettings.shared.savedWindowSizes = Array(list.prefix(8))
    }

    func ignore(_ w: WindowRow) { ignored.insert(w.id); hover = nil }

    /// The window's rectangle becomes the area to record (then the area overlay opens to fine-tune it).
    func adjustAsArea(_ w: WindowRow, screenFrame: CGRect, primaryMaxY: CGFloat) {
        let local = OverlayGeometry.localRect(cg: w.bounds, screenFrame: screenFrame, primaryMaxY: primaryMaxY)
        if let id = NSScreen.screens.first(where: { $0.frame == screenFrame })?.displayID { onAdjustAsArea?(local, id) }
    }

    func recordDisplay(containing w: WindowRow) {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let center = CGPoint(x: w.bounds.midX, y: w.bounds.midY)
        let id = NSScreen.screens.first { OverlayGeometry.cgFrame(of: $0.frame, primaryMaxY: primaryMaxY).contains(center) }?.displayID
            ?? Displays.resolve(0)?.id
        if let id { onRecordDisplay?(id) }
    }
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

extension WindowOverlayRoot {
    /// The reference's window context actions, in our own words.
    @ViewBuilder func windowMenu(_ w: WindowRow) -> some View {
        Menu {
            Menu("Resize window") {
                ForEach(WindowAX.Preset.allCases) { p in
                    Button(p.rawValue) { model.resize(w, to: p, in: screenFrame.size) }
                }
                Divider()
                Button("Set size…") { model.promptSize(w) }
                Button("Save current size") { model.saveSize(of: w) }
                ForEach(AppSettings.shared.savedWindowSizes, id: \.self) { t in
                    Button(t) { if let size = WindowAX.parseSize(t) { model.resize(w, toSize: size) } }
                }
            }
            Button("Ignore this window") { model.ignore(w) }
            Button("Bring to front") { WindowAX.raise(pid: w.pid, bounds: w.bounds) }
            Button("Adjust as area") { model.adjustAsArea(w, screenFrame: screenFrame, primaryMaxY: primaryMaxY) }
            Button("Record entire display") { model.recordDisplay(containing: w) }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 16)).foregroundStyle(.secondary)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Window options").accessibilityLabel("Window options")
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
                               start: { start(w.id) },
                               extras: { AnyView(windowMenu(w)) })
                        .position(x: r.midX, y: r.midY)
                }
            } else {
                Text("Move the pointer over a window").font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 8).panelSurface(cornerRadius: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) {
            if let n = model.notice {
                Text(n).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 6)
                    .panelSurface(cornerRadius: 10).padding(.top, 40)
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
    var onReturn: (() -> Void)?
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screen.frame, display: false)
    }
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: if !event.isARepeat { onEscape?() }
        case 36, 76: if !event.isARepeat { onReturn?() }          // Return starts, like the Start recording button
        default: super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Click a source button → this overlay → Start recording. Display and window overlays live here;
/// the area overlay is `AreaSelector`.
@MainActor final class SourceOverlay {
    static let shared = SourceOverlay()
    private var windows: [OverlayWindow] = []
    private var model: SourceOverlayModel?
    private var timer: Timer?
    private var keyMonitor: Any?
    private var screenObserver: Any?
    var isActive: Bool { !windows.isEmpty }
    private var primaryMaxY: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    func show(_ kind: SourceOverlayModel.Kind) {
        hide(restoreFocus: false)
        AreaSelector.shared.end(nil, restoreFocus: false)
        let m = SourceOverlayModel(kind: kind)
        m.onAdjustAsArea = { [weak self] rect, displayID in
            AppSettings.shared.areaDisplayID = displayID; AppSettings.shared.areaRect = rect
            self?.hide(restoreFocus: false); AreaPicker.begin(onDisplay: displayID)
        }
        m.onRecordDisplay = { [weak self] id in self?.startDisplay(id) }
        model = m
        let settings = AppSettings.shared
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let info = Displays.info(for: id) else { continue }
            let w = OverlayWindow(screen: screen)
            w.onEscape = { [weak self] in self?.hide() }
            w.onReturn = { [weak self] in self?.startForTesting() }
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
        let key = windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? windows.first
        OverlayKeys.takeKeyboard(key)
        keyMonitor = OverlayKeys.install(window: key, start: { [weak self] in self?.startForTesting() }, cancel: { [weak self] in self?.hide() })
        // Display plugged/unplugged or rearranged: the windows would be on stale frames, so start over.
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        track()
        timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.track() } }
    }

    func hide(restoreFocus: Bool = true) {
        OverlayKeys.remove(keyMonitor); keyMonitor = nil
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
        if restoreFocus && !windows.isEmpty { OverlayFocus.restore() }
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
            let hit = WindowHit.pick(from: WindowHit.onScreenRows(), at: cg, excludingPID: ProcessInfo.processInfo.processIdentifier, ignoring: m.ignored)
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

    /// Runs `body` (a modal prompt) with the overlay windows below it and not catching clicks.
    func loweredWhile<T>(_ body: () -> T) -> T {
        let saved = windows.map { ($0, $0.level) }
        for w in windows { w.level = .normal; w.ignoresMouseEvents = true }
        defer { for (w, l) in saved { w.level = l; w.ignoresMouseEvents = false } }
        return body()
    }

    /// Start with the current choice (Return, or the Start/Stop shortcut while the overlay is up).
    func commit() { startForTesting() }

    func setHoverForTesting(_ row: WindowRow?) { model?.hover = row }
    var windowCountForTesting: Int { windows.count }
}
