import AVFoundation
import ScreenCaptureKit

// Setup probe (kept until capture's self-test exists, then `--capture-selftest` takes over).
// `--probe-record <seconds>` records the main display to ~/Movies/Yapcam/Probes and quits;
// results go to ~/Library/Logs/Yapcam.
enum Probe {
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Yapcam/probe.log")

    static func log(_ line: String) {
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry = "\(Date().ISO8601Format()) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: logURL)
        }
    }

    static func report() async {
        log("bundle \(Bundle.main.bundleIdentifier ?? "nil")")
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        log("screen access \(CGPreflightScreenCaptureAccess())")
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        let cam = await AVCaptureDevice.requestAccess(for: .video)
        log("mic access \(mic) camera access \(cam)")
        let video = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
        let audio = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        log("cameras \(video.map(\.localizedName)) microphones \(audio.map(\.localizedName))")
    }

    static func record(seconds: Double) async throws -> URL {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw ProbeError.noDisplay }
        let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let scale = Int(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width) * scale
        config.height = Int(filter.contentRect.height) * scale
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.capturesAudio = true

        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Yapcam/Probes")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "probe-\(Int(Date().timeIntervalSince1970)).mov")

        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = url
        outputConfig.outputFileType = .mov
        outputConfig.videoCodecType = .hevc

        let finished = RecordingFinished()
        let output = SCRecordingOutput(configuration: outputConfig, delegate: finished)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addRecordingOutput(output)
        log("recording \(config.width)x\(config.height) display \(display.displayID) excluded apps \(own.count)")
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(seconds))
        try await stream.stopCapture()
        try await finished.wait()
        return url
    }
}

enum ProbeError: Error { case noDisplay }

final class RecordingFinished: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private let lock = NSLock()

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { finish(.success(())) }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { finish(.failure(error)) }

    private func finish(_ value: Result<Void, Error>) {
        lock.lock()
        if let continuation { self.continuation = nil; lock.unlock(); continuation.resume(with: value); return }
        result = value
        lock.unlock()
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result { lock.unlock(); c.resume(with: result); return }
            continuation = c
            lock.unlock()
        }
    }
}
