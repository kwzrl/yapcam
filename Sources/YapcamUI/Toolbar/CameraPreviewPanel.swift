@preconcurrency import AVFoundation
import AppKit
import Combine
import SwiftUI
import YapcamDesign

/// The floating camera preview that shows while the picker is open and a camera is chosen (reference: square shape,
/// hidden with "Hide camera preview"). It runs its own capture session, never the one the camera menu uses, and
/// is excluded from recordings.
@MainActor final class CameraPreviewPanel {
    static let shared = CameraPreviewPanel()

    /// Pure rule, unit-tested: when the preview is on screen.
    static func shouldShow(barVisible: Bool, phase: RecordingPhase, cameraID: String?, cameraAvailable: Bool,
                           permissionGranted: Bool, hidden: Bool) -> Bool {
        // While a take is counting down, running or paused the preview stays (it is excluded from the capture).
        let takeActive: Bool
        switch phase { case .idle, .finishing: takeActive = false; default: takeActive = true }
        return (barVisible || takeActive) && phase != .finishing && cameraID != nil && cameraAvailable && permissionGranted && !hidden
    }

    /// Paused takes dim the preview (it keeps the last frame).
    static func opacity(for phase: RecordingPhase) -> Double { phase == .paused ? 0.45 : 1 }

    /// Where the user left the panel on this display, if that spot is still on a screen.
    static func savedOrigin(_ stored: [Double]?, screens: [CGRect], size: CGFloat = 168) -> CGPoint? {
        guard let stored, stored.count == 2 else { return nil }
        let p = CGPoint(x: stored[0], y: stored[1])
        return screens.contains { $0.intersects(CGRect(origin: p, size: CGSize(width: size, height: size))) } ? p : nil
    }

    /// Where the preview's pictures come from: its own session until capture owns the camera, then the recording's stream.
    enum Source: Equatable { case standalone, recording }
    static func source(for phase: RecordingPhase) -> Source {
        switch phase { case .idle, .countdown, .finishing: .standalone; case .starting, .recording, .paused: .recording }
    }

    /// Text on the placeholder when the camera disappears during a take.
    static func disconnectedText(_ reason: String) -> String {
        reason.isEmpty ? "Camera disconnected" : "Camera disconnected\n\(reason)"
    }

    /// Called with the recording's camera stream.
    func receive(_ update: CameraPreviewFeed) {
        switch update {
        case .frame(let f):
            model.unavailable = nil
            let layer = model.displayLayer
            if layer.status == .failed { layer.flush() }
            layer.enqueue(f.sampleBuffer)
        case .unavailable(let why):
            model.displayLayer.flushAndRemoveImage()
            model.unavailable = Self.disconnectedText(why)
        }
    }

    var placeholderText: String? { model.unavailable }
    private var usingFeed = false
    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private var shownFor: String?
    private var bag = Set<AnyCancellable>()
    private let model = PreviewModel()

    final class PreviewModel: ObservableObject {
        @Published var session: AVCaptureSession?
        @Published var opacity = 1.0
        @Published var fromRecording = false
        @Published var unavailable: String?
        let displayLayer = AVSampleBufferDisplayLayer()
    }

    func start() {
        guard bag.isEmpty else { return }
        let s = AppSettings.shared
        Publishers.CombineLatest3(s.$cameraID, s.$hideCameraPreview, RecordingController.shared.$phase)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    /// Re-evaluates (also called when the bar is shown or hidden).
    func update() {
        let s = AppSettings.shared
        let show = Self.shouldShow(barVisible: ToolbarPanelController.shared.isVisible, phase: RecordingController.shared.phase,
                                   cameraID: s.cameraID, cameraAvailable: DeviceModel.shared.isAvailable(camera: s.cameraID),
                                   permissionGranted: PermissionsModel.shared.state(.camera) == .granted, hidden: s.hideCameraPreview)
        guard show, let id = s.cameraID else { hide(); return }
        if Self.source(for: RecordingController.shared.phase) == .recording {
            // Capture owns the camera now: stop the panel's own session and show the recording's stream.
            if !usingFeed { stopSession(); usingFeed = true; model.fromRecording = true; ensurePanel() }
        } else {
            if usingFeed { usingFeed = false; model.fromRecording = false; model.unavailable = nil; model.displayLayer.flushAndRemoveImage(); shownFor = nil }
            if shownFor != id { startSession(id) }
        }
        model.opacity = Self.opacity(for: RecordingController.shared.phase)
        place()
        panel?.orderFrontRegardless()
    }

    private func startSession(_ id: String) {
        stopSession()
        guard let dev = AVCaptureDevice(uniqueID: id), let input = try? AVCaptureDeviceInput(device: dev) else { return }
        let session = AVCaptureSession(); session.sessionPreset = .medium
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        self.session = session; shownFor = id
        model.session = session
        ensurePanel()
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    private func ensurePanel() {
        if panel == nil {
            let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 168, height: 168), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.level = .floating
            p.isMovableByWindowBackground = true; p.isReleasedWhenClosed = false; p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: PreviewView(model: model))
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { n in
                MainActor.assumeIsolated {
                    guard let w = n.object as? NSWindow, w.isVisible else { return }
                    AppDefaults.store.set([Double(w.frame.origin.x), Double(w.frame.origin.y)], forKey: "cameraPreviewOrigin")
                }
            }
            RecordingController.shared.engine.registerExcluded(p)
            panel = p
        }
    }

    private func stopSession() {
        if let s = session { DispatchQueue.global(qos: .utility).async { s.stopRunning() } }
        session = nil; shownFor = nil; model.session = nil
    }

    /// Above the bar when there is room, else below it.
    private func place() {
        guard let panel, let bar = Optional(ToolbarPanelController.shared.panel.frame) else { return }
        var origin = CGPoint(x: bar.midX - 84, y: bar.maxY + 12)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: bar.midX, y: bar.midY)) }), origin.y + 168 > screen.visibleFrame.maxY {
            origin.y = bar.minY - 168 - 12
        }
        if !panel.isVisible {
            let key = "cameraPreviewOrigin"
            origin = Self.savedOrigin(AppDefaults.store.array(forKey: key) as? [Double], screens: NSScreen.screens.map(\.frame)) ?? origin
            panel.setFrameOrigin(origin)
        }
    }

    func hide() {
        panel?.orderOut(nil)
        stopSession()
        if usingFeed { usingFeed = false; model.fromRecording = false; model.unavailable = nil; model.displayLayer.flushAndRemoveImage() }
    }

    /// Shows the recording's camera frames, mirrored like the picker's preview.
    private struct RecordingFeedView: NSViewRepresentable {
        let layer: AVSampleBufferDisplayLayer
        func makeNSView(context: Context) -> NSView {
            let v = NSView(); v.wantsLayer = true
            layer.videoGravity = .resizeAspectFill
            layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            layer.frame = v.bounds; layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            v.layer?.addSublayer(layer)
            return v
        }
        func updateNSView(_ v: NSView, context: Context) {}
    }

    private struct PreviewView: View {
        @ObservedObject var model: PreviewModel
        var body: some View {
            Group {
                if let text = model.unavailable {
                    ZStack {
                        Yap.recess
                        VStack(spacing: 6) {
                            Image(systemName: "video.slash").font(.system(size: 22))
                            Text(text).font(.caption).multilineTextAlignment(.center)
                        }.foregroundStyle(.secondary).padding(8)
                    }
                } else if model.fromRecording {
                    RecordingFeedView(layer: model.displayLayer)
                } else {
                    CameraPreview(session: model.session)
                }
            }
                .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 40, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .padding(4)
                .opacity(model.opacity)
                .accessibilityLabel("Camera preview")
        }
    }
}
