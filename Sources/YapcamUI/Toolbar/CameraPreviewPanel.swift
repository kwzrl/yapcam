@preconcurrency import AVFoundation
import AppKit
import Combine
import SwiftUI

/// The floating camera preview that shows while the picker is open and a camera is chosen (reference: square shape,
/// hidden with "Hide camera preview"). It runs its own capture session, never the one the camera menu uses, and
/// is excluded from recordings.
@MainActor final class CameraPreviewPanel {
    static let shared = CameraPreviewPanel()

    /// Pure rule, unit-tested: when the preview is on screen.
    static func shouldShow(barVisible: Bool, phase: RecordingPhase, cameraID: String?, cameraAvailable: Bool,
                           permissionGranted: Bool, hidden: Bool) -> Bool {
        barVisible && phase == .idle && cameraID != nil && cameraAvailable && permissionGranted && !hidden
    }

    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private var shownFor: String?
    private var bag = Set<AnyCancellable>()
    private let model = PreviewModel()

    final class PreviewModel: ObservableObject { @Published var session: AVCaptureSession? }

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
        if shownFor != id { startSession(id) }
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
        if panel == nil {
            let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 168, height: 168), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.level = .floating
            p.isMovableByWindowBackground = true; p.isReleasedWhenClosed = false; p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: PreviewView(model: model))
            RecordingController.shared.engine.registerExcluded(p)
            panel = p
        }
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
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
        if !panel.isVisible { panel.setFrameOrigin(origin) }
    }

    func hide() {
        panel?.orderOut(nil)
        stopSession()
    }

    private struct PreviewView: View {
        @ObservedObject var model: PreviewModel
        var body: some View {
            CameraPreview(session: model.session)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .padding(4)
                .accessibilityLabel("Camera preview")
        }
    }
}
