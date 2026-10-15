import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor protocol CaptureSessionStream: AnyObject {
    func startCapture() async throws
    func stopCapture() async throws
    func updateContentFilter(_ filter: SCContentFilter) async throws
}

extension SCStream: CaptureSessionStream {}

@MainActor struct CaptureSessionPlan {
    let source: SourceMetadata
    let geometry: CaptureGeometry
    let makeStream: (SegmentWriter, [Int]) throws -> any CaptureSessionStream
}

/// Internal dependencies allow lifecycle/fault tests to exercise the real session
/// coordinator and package IO without requesting OS permissions or encoding media.
/// The public initializer always uses these live framework implementations.
@MainActor struct CaptureSessionServices {
    var permissionState: (Permission) -> PermissionState
    var availableBytes: (URL) throws -> Int64
    var prepare: (RecordingOptions) async throws -> CaptureSessionPlan
    var makeWriter: (URL, Int64, Int) -> SegmentWriter
    var startEvents: (InputEventRecorder) throws -> Void
    var automaticHealthChecks = true

    static var live: CaptureSessionServices {
        CaptureSessionServices(permissionState: CapturePermissions.state,
            availableBytes: PackageIO.availableBytes,
            prepare: { options in
                if case .device(let id) = options.target {
                    if case .applications = options.systemAudioSelection {
                        throw CaptureError.writerFailed("Application audio selection applies to Mac sources. Choose all audio or off for a USB device.")
                    }
                    guard options.maxFPS == 30 || options.maxFPS == 60 else {
                        throw CaptureError.writerFailed("Frame rate must be 30 or 60")
                    }
                    let device = try DeviceScreenDiscovery.require(id, devices: DeviceScreenDiscovery.load())
                    let geometry = try device.geometry()
                    let source = try device.source()
                    return CaptureSessionPlan(source: source, geometry: geometry) { writer, pixels in
                        DeviceScreenStream(id: id, audio: options.systemAudio, pixels: pixels, writer: writer)
                    }
                }
                let resolved = try await ResolvedCapture.resolve(options)
                return CaptureSessionPlan(source: resolved.source, geometry: resolved.geometry) { writer, pixels in
                    resolved.configuration.width = pixels[0]
                    resolved.configuration.height = pixels[1]
                    let stream = SCStream(filter: resolved.filter, configuration: resolved.configuration, delegate: writer)
                    try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
                    var audio: SCStream?
                    if let filter = resolved.audioFilter {
                        let config = SCStreamConfiguration()
                        config.width = 2; config.height = 2
                        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                        config.capturesAudio = true; config.excludesCurrentProcessAudio = true
                        config.sampleRate = 48_000; config.channelCount = 2
                        config.showsCursor = false; config.queueDepth = 3
                        let audioStream = SCStream(filter: filter, configuration: config, delegate: writer)
                        try audioStream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
                        audio = audioStream
                    }
                    return CaptureStreamGroup(video: stream, audio: audio)
                }
            }, makeWriter: { SegmentWriter(directory: $0, hostStartNs: $1, maxFPS: $2) },
            startEvents: { try $0.start() })
    }
}
