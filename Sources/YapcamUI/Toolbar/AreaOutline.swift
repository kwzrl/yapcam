import AppKit
import Combine

/// Thin, click-through outline of the saved area while the source mode is Area and idle.
@MainActor final class AreaOutline {
    static let shared = AreaOutline()
    private var window: NSWindow?
    private var dimWindow: NSWindow?
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

    /// While an area is being recorded, dim everything outside it (setting "Highlight recorded area").
    /// The dim window is excluded from capture, so the recording itself is unaffected.
    private func updateDim() {
        let s = AppSettings.shared
        let recording = RecordingController.shared.isRecording
        guard recording, s.highlightRecordedArea, s.sourceMode == .area, let r = s.areaRect,
              let screen = Displays.screen(for: s.areaDisplayID), let fitted = AreaGeometry.fit(r, in: screen.frame.size) else {
            dimWindow?.orderOut(nil); return
        }
        if dimWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.ignoresMouseEvents = true; w.level = .floating; w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            w.contentView = DimView()
            RecordingController.shared.engine.registerExcluded(w)
            dimWindow = w
        }
        (dimWindow?.contentView as? DimView)?.hole = fitted     // top-left display-local points
        dimWindow?.setFrame(screen.frame, display: true)
        dimWindow?.orderFrontRegardless()
    }

    private func update() {
        updateDim()
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


/// Black veil with a clear hole over the recorded area.
private final class DimView: NSView {
    var hole: CGRect = .zero { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        NSGraphicsContext.current?.compositingOperation = .clear
        hole.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }
}
