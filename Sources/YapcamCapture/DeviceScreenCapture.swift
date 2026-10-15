@preconcurrency import AVFoundation
import Foundation
import ScreenCaptureKit

/// AVCapture control never blocks the main actor; samples share the writer queue.
@MainActor final class DeviceScreenStream: CaptureSessionStream {
    private let driver: DeviceScreenDriver
    init(id: String, audio: Bool, pixels: [Int], writer: SegmentWriter) {
        driver = DeviceScreenDriver(id: id, audio: audio, pixels: pixels, writer: writer)
    }
    func startCapture() async throws { try await driver.start() }
    func stopCapture() async throws { await driver.stop() }
    func updateContentFilter(_ filter: SCContentFilter) async throws {
        throw CaptureError.writerFailed("Mac window filters do not apply to a USB device screen")
    }
}

final class DeviceScreenDriver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let control = DispatchQueue(label: "mov.yapcam.capture.usb-screen")
    private let id: String
    private let audio: Bool
    private let pixels: [Int]
    private let writer: SegmentWriter
    private let lock = NSLock()
    private var sampleSession: AVCaptureSession? // lock; read on writer queue
    private var session: AVCaptureSession? // control queue
    private var outputs: [AVCaptureOutput] = []
    private var observers: [NSObjectProtocol] = []

    init(id: String, audio: Bool, pixels: [Int], writer: SegmentWriter) {
        self.id = id; self.audio = audio; self.pixels = pixels; self.writer = writer
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            control.async {
                do {
                    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                        throw CaptureError.permissionDenied(.camera)
                    }
                    if self.audio, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                        throw CaptureError.permissionDenied(.microphone)
                    }
                    let device = try DeviceScreenDiscovery.captureDevice(self.id)
                    let session = AVCaptureSession()
                    self.session = session
                    session.beginConfiguration()
                    do {
                        let input = try AVCaptureDeviceInput(device: device)
                        guard session.canAddInput(input) else { throw CaptureError.deviceLost(device.localizedName) }
                        session.addInput(input)
                        // Select native format directly on macOS (the iOS-only
                        // inputPriority preset is not available on this platform).
                        guard let format = device.formats.first(where: {
                            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                            return [Int(size.width), Int(size.height)] == self.pixels
                        }) else {
                            throw CaptureError.writerFailed("USB device native video format changed")
                        }
                        try device.lockForConfiguration()
                        device.activeFormat = format
                        device.unlockForConfiguration()
                        let video = AVCaptureVideoDataOutput()
                        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                        video.alwaysDiscardsLateVideoFrames = true
                        video.setSampleBufferDelegate(self, queue: self.writer.queue)
                        guard session.canAddOutput(video) else { throw CaptureError.deviceLost(device.localizedName) }
                        session.addOutput(video)
                        self.outputs.append(video)
                        if self.audio {
                            let output = AVCaptureAudioDataOutput()
                            output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM,
                                AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
                                AVLinearPCMIsNonInterleaved: false]
                            output.setSampleBufferDelegate(self, queue: self.writer.queue)
                            guard session.canAddOutput(output) else { throw CaptureError.writerFailed("USB device audio output unavailable") }
                            session.addOutput(output)
                            self.outputs.append(output)
                        }
                        session.commitConfiguration()
                    } catch {
                        session.commitConfiguration()
                        throw error
                    }
                    if self.audio, !self.outputs.contains(where: { ($0 as? AVCaptureAudioDataOutput)?.connection(with: .audio) != nil }) {
                        throw CaptureError.writerFailed("USB device provides no audio; disable device audio to record video")
                    }
                    self.lock.withLock { self.sampleSession = session }
                    let name = device.localizedName
                    for (notification, object) in [
                        (AVCaptureSession.runtimeErrorNotification, session as AnyObject),
                        (AVCaptureDevice.wasDisconnectedNotification, device as AnyObject)
                    ] {
                        self.observers.append(NotificationCenter.default.addObserver(forName: notification, object: object, queue: nil) { [weak self] _ in
                            self?.writer.fail(.deviceLost(name))
                        })
                    }
                    session.startRunning()
                    guard session.isRunning else { throw CaptureError.deviceLost(name) }
                    continuation.resume()
                } catch {
                    self.cleanUp()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            control.async { self.cleanUp(); continuation.resume() }
        }
    }

    private func cleanUp() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        session?.stopRunning()
        for output in outputs {
            (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
        }
        outputs.removeAll(); session = nil
        lock.withLock { sampleSession = nil }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let session = lock.withLock({ sampleSession }) else { return }
        guard let clock = session.synchronizationClock else {
            writer.fail(.writerFailed("USB device clock unavailable")); return
        }
        do {
            try DeviceScreenSamples.append(sampleBuffer, video: output is AVCaptureVideoDataOutput,
                                           clock: clock, pixels: pixels, writer: writer)
        } catch { writer.fail(CaptureError.from(error)) }
    }
}

enum DeviceScreenSamples {
    /// Caller runs on writer.queue; both outputs use the SAME session clock.
    static func append(_ sampleBuffer: CMSampleBuffer, video: Bool, clock: CMClock,
                       pixels: [Int], writer: SegmentWriter) throws {
        let sample = try CaptureClock.hostSample(sampleBuffer, from: clock)
        if video {
            guard let format = sample.formatDescription else { throw CaptureError.writerFailed("USB video format unavailable") }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            guard [Int(dimensions.width), Int(dimensions.height)] == pixels else {
                throw CaptureError.writerFailed("USB screen dimensions changed; start a new recording")
            }
        }
        writer.append(sample, track: video ? "screen" : "system_audio")
    }
}
