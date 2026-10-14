@preconcurrency import AVFoundation
import Foundation

/// Session configuration/start/stop runs away from the main thread. All sample
/// delegates run on the same queue as screen capture and the asset writers.
final class AuxiliaryCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let control = DispatchQueue(label: "mov.yapcam.capture.devices")
    private let writer: SegmentWriter
    private let fps: Int
    private var sessions: [AVCaptureSession] = [] // control queue only
    private var observers: [NSObjectProtocol] = []
    private let sessionLock = NSLock()
    private var outputSessions: [ObjectIdentifier: AVCaptureSession] = [:] // sessionLock
    var onWarning: (@Sendable (String) -> Void)?

    init(writer: SegmentWriter, fps: Int) { self.writer = writer; self.fps = fps }

    struct Metadata: Sendable { var mic: AudioMetadata?; var camera: CameraMetadata? }

    func start(microphoneID: String?, cameraID: String?) async -> Metadata {
        await withCheckedContinuation { continuation in
            control.async {
                var result = Metadata()
                for (id, media) in [(microphoneID, AVMediaType.audio), (cameraID, AVMediaType.video)] {
                    guard let id else { continue }
                    do {
                        let session = AVCaptureSession()
                        let types: [AVCaptureDevice.DeviceType] = media == .video
                            ? [.builtInWideAngleCamera, .external, .continuityCamera] : [.microphone, .external]
                        guard AVCaptureDevice.authorizationStatus(for: media) == .authorized else {
                            throw CaptureError.permissionDenied(media == .video ? .camera : .microphone)
                        }
                        guard let device = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: media, position: .unspecified)
                            .devices.first(where: { $0.uniqueID == id }), device.isConnected else { throw CaptureError.deviceLost(id) }
                        session.beginConfiguration()
                        var committed = false
                        defer { if !committed { session.commitConfiguration() } }
                        var sampleOutput: AVCaptureOutput?
                        let input = try AVCaptureDeviceInput(device: device)
                        guard session.canAddInput(input) else { throw CaptureError.deviceLost(device.localizedName) }
                        session.addInput(input)
                        if media == .video {
                            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                            let output = AVCaptureVideoDataOutput()
                            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                            output.alwaysDiscardsLateVideoFrames = true
                            output.setSampleBufferDelegate(self, queue: self.writer.queue)
                            guard session.canAddOutput(output) else { throw CaptureError.deviceLost(device.localizedName) }
                            session.addOutput(output)
                            sampleOutput = output
                            if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                                connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
                            }
                            try device.lockForConfiguration()
                            let rates = device.activeFormat.videoSupportedFrameRateRanges
                            let actualFPS = [self.fps, 30].first { fps in
                                rates.contains { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) }
                            }
                            guard let actualFPS else {
                                device.unlockForConfiguration()
                                throw CaptureError.writerFailed("Camera does not support 30 or 60 fps in its current format")
                            }
                            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(actualFPS))
                            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(actualFPS))
                            device.unlockForConfiguration()
                            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                            result.camera = CameraMetadata(deviceName: device.localizedName, pixelSize: [Int(dimensions.width), Int(dimensions.height)], fps: actualFPS)
                        } else {
                            let output = AVCaptureAudioDataOutput()
                            output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                                AVNumberOfChannelsKey: 1, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32]
                            output.setSampleBufferDelegate(self, queue: self.writer.queue)
                            guard session.canAddOutput(output) else { throw CaptureError.deviceLost(device.localizedName) }
                            session.addOutput(output)
                            sampleOutput = output
                            result.mic = AudioMetadata(deviceName: device.localizedName, sampleRate: 48_000, channels: 1)
                        }
                        session.commitConfiguration()
                        committed = true
                        if let sampleOutput {
                            self.sessionLock.withLock { self.outputSessions[ObjectIdentifier(sampleOutput)] = session }
                        }
                        let name = device.localizedName
                        let track: AuxiliaryTrack = media == .video ? .camera : .microphone
                        self.observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
                            self?.writer.deviceUnavailable(track, reason: "\(name) stopped responding; screen recording continues.")
                        })
                        self.observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                            self?.writer.deviceUnavailable(track, reason: "\(name) disconnected; screen recording continues.")
                        })
                        self.sessions.append(session)
                        session.startRunning()
                        if !session.isRunning {
                            self.onWarning?("\(name) could not start; screen recording continues.")
                            if media == .video { result.camera = nil } else { result.mic = nil }
                        }
                    } catch {
                        self.onWarning?("\(media == .video ? "Camera" : "Microphone"): \(error.localizedDescription) Screen recording continues.")
                        if media == .video { result.camera = nil } else { result.mic = nil }
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            control.async {
                self.sessions.forEach { $0.stopRunning() }; self.sessions.removeAll()
                self.sessionLock.withLock { self.outputSessions.removeAll() }
                self.observers.forEach { NotificationCenter.default.removeObserver($0) }; self.observers.removeAll()
                continuation.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let input = connection.inputPorts.first?.input as? AVCaptureDeviceInput,
              input.device.isConnected else { return }
        let track: AuxiliaryTrack = output is AVCaptureVideoDataOutput ? .camera : .microphone
        // Output timestamps use the session synchronizationClock, not the input
        // port's native device clock (AVCaptureSession.h documents this explicitly).
        guard let session = sessionLock.withLock({ outputSessions[ObjectIdentifier(output)] }),
              let clock = session.synchronizationClock else {
            writer.deviceUnavailable(track, reason: "Capture device clock unavailable; screen recording continues.")
            return
        }
        do { writer.append(try CaptureClock.hostSample(sampleBuffer, from: clock), track: track.rawValue) }
        catch { writer.deviceUnavailable(track, reason: "Capture device timestamps invalid; screen recording continues.") }
    }
}
