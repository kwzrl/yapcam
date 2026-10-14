import AppKit
import Combine
import SwiftUI

/// Floating, non-activating vertical toolbar. Draggable by its background/grabber;
/// remembers its position per display (as a fraction of the display frame) and
/// stays on screen when displays change.
@MainActor final class ToolbarPanelController: NSObject, NSWindowDelegate {
    static let shared = ToolbarPanelController()

    private(set) var panel: ToolbarPanel!
    private var hosting: NSHostingView<AnyView>!
    private var bag = Set<AnyCancellable>()
    private let layout = ToolbarLayoutModel()
    private var isAdjusting = false
    private let defaults = UserDefaults.standard

    private override init() {
        super.init()
        let p = ToolbarPanel(contentRect: CGRect(x: 0, y: 0, width: 64, height: 300),
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
        hosting.sizingOptions = []
        p.contentView = hosting

        RecordingController.shared.engine.registerExcluded(p)

        RecordingController.shared.$phase.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refit() } }.store(in: &bag)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func show() {
        refit(initial: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
    var isVisible: Bool { panel.isVisible }
    func toggle() { isVisible ? hide() : show() }

    // MARK: Sizing

    /// Resizes to fit the SwiftUI content, keeping the top edge fixed.
    private func refit(initial: Bool = false) {
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        isAdjusting = true
        defer { isAdjusting = false }
        if initial && !panel.isVisible {
            let frame = CGRect(origin: .zero, size: size)
            panel.setFrame(frame, display: false)
            panel.setFrameOrigin(initialOrigin(for: size))
        } else {
            var f = panel.frame
            let top = f.maxY
            f.size = size
            f.origin.y = top - size.height
            panel.setFrame(f, display: true)
        }
        clampToScreen()
        updateSide()
    }

    // MARK: Position

    private func key(_ id: CGDirectDisplayID) -> String { "toolbarPos.\(id)" }

    private func initialOrigin(for size: CGSize) -> CGPoint {
        let lastID = UInt32(defaults.integer(forKey: "toolbarLastDisplay"))
        let screen = Displays.screen(for: lastID) ?? NSScreen.main ?? NSScreen.screens[0]
        let id = screen.displayID ?? 0
        let vis = screen.visibleFrame
        if let a = defaults.array(forKey: key(id)) as? [Double], a.count == 2 {
            // Stored as fraction of the screen frame for the toolbar's top-left corner.
            let f = screen.frame
            return CGPoint(x: f.minX + a[0] * f.width, y: f.minY + a[1] * f.height - size.height)
        }
        // Default: right edge, vertically centered, 24 pt inset.
        return CGPoint(x: vis.maxX - size.width - 24, y: vis.midY - size.height / 2)
    }

    private func currentScreen() -> NSScreen? {
        let c = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(c) } ?? panel.screen ?? NSScreen.main
    }

    func windowDidMove(_ notification: Notification) {
        guard !isAdjusting, let screen = currentScreen(), let id = screen.displayID else { return }
        let f = screen.frame
        let topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        defaults.set([(topLeft.x - f.minX) / f.width, (topLeft.y - f.minY) / f.height], forKey: key(id))
        defaults.set(Int(id), forKey: "toolbarLastDisplay")
        updateSide()
    }

    private func clampToScreen() {
        guard let screen = currentScreen() else { return }
        let vis = screen.visibleFrame
        var f = panel.frame
        f.origin.x = min(max(f.origin.x, vis.minX + 4), vis.maxX - f.width - 4)
        f.origin.y = min(max(f.origin.y, vis.minY + 4), vis.maxY - f.height - 4)
        if f != panel.frame { panel.setFrame(f, display: true) }
    }

    @objc private func screensChanged() {
        guard panel.isVisible else { return }
        // If the display we were on is gone, move to the saved spot on the main display.
        let c = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        isAdjusting = true
        defer { isAdjusting = false }
        if !NSScreen.screens.contains(where: { $0.frame.contains(c) }) {
            panel.setFrameOrigin(initialOrigin(for: panel.frame.size))
        }
        clampToScreen()
        updateSide()
    }

    /// Popovers open toward the screen's center: right of the toolbar when it is on the left half.
    private func updateSide() {
        guard let screen = currentScreen() else { return }
        layout.onLeftHalf = panel.frame.midX < screen.frame.midX
    }
}

@MainActor final class ToolbarLayoutModel: ObservableObject {
    @Published var onLeftHalf = false
}

final class ToolbarPanel: NSPanel {
    // Needed so popover content (fields, menus) can take key status without activating the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
