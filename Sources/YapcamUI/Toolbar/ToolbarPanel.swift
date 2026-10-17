import AppKit
import Combine
import SwiftUI

/// Floating, non-activating horizontal bar (the recording picker, and the widget while recording). Draggable by its background/grabber;
/// remembers its position per display (as a fraction of the display frame) and
/// stays on screen when displays change.
@MainActor final class ToolbarPanelController: NSObject, NSWindowDelegate {
    static let shared = ToolbarPanelController()

    private(set) var panel: ToolbarPanel!
    private var hosting: NSHostingView<AnyView>!
    private var bag = Set<AnyCancellable>()
    private let layout = ToolbarLayoutModel()
    private var isAdjusting = false
    private let defaults = AppDefaults.store

    private override init() {
        super.init()
        let p = ToolbarPanel(contentRect: CGRect(x: 0, y: 0, width: 560, height: 64),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.title = "Yapcam Toolbar"
        p.delegate = self
        panel = p

        hosting = NSHostingView(rootView: AnyView(
            ToolbarView(layout: layout)
                .environmentObject(RecordingController.shared)
                .environmentObject(AppSettings.shared)
                .environmentObject(PermissionsModel.shared)))
        hosting.sizingOptions = [.intrinsicContentSize]
        p.contentView = hosting

        RecordingController.shared.engine.registerExcluded(p)
        layout.move = { [weak self] dx, dy in
            guard let self else { return }
            panel.setFrameOrigin(CGPoint(x: panel.frame.minX + dx, y: panel.frame.minY + dy))
            clampToScreen()
            windowDidMove(Notification(name: NSWindow.didMoveNotification))
        }

        RecordingController.shared.$phase.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refit() } }.store(in: &bag)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private var keyMonitor: Any?

    /// Esc on the bar: deselect the open source, or close the bar when none is open; 1 / 2 / 3 pick a source.
    /// Only while the bar itself has the keyboard (not a popover or another app).
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, NSApp.keyWindow === panel, RecordingController.shared.phase == .idle, NSApp.modalWindow == nil,
                  !(panel.firstResponder is NSText) else { return event }
            let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            if event.keyCode == 53 { SourcePicker.escape(); return nil }
            if case .mode(let m) = OverlayKeys.action(keyCode: event.keyCode, typing: false, plain: plain) { SourcePicker.open(m); return nil }
            return event
        }
    }

    func show() {
        installKeys()
        CameraPreviewPanel.shared.start()
        refit(initial: true)
        panel.orderFrontRegardless()
        CameraPreviewPanel.shared.update()
        // SwiftUI reports its real size only after the first layout pass; fit again once it has run.
        DispatchQueue.main.async { [weak self] in self?.refit() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refit() }
    }

    func hide() { panel.orderOut(nil); CameraPreviewPanel.shared.update() }
    var isVisible: Bool { panel.isVisible }
    func toggle() { isVisible ? hide() : show() }

    // MARK: Sizing

    /// Resizes to fit the SwiftUI content, keeping the top edge fixed.
    private func refit(initial: Bool = false) {
        let size = hosting.intrinsicContentSize
        guard size.width > 0, size.height > 0 else { return }
        isAdjusting = true
        defer { isAdjusting = false }
        if initial && !panel.isVisible {
            panel.setFrame(CGRect(origin: .zero, size: size), display: false)
            panel.setFrameOrigin(initialOrigin(for: size))
        } else {
            panel.setFrame(ToolbarGeometry.resized(panel.frame, to: size), display: true)
        }
        clampToScreen()
        updateSide()
    }

    // MARK: Position (rules live in ToolbarGeometry)

    private func key(_ id: UInt32) -> String { "\(Self.positionKeyPrefix)\(id)" }
    /// The horizontal bar has its own saved positions (the old vertical toolbar's spots would not fit).
    static let positionKeyPrefix = "toolbarPos2."

    private var screens: [ScreenInfo] {
        NSScreen.screens.compactMap { s in
            s.displayID.map { ScreenInfo(id: $0, frame: s.frame, visibleFrame: s.visibleFrame, scale: s.backingScaleFactor) }
        }
    }

    private func savedFraction(_ id: UInt32) -> ToolbarGeometry.Fraction? {
        guard let a = defaults.array(forKey: key(id)) as? [Double], a.count == 2 else { return nil }
        return .init(x: a[0], y: a[1])
    }

    private var lastDisplay: UInt32? {
        let v = UInt32(defaults.integer(forKey: "toolbarLastDisplay")); return v == 0 ? nil : v
    }

    private func initialOrigin(for size: CGSize) -> CGPoint {
        let all = screens
        let mainID = NSScreen.main?.displayID
        guard let s = ToolbarGeometry.fallbackScreen(lastID: lastDisplay, mainID: mainID, in: all) else { return .zero }
        return ToolbarGeometry.origin(size: size, on: s, saved: savedFraction(s.id))
    }

    private func currentScreen() -> ScreenInfo? {
        ToolbarGeometry.screen(containing: panel.frame, in: screens)
            ?? ToolbarGeometry.fallbackScreen(lastID: lastDisplay, mainID: NSScreen.main?.displayID, in: screens)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isAdjusting, let screen = ToolbarGeometry.screen(containing: panel.frame, in: screens) else { return }
        let f = ToolbarGeometry.fraction(frame: panel.frame, on: screen)
        defaults.set([f.x, f.y], forKey: key(screen.id))
        defaults.set(Int(screen.id), forKey: "toolbarLastDisplay")
        updateSide()
    }

    private func clampToScreen() {
        guard let screen = currentScreen() else { return }
        let f = ToolbarGeometry.clamp(panel.frame, to: screen.visibleFrame)
        if f != panel.frame { panel.setFrame(f, display: true) }
    }

    @objc private func screensChanged() {
        guard panel.isVisible else { return }
        isAdjusting = true
        defer { isAdjusting = false }
        if let f = ToolbarGeometry.relocate(frame: panel.frame, screens: screens, lastID: lastDisplay,
                                            mainID: NSScreen.main?.displayID, saved: { self.savedFraction($0) }),
           f != panel.frame { panel.setFrame(f, display: true) }
        updateSide()
    }

    private func updateSide() {
        guard let screen = currentScreen() else { return }
        layout.onLeftHalf = ToolbarGeometry.onLeftHalf(frame: panel.frame, of: screen)
        layout.inLowerHalf = ToolbarGeometry.inLowerHalf(frame: panel.frame, of: screen)
    }
}

@MainActor final class ToolbarLayoutModel: ObservableObject {
    @Published var onLeftHalf = false
    @Published var inLowerHalf = true
    /// Moves the toolbar by (dx, dy) points; used by VoiceOver actions and keyboard users.
    var move: (CGFloat, CGFloat) -> Void = { _, _ in }
}

final class ToolbarPanel: NSPanel {
    // Needed so popover content (fields, menus) can take key status without activating the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
