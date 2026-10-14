import AVFoundation
import Foundation

/// Nanosecond conversion is integer-only; host time and sample PTS share this epoch.
enum CaptureClock {
    static func nanoseconds(_ time: CMTime) -> Int64 {
        guard time.isNumeric else { return 0 }
        return CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
    }
    static var now: Int64 { nanoseconds(CMClockGetTime(CMClockGetHostTimeClock())) }
}

struct SessionManifest: Codable, Sendable {
    var schemaVersion = 1
    var appVersion = "0.1.0"
    var createdAt = Date().ISO8601Format()
    var status = "recording"
    var source: SourceMetadata
    var tracks: TrackMetadata
    var segments: [SegmentMetadata] = []
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", appVersion = "app_version", createdAt = "created_at", status, source, tracks, segments
    }
}

struct SourceMetadata: Codable, Sendable {
    var kind: String
    var displayID: UInt32?
    var displayName: String?
    var contentRectPoints: [Double]
    var scale: Double
    var windowTitle: String?
    var appBundleID: String?

    enum CodingKeys: String, CodingKey {
        case kind, displayID = "display_id", displayName = "display_name", contentRectPoints = "content_rect_points"
        case scale, windowTitle = "window_title", appBundleID = "app_bundle_id"
    }
}
struct TrackMetadata: Codable, Sendable {
    var screen: ScreenMetadata
    var camera: CameraMetadata?
    var mic: AudioMetadata?
    var systemAudio: AudioMetadata?
    enum CodingKeys: String, CodingKey { case screen, camera, mic, systemAudio = "system_audio" }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(screen, forKey: .screen)
        try container.encode(camera, forKey: .camera)
        try container.encode(mic, forKey: .mic)
        try container.encode(systemAudio, forKey: .systemAudio)
    }
}
struct ScreenMetadata: Codable, Sendable {
    var pixelSize: [Int]
    var maxFPS: Int
    var codec = "hevc"
    var cursorInVideo = false
    enum CodingKeys: String, CodingKey {
        case pixelSize = "pixel_size", maxFPS = "max_fps", codec, cursorInVideo = "cursor_in_video"
    }
}
struct CameraMetadata: Codable, Sendable {
    var deviceName: String
    var pixelSize: [Int]
    var fps: Int
    var mirrored = false
    enum CodingKeys: String, CodingKey { case deviceName = "device_name", pixelSize = "pixel_size", fps, mirrored }
}
struct AudioMetadata: Codable, Sendable {
    var deviceName: String?
    var sampleRate: Int
    var channels: Int
    enum CodingKeys: String, CodingKey { case deviceName = "device_name", sampleRate = "sample_rate", channels }
}
struct SegmentMetadata: Codable, Sendable {
    var index: Int
    var dir: String
    var srcStartNs: Int64
    var durationNs: Int64 = 0
    var hostStartNs: Int64
    var files: [String: String] = [:]
    var trackStartNs: [String: Int64] = [:]
    enum CodingKeys: String, CodingKey {
        case index, dir, srcStartNs = "src_start_ns", durationNs = "duration_ns", hostStartNs = "host_start_ns", files, trackStartNs = "track_start_ns"
    }
}

enum SegmentTimeline {
    static func nextSourceStart(after segments: [SegmentMetadata]) throws -> Int64 {
        guard let last = segments.last else { return 0 }
        guard last.srcStartNs >= 0, last.durationNs >= 0,
              last.srcStartNs <= Int64.max - last.durationNs else {
            throw CaptureError.writerFailed("Invalid segment time range")
        }
        return last.srcStartNs + last.durationNs
    }
}

enum PackageIO {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try writeBytes(encoder.encode(value), to: url)
    }

    static func writeBytes(_ bytes: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try bytes.write(to: temporary)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            if FileManager.default.fileExists(atPath: url.path) {
                let previous = url.appendingPathExtension("prev")
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.copyItem(at: url, to: previous)
            }
            // POSIX rename replaces atomically on the same volume.
            guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            let directoryFD = open(url.deletingLastPathComponent().path, O_RDONLY)
            if directoryFD >= 0 { _ = fsync(directoryFD); _ = close(directoryFD) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func readManifest(at url: URL) throws -> SessionManifest {
        // Use explicit keys on all persisted types so decoder and encoder are symmetric.
        try JSONDecoder().decode(SessionManifest.self, from: Data(contentsOf: url))
    }

    static func availableBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage { return available }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let available = attributes[.systemFreeSize] as? NSNumber else {
            throw CaptureError.writerFailed("Cannot determine available disk space")
        }
        return available.int64Value
    }
    static func checkSpace(at url: URL) throws {
        try requireSpace(availableBytes(at: url))
    }
    static func requireSpace(_ available: Int64) throws {
        if available < 1_000_000_000 { throw CaptureError.diskFull(availableBytes: available) }
    }
}
