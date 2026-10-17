import AppKit
import YapcamCapture
import SwiftUI
import YapcamDesign

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
    /// `allowed`: the window ids capture reports as recordable (nil until the first answer arrives): system and
    /// helper windows that capture filters out are never offered.
    static func pick(from rows: [WindowRow], at point: CGPoint, excludingPID: Int32, ignoring: Set<UInt32> = [], allowed: Set<UInt32>? = nil) -> WindowRow? {
        rows.first { $0.layer == 0 && $0.pid != excludingPID && !ignoring.contains($0.id) && (allowed?.contains($0.id) ?? true) && $0.bounds.width >= 80 && $0.bounds.height >= 60 && $0.bounds.contains(point) }
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

/// Window sizes for "resize the window you record". The resize itself is capture's `CaptureWindowControl`
/// (typed errors, checks the size the app actually applied); this enum only shapes the menu and parses typed sizes.
enum WindowAX {
    struct SizeGroup: Identifiable, Equatable { let name: String; let sizes: [CGSize]; var id: String { name } }

    /// Capture's exact presets that fit `limit` (the display in points), grouped in the reference order; empty groups drop out.
    static func groups(fitting limit: CGSize) -> [SizeGroup] {
        var out: [SizeGroup] = []
        for p in CaptureWindowSizePreset.fitting(in: limit) {
            let name = p.group == .square ? "Square" : p.group.rawValue
            if let i = out.firstIndex(where: { $0.name == name }) { out[i] = SizeGroup(name: name, sizes: out[i].sizes + [p.size]) }
            else { out.append(SizeGroup(name: name, sizes: [p.size])) }
        }
        return out
    }

    static func label(_ s: CGSize) -> String { "\(Int(s.width)) × \(Int(s.height))" }

    /// "1280x720", "1280 × 720" or "1280,720" → a size within 150…8192 per side; nil when it isn't two numbers.
    static func parseSize(_ text: String) -> CGSize? {
        let parts = text.lowercased().replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: ",", with: "x")
            .split(separator: "x").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w >= 150, h >= 150, w <= 8192, h <= 8192 else { return nil }
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    /// What to tell the user when a resize did not happen (typed capture errors; permission first).
    static func resizeMessage(for error: Error) -> String {
        if case CaptureError.permissionDenied = error { return "Allow Accessibility for Yapcam to resize windows." }
        if case CaptureError.sourceUnavailable = error { return "That window is gone. Point at it again." }
        return error.localizedDescription
    }
}

// MARK: - The card: what will be recorded + Start recording

struct SourceCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let start: () -> Void
    /// The app's icon (window mode); the SF Symbol stands in when there is none.
    var icon: NSImage? = nil
    /// Right of the size text (window mode: the Resize menu).
    var sizeExtras: (() -> AnyView)? = nil
    var extras: (() -> AnyView)? = nil
    @EnvironmentObject var settings: AppSettings
    @Environment(\.contrastOpacity) private var contrast

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 40, height: 40).accessibilityHidden(true) }
                else { Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.secondary).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        if let sizeExtras { sizeExtras() }
                    }
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
                    Picker("After recording", selection: $settings.afterRecording) { ForEach(AfterRecording.allCases) { Text($0.title).tag($0) } }
                    Picker("Countdown", selection: $settings.countdown) { ForEach(GearMenu.countdownChoices, id: \.1) { Text($0.0).tag($0.1) } }
                    Picker("System audio", selection: $settings.systemAudioChoice) { ForEach(SystemAudioChoice.allCases) { Text($0.title).tag($0) } }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 34)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 9, topTrailingRadius: 9, style: .continuous).fill(Color.red.opacity(0.88)))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Recording options")
            }
            CancelHint()
        }
        .padding(18)
        .panelSurface(cornerRadius: 16)
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }
}

/// "Esc to cancel" that can also be clicked: the same path as the key (closes the overlay, clears the mode).
private struct CancelHint: View {
    @State private var hover = false

    var body: some View {
        Button { SourcePicker.escape() } label: {
            Text("Esc to cancel").font(.system(size: 11, weight: hover ? .medium : .regular))
                .foregroundStyle(hover ? Yap.title : Yap.caption)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.08)).opacity(hover ? 1 : 0).scaleEffect(hover ? 1 : 0.9))
                .animation(hover ? .snappy(duration: 0.14) : .smooth(duration: 0.3), value: hover)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Cancel (Esc)")
        .accessibilityLabel("Cancel")
    }
}

// MARK: - SwiftUI roots hosted in the overlay windows

@MainActor final class SourceOverlayModel: ObservableObject {
    enum Kind { case display, window }
    let kind: Kind
    @Published var activeDisplayID: UInt32 = 0
    @Published var hover: WindowRow?
    /// Recordable window ids from capture (refreshed while the window overlay is up).
    var allowedWindows: Set<UInt32>?
    private var allowedLoadedAt = Date.distantPast
    func refreshAllowed() {
        guard Date().timeIntervalSince(allowedLoadedAt) > 2 else { return }
        allowedLoadedAt = Date()
        Task { @MainActor in
            if let sources = try? await CaptureSources.load(includeWindowThumbnails: false) { allowedWindows = Set(sources.windows.map(\.id)) }
        }
    }
    /// A display chosen from the Display button's context menu: its card stays put instead of following the pointer.
    var pinnedDisplay: UInt32?
    @Published var notice: String?
    /// Windows the user chose to ignore for this overlay session (they are skipped when pointing).
    @Published var ignored: Set<UInt32> = []
    var onAdjustAsArea: ((CGRect, UInt32) -> Void)?
    var onRecordDisplay: ((UInt32) -> Void)?
    init(kind: Kind) { self.kind = kind }

    /// Resizes the real window through capture's Accessibility control and reports what the app actually did.
    func resize(_ w: WindowRow, toSize size: CGSize) {
        if let issue = CapturePreflight.windowResizeIssue() { notice = issue.message; return }
        Task { @MainActor in
            do {
                let actual = try await CaptureWindowControl.resize(windowID: w.id, to: size)
                notice = "Window is now \(Int(actual.width)) × \(Int(actual.height))."
                if hover?.id == w.id { hover = WindowRow(id: w.id, pid: w.pid, layer: w.layer, app: w.app, title: w.title, bounds: actual) }
            } catch { notice = WindowAX.resizeMessage(for: error) }
        }
    }

    func promptSize(_ w: WindowRow) {
        // The overlay covers the display above modal-panel level: step it aside while the prompt is up.
        guard let text = SourceOverlay.shared.loweredWhile({
            Prompt.text(title: "Window size", message: "Width × height in points, for example 1280x720",
                        initial: "\(Int(w.bounds.width))x\(Int(w.bounds.height))")
        }) else { return }
        applyTypedSize(text, to: w)
    }

    /// What the "Custom…" prompt does with the text typed: resize, or explain what is accepted.
    func applyTypedSize(_ text: String, to w: WindowRow) {
        guard let size = WindowAX.parseSize(text) else { notice = "Enter two numbers between 150 and 8192, like 1280x720."; return }
        resize(w, toSize: size)
    }

    func saveSize(of w: WindowRow, in settings: AppSettings = .shared) {
        let t = "\(Int(w.bounds.width))x\(Int(w.bounds.height))"
        var list = settings.savedWindowSizes
        list.removeAll { $0 == t }; list.insert(t, at: 0)
        settings.savedWindowSizes = Array(list.prefix(8))
    }

    struct AppWindows: Identifiable { let app: String; let rows: [WindowRow]; var id: String { app } }
    /// Recordable windows grouped by app (own windows, system layers and ignored windows left out).
    func windowsByApp() -> [AppWindows] {
        let own = ProcessInfo.processInfo.processIdentifier
        let rows = WindowHit.onScreenRows().filter { $0.layer == 0 && $0.pid != own && !ignored.contains($0.id) && (allowedWindows?.contains($0.id) ?? true) && $0.bounds.width >= 80 && $0.bounds.height >= 60 }
        return Dictionary(grouping: rows, by: \.app).map { AppWindows(app: $0.key, rows: $0.value) }.sorted { $0.app.localizedCaseInsensitiveCompare($1.app) == .orderedAscending }
    }

    /// Chooses a window from the menu: it stays highlighted until the pointer moves.
    @Published var pinned: (row: WindowRow, at: CGPoint)?
    func select(_ w: WindowRow) { pinned = (w, NSEvent.mouseLocation); hover = w }

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
                           subtitle: display.detail,
                           start: { start(display.id) })
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose display to record")
    }
}

extension WindowOverlayRoot {
    /// "Resize": exact sizes that fit the display, Custom…, and saved sizes.
    @ViewBuilder func resizeMenu(_ w: WindowRow) -> some View {
        Menu {
            ForEach(WindowAX.groups(fitting: screenFrame.size)) { g in
                Menu(g.name) {
                    ForEach(g.sizes, id: \.self) { size in Button(WindowAX.label(size)) { model.resize(w, toSize: size) } }
                }
            }
            Divider()
            Button("Custom…") { model.promptSize(w) }
            Button("Save current size") { model.saveSize(of: w) }
            let saved = AppSettings.shared.savedWindowSizes
            ForEach(saved, id: \.self) { t in
                Button(t.replacingOccurrences(of: "x", with: " × ")) { if let size = WindowAX.parseSize(t) { model.resize(w, toSize: size) } }
            }
            if !saved.isEmpty { Divider(); Button("Delete saved sizes") { AppSettings.shared.savedWindowSizes = [] } }
        } label: { Text("Resize").font(.system(size: 11, weight: .medium)) }
        .menuStyle(.button).menuIndicator(.hidden).fixedSize().controlSize(.small)
        .help("Resize this window to an exact size (needs Accessibility)").accessibilityLabel("Resize window")
    }

    /// The reference's window context actions, in our own words.
    @ViewBuilder func windowMenu(_ w: WindowRow) -> some View {
        Menu {
            Button("Ignore this window") { model.ignore(w) }
            if !model.ignored.isEmpty { Button("Reset ignored windows") { model.ignored = [] } }
            Menu("Select window") {
                ForEach(model.windowsByApp()) { g in
                    Menu(g.app) { ForEach(g.rows, id: \.id) { r in Button(r.title.isEmpty ? g.app : r.title) { model.select(r) } } }
                }
            }
            Button("Bring to front") { do { try CaptureWindowControl.raise(windowID: w.id) } catch { NSRunningApplication(processIdentifier: w.pid)?.activate() } }
            Button("Adjust recording area…") { model.adjustAsArea(w, screenFrame: screenFrame, primaryMaxY: primaryMaxY) }
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
                    SourceCard(symbol: "macwindow", title: w.app,
                               subtitle: "\(Int(w.bounds.width)) × \(Int(w.bounds.height))",
                               start: { start(w.id) },
                               icon: NSRunningApplication(processIdentifier: w.pid)?.icon,
                               sizeExtras: { AnyView(resizeMenu(w)) },
                               extras: { AnyView(windowMenu(w)) })
                        .position(x: r.midX, y: r.midY)
                    Button { model.adjustAsArea(w, screenFrame: screenFrame, primaryMaxY: primaryMaxY) } label: {
                        Text("Adjust recording area").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                    .position(x: r.midX, y: max(r.minY + 16, min(r.maxY - 24, screenFrame.height - 24)))
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

    func show(_ kind: SourceOverlayModel.Kind, pinnedDisplay: UInt32? = nil) {
        hide(restoreFocus: false)
        AreaSelector.shared.end(nil, restoreFocus: false)
        let m = SourceOverlayModel(kind: kind)
        m.onAdjustAsArea = { [weak self] rect, displayID in
            AppSettings.shared.areaDisplayID = displayID; AppSettings.shared.areaRect = rect
            self?.hide(restoreFocus: false); AreaPicker.begin(onDisplay: displayID)
        }
        m.onRecordDisplay = { [weak self] id in self?.startDisplay(id) }
        m.pinnedDisplay = pinnedDisplay
        if let pinnedDisplay { m.activeDisplayID = pinnedDisplay }
        model = m
        let settings = AppSettings.shared
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let info = Displays.info(for: id) else { continue }
            let w = OverlayWindow(screen: screen)
            w.onEscape = { SourcePicker.escape() }   // first Esc clears the mode; the next one closes the bar
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
        keyMonitor = OverlayKeys.install(window: key, start: { [weak self] in self?.startForTesting() }, cancel: { [weak self] in self?.hide() },
                                         mode: { SourcePicker.open($0) })
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
        if PickerState.shared.openMode == .display || PickerState.shared.openMode == .window { PickerState.shared.openMode = nil }
    }

    /// Follow the pointer: the card moves to the display under it; the highlight to the window under it.
    private func track() {
        guard let m = model else { return }
        let p = NSEvent.mouseLocation
        if m.pinnedDisplay == nil, let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }), let id = screen.displayID, m.activeDisplayID != id { m.activeDisplayID = id }
        if m.kind == .window {
            let cg = OverlayGeometry.cgPoint(fromAppKit: p, primaryMaxY: primaryMaxY)
            if let pin = m.pinned {
                if hypot(p.x - pin.at.x, p.y - pin.at.y) < 6 { return }
                m.pinned = nil
            }
            m.refreshAllowed()
            let hit = WindowHit.pick(from: WindowHit.onScreenRows(), at: cg, excludingPID: ProcessInfo.processInfo.processIdentifier, ignoring: m.ignored, allowed: m.allowedWindows)
            if hit != m.hover { m.hover = hit }
        }
    }

    private func startDisplay(_ id: UInt32) {
        SourceChoice.display(id).apply(to: AppSettings.shared)
        hide(); beginSoon()
    }

    private func startWindow(_ id: UInt32) {
        SourceChoice.window(id).apply(to: AppSettings.shared)
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
