import AppKit
import Combine

/// Thin, click-through outline of the saved area while the source mode is Area and idle.
@MainActor final class AreaOutline {
    static let shared = AreaOutline()
    private var window: NSWindow?
    private var bag = Set<AnyCancellable>()

    func start() {
        let s = AppSettings.shared
        Publishers.CombineLatest4(s.$sourceMode, s.$areaRect, s.$areaDisplayID, RecordingController.shared.$phase)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func update() {
        let s = AppSettings.shared
        guard s.sourceMode == .area, RecordingController.shared.phase == .idle, !AreaSelector.shared.isActive,
              let r = s.areaRect, let screen = Displays.screen(for: s.areaDisplayID) else { window?.orderOut(nil); return }
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.ignoresMouseEvents = true; w.level = .floating; w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            let v = NSView(); v.wantsLayer = true
            v.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
            v.layer?.borderWidth = 1.5
            w.contentView = v
            RecordingController.shared.engine.registerExcluded(w)
            window = w
        }
        // Stored top-left origin, display-local → AppKit global (bottom-left origin).
        guard let fitted = AreaGeometry.fit(r, in: screen.frame.size) else { window?.orderOut(nil); return }
        let frame = AreaGeometry.globalRect(fromLocal: fitted, screenFrame: screen.frame).insetBy(dx: -2, dy: -2)
        window?.setFrame(frame, display: true)
        window?.orderFrontRegardless()
    }
}
