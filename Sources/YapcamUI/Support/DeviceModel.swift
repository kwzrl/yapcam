@preconcurrency import AVFoundation
import AppKit
import SwiftUI

struct DeviceInfo: Identifiable, Equatable { let id: String; let name: String }

/// Cameras and microphones plus live mic level, for the toolbar menus.
/// Sessions only run while a popover is open (`startMeter` / `startPreview`).
@MainActor final class DeviceModel: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = DeviceModel()

    @Published private(set) var cameras: [DeviceInfo] = []
    @Published private(set) var microphones: [DeviceInfo] = []
    @Published private(set) var level: Float = 0
    @Published private(set) var meterError: String?
    private(set) var previewSession: AVCaptureSession?
    private var meterSession: AVCaptureSession?
    private let queue = DispatchQueue(label: "yapcam.meter")

    override private init() {
        super.init()
        reload()
        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    func reload() {
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                   mediaType: .video, position: .unspecified).devices
            .map { DeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                       mediaType: .audio, position: .unspecified).devices
            .map { DeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
        // A device that was selected but is gone counts as off; keep the id so it returns when plugged in.
    }

    func isAvailable(camera id: String?) -> Bool { id.map { i in cameras.contains { $0.id == i } } ?? false }
    func isAvailable(microphone id: String?) -> Bool { id.map { i in microphones.contains { $0.id == i } } ?? false }

    // MARK: Mic level

    func startMeter(deviceID: String?) {
        stopMeter()
        meterError = nil
        guard let id = deviceID, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let dev = AVCaptureDevice(uniqueID: id) else { return }
        let s = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            guard s.canAddInput(input) else { meterError = "Microphone is busy."; return }
            s.addInput(input)
            let out = AVCaptureAudioDataOutput()
            out.setSampleBufferDelegate(self, queue: queue)
            guard s.canAddOutput(out) else { return }
            s.addOutput(out)
        } catch { meterError = "Could not read the microphone. \(UserMessage.describe(error))"; return }
        meterSession = s
        queue.async { s.startRunning() }
    }

    func stopMeter() {
        if let s = meterSession { queue.async { s.stopRunning() } }
        meterSession = nil
        level = 0
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let channels = connection.audioChannels.first else { return }
        // Average power in dB (−160…0) → 0…1 with a −50 dB floor.
        let db = channels.averagePowerLevel
        let v = max(0, min(1, (db + 50) / 50))
        Task { @MainActor in self.level = v }
    }

    // MARK: Camera preview

    func startPreview(deviceID: String?) {
        stopPreview()
        guard let id = deviceID, AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let dev = AVCaptureDevice(uniqueID: id), let input = try? AVCaptureDeviceInput(device: dev) else { return }
        let s = AVCaptureSession()
        s.sessionPreset = .medium
        guard s.canAddInput(input) else { return }
        s.addInput(input)
        previewSession = s
        objectWillChange.send()
        queue.async { s.startRunning() }
    }

    func stopPreview() {
        if let s = previewSession { queue.async { s.stopRunning() } }
        previewSession = nil
        objectWillChange.send()
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession?
    func makeNSView(context: Context) -> PreviewHost { PreviewHost() }
    func updateNSView(_ v: PreviewHost, context: Context) { v.previewLayer.session = session }

    final class PreviewHost: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspectFill
            layer = previewLayer
        }
        required init?(coder: NSCoder) { fatalError() }
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(level > 0.9 ? Color.red : Color.green).frame(width: g.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Input level")
    }
}
