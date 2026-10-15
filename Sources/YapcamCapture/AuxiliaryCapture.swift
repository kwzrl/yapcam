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
    private var cameraSizes: [ObjectIdentifier: [Int]] = [:] // sessionLock
    var onWarning: (@Sendable (String) -> Void)?

    init(writer: SegmentWriter, fps: Int) { self.writer = writer; self.fps = fps }

    struct Metadata: Sendable { var mic: AudioMetadata?; var camera: CameraMetadata? }

    func start(microphoneID: String?, cameraID: String?, cameraMaxResolution: CameraMaxResolution = .hd1080) async -> Metadata {
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
                            let choice = try CameraFormatPolicy.configure(device, maximum: cameraMaxResolution, fps: self.fps)
                            self.sessionLock.withLock { self.cameraSizes[ObjectIdentifier(output)] = [choice.width, choice.height] }
                            result.camera = CameraMetadata(deviceName: device.localizedName,
                                pixelSize: [choice.width, choice.height], fps: choice.fps)
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
                self.sessionLock.withLock { self.outputSessions.removeAll(); self.cameraSizes.removeAll() }
                self.observers.forEach { NotificationCenter.default.removeObserver($0) }; self.observers.removeAll()
                continuation.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let input = connection.inputPorts.first?.input as? AVCaptureDeviceInput,
              input.device.isConnected else { return }
        let track: AuxiliaryTrack = output is AVCaptureVideoDataOutput ? .camera : .microphone
        let session = sessionLock.withLock { outputSessions[ObjectIdentifier(output)] }
        let expected = sessionLock.withLock { cameraSizes[ObjectIdentifier(output)] }
        AuxiliarySamples.append(sampleBuffer, track: track, clock: session?.synchronizationClock,
                                cameraPixels: expected, writer: writer)
    }
}

/// The AV delegates and this router run on writer.queue. Keeping validation here
/// lets real sample buffers exercise format/clock failures without camera hardware.
enum AuxiliarySamples {
    static func append(_ sample: CMSampleBuffer, track: AuxiliaryTrack, clock: CMClock?,
                       cameraPixels: [Int]?, writer: SegmentWriter) {
        dispatchPrecondition(condition: .onQueue(writer.queue))
        if track == .camera {
            guard let format = sample.formatDescription,
                  CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video else {
                writer.disable(.camera, reason: "Camera video format unavailable; screen recording continues.")
                return
            }
            let size = CMVideoFormatDescriptionGetDimensions(format)
            guard cameraPixels == [Int(size.width), Int(size.height)] else {
                writer.disable(.camera, reason: "Camera changed its negotiated size; screen recording continues.")
                return
            }
        }
        // Output timestamps use the session synchronizationClock, not the input
        // port's native device clock (AVCaptureSession.h documents this explicitly).
        guard let clock else {
            writer.disable(track, reason: "Capture device clock unavailable; screen recording continues.")
            return
        }
        do { writer.append(try CaptureClock.hostSample(sample, from: clock), track: track.rawValue) }
        catch { writer.disable(track, reason: "Capture device timestamps invalid; screen recording continues.") }
    }
}
