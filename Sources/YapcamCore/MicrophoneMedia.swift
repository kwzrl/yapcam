import Foundation
@preconcurrency import AVFoundation

public struct CoreMicrophoneMedia: Decodable, Sendable, Equatable {
    public var original: MicrophoneMediaIdentity
    public var originalPath: String
    public var originalMediaIndex: UInt32
    public var path: String
    public var mediaIndex: UInt32
    public var enhanced: Bool
    public var stale: Bool
}

extension Project {
    public func microphoneMedia() throws -> [CoreMicrophoneMedia] {
        try query("{\"q\":\"microphone_media\"}", as: [CoreMicrophoneMedia].self)
    }

    /// Capture this identity BEFORE starting isolation; pass it back on success.
    /// A later relink/edit cannot silently attach the output to a different input.
    public func microphoneIdentity(path: String) throws -> MicrophoneMediaIdentity {
        guard session.segments.contains(where: { $0.files["mic"].map { "recording/" + $0 } == path }),
              let original = try query("{\"q\":\"media\"}", as: [MicrophoneMediaIdentity].self).first(where: { $0.path == path }) else {
            throw CoreError.status(1, "Path is not a registered microphone")
        }
        return original
    }

    /// Import only after the processor succeeds. No Capture/Render dependency or
    /// processing occurs here. Original media, track offsets and clocks stay intact.
    @discardableResult public func importEnhancedMicrophone(_ file: URL, forOriginal expected: MicrophoneMediaIdentity) async throws -> ChangeSet {
        try Task.checkCancellation()
        guard file.isFileURL else { throw CoreError.status(1, "Enhanced microphone must be a local file") }
        let snapshot = try snapshot()
        let original = try snapshot.microphoneIdentity(path: expected.path)
        guard original == expected else { throw CoreError.status(1, "Microphone changed during processing") }
        let media = try snapshot.query("{\"q\":\"media\"}", as: [MicrophoneMediaIdentity].self)
        guard let index = media.firstIndex(of: original) else { throw CoreError.status(1, "Microphone media is unavailable") }
        let source = try snapshot.mediaURL(atIndex: UInt32(index))
        guard try MicrophoneMediaIdentity.read(source, path: expected.path) == expected else { throw CoreError.missingMedia([expected.path]) }
        let sourceInfo = try await SpeechFileInfo.source(source)
        try Task.checkCancellation()
        let directory = packageURL.appendingPathComponent("assets", isDirectory: true)
        let root = packageURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw CoreError.status(1, "Microphone asset directory escapes package") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let relative = "assets/mic-\(UUID().uuidString).caf"
        let destination = packageURL.appendingPathComponent(relative)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: destination) } }
        try FileManager.default.copyItem(at: file, to: destination)
        // Validate the staged bytes, rather than assuming an extension/report is PCM.
        let pcm = try AVAudioFile(forReading: destination)
        let info = try SpeechFileInfo.pcm(pcm)
        guard pcm.fileFormat.commonFormat == .pcmFormatFloat32, info.sampleRate == 48_000,
              info.channels == sourceInfo.channels, abs(info.durationNs - sourceInfo.durationNs) <= 20_834 else {
            throw CoreError.status(1, "Enhanced microphone must preserve channels and duration as 48k Float32 PCM")
        }
        try Task.checkCancellation()
        let changes = try apply(.selectMicrophone(original: expected, enhancedPath: relative))
        published = true
        return changes
    }

    @discardableResult public func useOriginalMicrophone(path: String) throws -> ChangeSet {
        try apply(.selectMicrophone(original: microphoneIdentity(path: path), enhancedPath: nil))
    }
}
