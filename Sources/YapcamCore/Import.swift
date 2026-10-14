import Foundation
import Darwin
@preconcurrency import AVFoundation

extension Project {
    /// Import a local movie as a single shared screen/audio segment. The original
    /// movie remains untouched; the new package owns a copy. Rotated movies are
    /// normalized before import so captured geometry also matches decoded pixels.
    public static func importVideo(_ video: URL, package: URL) async throws -> Project {
        guard video.isFileURL && package.isFileURL else { throw CoreError.status(1, "Import requires local file URLs") }
        guard !FileManager.default.fileExists(atPath: package.path) else { throw CoreError.status(1, "Import destination already exists") }
        let normalized = try await normalizedMovie(video)
        defer { if let normalized { try? FileManager.default.removeItem(at: normalized) } }
        let source = normalized ?? video
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CoreError.status(1, "Movie has no video track") }
        let duration = try await asset.load(.duration)
        let trackRange = try await track.load(.timeRange)
        let size = try await track.load(.naturalSize)
        let fps = try await track.load(.nominalFrameRate)
        let ns = CMTimeConvertScale(duration, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
        guard duration.isNumeric && ns > 0 && size.width.isFinite && size.height.isFinite && (1...16384).contains(size.width) && (1...16384).contains(size.height) && fps.isFinite && (0...16384).contains(fps) else { throw CoreError.status(1, "Movie duration or dimensions are invalid") }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let audioRange = try await audio?.load(.timeRange)
        let now = ISO8601DateFormatter().string(from: Date())
        let file = "seg-000/screen.\(source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased())"
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
        guard mkdir(package.path, 0o700) == 0 else { throw CoreError.status(4, "Cannot create import destination: \(String(cString: strerror(errno)))") }
        do {
            let recording = package.appendingPathComponent("recording")
            try FileManager.default.createDirectory(at: recording.appendingPathComponent("seg-000"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: recording.appendingPathComponent(file))
            try JSONSerialization.data(withJSONObject: session, options: [.prettyPrinted, .sortedKeys]).write(to: recording.appendingPathComponent("session.json"), options: .atomic)
            let project = try Project.create(package: package)
            try project.save()
            return project
        } catch {
            try? FileManager.default.removeItem(at: package)
            throw error
        }
    }
    private static func normalizedMovie(_ url: URL) async throws -> URL? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CoreError.status(1, "Movie has no video track") }
        let transform = try await track.load(.preferredTransform)
        guard !transform.isIdentity else { return nil }
        let size = try await track.load(.naturalSize)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        let duration = try await asset.load(.duration)
        let fps = try await track.load(.nominalFrameRate)
        guard duration.isNumeric && duration.value > 0, fps.isFinite && (0...16384).contains(fps),
              bounds.width.isFinite && bounds.height.isFinite && (1...16384).contains(abs(bounds.width)) && (1...16384).contains(abs(bounds.height)) else { throw CoreError.status(1, "Invalid movie orientation or timing") }
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: abs(bounds.width), height: abs(bounds.height))
        composition.frameDuration = CMTime(value: 1, timescale: Int32(max(1, fps.rounded())))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)), at: .zero)
        instruction.layerInstructions = [layer]; composition.instructions = [instruction]
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { throw CoreError.status(6, "Movie orientation normalization unavailable") }
        exporter.videoComposition = composition
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-normalize-\(UUID().uuidString).mov")
        do { try await exporter.export(to: temporary, as: .mov); return temporary }
        catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }
}
