@preconcurrency import AVFoundation
import Foundation

extension RecordingSession {
    public nonisolated static func interruptedPackages(in directory: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.filter { url in
            guard url.pathExtension == "yapcam", let manifest = try? Recovery.readManifest(url) else { return false }
            return manifest.status == "recording" || manifest.status == "interrupted"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Synchronous contract for opening an interrupted package. Call from a worker
    /// when possible: inspecting fragmented media can take time on a slow disk.
    public nonisolated static func recover(_ package: URL) throws -> URL {
        try Recovery.recover(package)
    }
}

enum Recovery {
    static func readManifest(_ package: URL) throws -> SessionManifest {
        let url = package.appendingPathComponent("recording/session.json")
        do { return try PackageIO.readManifest(at: url) }
        catch { return try PackageIO.readManifest(at: url.appendingPathExtension("prev")) }
    }

    static func recover(_ package: URL) throws -> URL {
        var manifest = try readManifest(package)
        guard manifest.schemaVersion == 1 else { throw CaptureError.writerFailed("Unsupported recording schema \(manifest.schemaVersion)") }
        if manifest.status == "complete" { return package }
        guard manifest.status == "recording" || manifest.status == "interrupted" else {
            throw CaptureError.writerFailed("Unknown recording status")
        }
        var recovered: [SegmentMetadata] = []
        var sourceOffset: Int64 = 0
        for var segment in manifest.segments {
            guard segment.dir == String(format: "seg-%03d", segment.index), segment.index >= 0 else {
                throw CaptureError.writerFailed("Invalid segment directory")
            }
            let directory = package.appendingPathComponent("recording/\(segment.dir)")
            let sidecar = directory.appendingPathComponent("track-starts.json")
            if let bytes = try? Data(contentsOf: sidecar), let starts = try? JSONDecoder().decode([String: Int64].self, from: bytes) {
                segment.trackStartNs.merge(starts) { existing, _ in existing }
            }
            var files: [String: String] = [:]
            var starts: [String: Int64] = [:]
            var duration: Int64 = 0
            for (key, filename) in [("screen", "screen.mov"), ("camera", "camera.mov"), ("mic", "mic.m4a"), ("system_audio", "system.m4a")] {
                let url = directory.appendingPathComponent(filename)
                guard let start = segment.trackStartNs[key], start >= 0,
                      let mediaDuration = try? inspect(url, video: key == "screen" || key == "camera"), mediaDuration > 0,
                      start <= Int64.max - mediaDuration else { continue }
                files[key] = "\(segment.dir)/\(filename)"
                starts[key] = start
                duration = max(duration, start + mediaDuration)
            }
            // An audio-only segment cannot be opened as a screen recording.
            guard files["screen"] != nil else { continue }
            segment.files = files; segment.trackStartNs = starts
            segment.srcStartNs = sourceOffset
            duration = max(duration, segment.durationNs)
            segment.durationNs = duration
            let eventURL = directory.appendingPathComponent("events.jsonl")
            try repairEvents(at: eventURL, duration: duration)
            segment.files["events"] = "\(segment.dir)/events.jsonl"
            let cursors = directory.appendingPathComponent("cursors.json")
            if !FileManager.default.fileExists(atPath: cursors.path) { try PackageIO.write([String: CursorMetadata](), to: cursors) }
            segment.files["cursors"] = "\(segment.dir)/cursors.json"
            recovered.append(segment)
            guard sourceOffset <= Int64.max - duration else { throw CaptureError.writerFailed("Recording duration overflow") }
            sourceOffset += duration
        }
        guard !recovered.isEmpty else { throw CaptureError.writerFailed("No readable screen fragments were found; the original files have been preserved") }
        manifest.segments = recovered
        manifest.status = "complete"
        try PackageIO.write(manifest, to: package.appendingPathComponent("recording/session.json"))
        return package
    }

    static func repairEvents(at url: URL, duration: Int64) throws {
        let data = (try? Data(contentsOf: url)) ?? Data()
        var repaired = Data()
        var last: Int64 = 0
        for line in data.split(separator: 0x0a) {
            guard let event = try? JSONDecoder().decode(CaptureEvent.self, from: Data(line)),
                  event.t >= last, event.t >= 0, event.t <= duration else { continue }
            repaired.append(contentsOf: line); repaired.append(0x0a); last = event.t
        }
        try repaired.write(to: url, options: .atomic)
    }

    private final class Inspection: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Int64, Error> = .failure(CaptureError.writerFailed("Media inspection did not complete"))
    }
    static func inspect(_ url: URL, video: Bool) throws -> Int64 {
        let inspection = Inspection()
        Task.detached {
            defer { inspection.semaphore.signal() }
            do {
                let asset = AVURLAsset(url: url)
                let tracks = try await asset.loadTracks(withMediaType: video ? .video : .audio)
                guard let track = tracks.first else { throw CaptureError.writerFailed("Missing media track") }
                let range = try await track.load(.timeRange)
                let duration = CaptureClock.nanoseconds(CMTimeRangeGetEnd(range))
                guard duration > 0 else { throw CaptureError.writerFailed("Empty media track") }
                inspection.result = .success(duration)
            } catch { inspection.result = .failure(error) }
        }
        inspection.semaphore.wait()
        return try inspection.result.get()
    }
}
