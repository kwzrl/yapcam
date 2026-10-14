import Foundation
@preconcurrency import AVFoundation

extension Project {
    /// Import a local movie as a single shared screen/audio segment. The original
    /// movie remains untouched; the new package owns a copy. Readers must honor the
    /// screen track's preferredTransform, as they do for other AVFoundation media.
    public static func importVideo(_ video: URL, package: URL) async throws -> Project {
        guard video.isFileURL && package.isFileURL else { throw CoreError.status(1, "Import requires local file URLs") }
        guard !FileManager.default.fileExists(atPath: package.path) else { throw CoreError.status(1, "Import destination already exists") }
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CoreError.status(1, "Movie has no video track") }
        let duration = try await asset.load(.duration)
        let trackRange = try await track.load(.timeRange)
        let size = try await track.load(.naturalSize)
        let fps = try await track.load(.nominalFrameRate)
        let ns = CMTimeConvertScale(duration, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
        guard duration.isNumeric && ns > 0 && size.width > 0 && size.height > 0 else { throw CoreError.status(1, "Movie duration or dimensions are invalid") }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let audioRange = try await audio?.load(.timeRange)
        let now = ISO8601DateFormatter().string(from: Date())
        let file = "seg-000/screen.\(video.pathExtension.isEmpty ? "mov" : video.pathExtension.lowercased())"
        var files = ["screen": file]
        let videoStart = max(0, CMTimeConvertScale(trackRange.start, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value)
        var starts: [String: Int64] = ["screen": videoStart]
        var systemAudio: Any = NSNull()
        if let audioRange {
            files["system_audio"] = file
            starts["system_audio"] = max(0, CMTimeConvertScale(audioRange.start, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value)
            let formats = try await audio?.load(.formatDescriptions)
            let format = formats?.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            systemAudio = ["sample_rate": Int(format?.mSampleRate ?? 48000), "channels": Int(format?.mChannelsPerFrame ?? 2)]
        }
        let session: [String: Any] = [
            "schema_version": 1, "app_version": "0.1.0", "created_at": now, "status": "complete",
            "source": ["kind": "display", "display_id": 0, "display_name": video.deletingPathExtension().lastPathComponent,
                       "content_rect_points": [0, 0, size.width, size.height], "scale": 1,
                       "window_title": NSNull(), "app_bundle_id": NSNull()],
            "tracks": ["screen": ["pixel_size": [Int(size.width), Int(size.height)], "max_fps": max(1, Int(fps.rounded())),
                                   "codec": "imported", "cursor_in_video": true],
                       "camera": NSNull(), "mic": NSNull(), "system_audio": systemAudio],
            "segments": [["index": 0, "dir": "seg-000", "src_start_ns": 0, "duration_ns": ns,
                          "host_start_ns": 0, "files": files, "track_start_ns": starts]],
        ]
        do {
            let recording = package.appendingPathComponent("recording")
            try FileManager.default.createDirectory(at: recording.appendingPathComponent("seg-000"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: video, to: recording.appendingPathComponent(file))
            try JSONSerialization.data(withJSONObject: session, options: [.prettyPrinted, .sortedKeys]).write(to: recording.appendingPathComponent("session.json"), options: .atomic)
            let project = try Project.create(package: package)
            try project.save()
            return project
        } catch {
            try? FileManager.default.removeItem(at: package)
            throw error
        }
    }
    public func exportPreset(to url: URL) throws {
        let preset = try query("{\"q\":\"preset\"}", as: [String: JSONValue].self)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preset).write(to: url, options: .atomic)
    }
    @discardableResult public func importPreset(from url: URL) throws -> ChangeSet {
        let data = try Data(contentsOf: url)
        let preset = try JSONDecoder().decode([String: JSONValue].self, from: data)
        return try apply(.applyPreset(preset))
    }
}
