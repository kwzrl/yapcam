@preconcurrency import AVFoundation
import Foundation

extension RecordingSession {
    public nonisolated static func interruptedPackages(in directory: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.filter { url in
            guard url.pathExtension == "yapcam", RecordingPackageLease.isAvailable(url),
                  let manifest = try? Recovery.readManifest(url) else { return false }
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

    static func recover(_ package: URL, inspectMedia: (URL, Bool) throws -> Int64 = { try inspect($0, video: $1) }) throws -> URL {
        let lease = try RecordingPackageLease(package: package)
        defer { withExtendedLifetime(lease) {} }
        var manifest = try readManifest(package)
        guard manifest.schemaVersion == 1 else { throw CaptureError.writerFailed("Unsupported recording schema \(manifest.schemaVersion)") }
        if manifest.status == "complete" { return package }
        guard manifest.status == "recording" || manifest.status == "interrupted" else {
            throw CaptureError.writerFailed("Unknown recording status")
        }
        var recovered: [SegmentMetadata] = []
        var sourceOffset: Int64 = 0
        let packageRoot = package.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for var segment in manifest.segments {
            guard segment.dir == String(format: "seg-%03d", segment.index), segment.index >= 0 else {
                throw CaptureError.writerFailed("Invalid segment directory")
            }
            let directory = package.appendingPathComponent("recording/\(segment.dir)")
            guard directory.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(packageRoot) else {
                throw CaptureError.writerFailed("Segment directory leaves the recording package")
            }
            let originURL = directory.appendingPathComponent("host-start.json")
            if originURL.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(packageRoot),
               let data = try? Data(contentsOf: originURL),
               let origin = try? JSONDecoder().decode(Int64.self, from: data), origin >= 0 {
                segment.hostStartNs = origin
                // Written before the offset sidecar, so screen zero is recoverable
                // even if the process dies between the two atomic writes.
                segment.trackStartNs["screen"] = 0
            }
            for sidecar in ["track-starts.json", "track-starts.json.prev"] {
                let url = directory.appendingPathComponent(sidecar)
                guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(packageRoot) else { continue }
                if let bytes = try? Data(contentsOf: url), let starts = try? JSONDecoder().decode([String: Int64].self, from: bytes) {
                    segment.trackStartNs.merge(starts.filter { $0.value >= 0 }) { existing, fallback in existing >= 0 ? existing : fallback }
                }
            }
            var files: [String: String] = [:]
            var starts: [String: Int64] = [:]
            var duration: Int64 = 0
            for (key, filename) in [("screen", "screen.mov"), ("camera", "camera.mov"), ("mic", "mic.m4a"), ("system_audio", "system.m4a")] {
                let url = directory.appendingPathComponent(filename)
                guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(packageRoot),
                      let start = segment.trackStartNs[key], start >= 0,
                      let mediaDuration = try? inspectMedia(url, key == "screen" || key == "camera"), mediaDuration > 0,
                      start <= Int64.max - mediaDuration else { continue }
                files[key] = "\(segment.dir)/\(filename)"
                starts[key] = start
                duration = max(duration, start + mediaDuration)
            }
            // An audio-only segment cannot be opened as a screen recording.
            guard files["screen"] != nil else { continue }
            segment.files = files; segment.trackStartNs = starts
            segment.index = recovered.count
            segment.srcStartNs = sourceOffset
            // A finalized segment's stop time is authoritative. Audio packets can
            // straddle it; extending the segment would shift every later segment.
            if segment.durationNs > 0 { duration = segment.durationNs }
            segment.durationNs = duration
            let eventURL = directory.appendingPathComponent("events.jsonl")
            guard eventURL.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(packageRoot) else {
                throw CaptureError.writerFailed("Input event log leaves the recording package")
            }
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
        var last: Int64 = 0
        let input: FileHandle?
        if FileManager.default.fileExists(atPath: url.path) { input = try FileHandle(forReadingFrom: url) }
        else { input = nil }
        defer { try? input?.close() }
        try PackageIO.writeStreaming(to: url) { output in
            var line = Data()
            var oversized = false
            func flush() throws {
                defer { line.removeAll(keepingCapacity: true); oversized = false }
                guard !oversized, let event = try? JSONDecoder().decode(CaptureEvent.self, from: line),
                      event.t >= last, event.t >= 0, event.t <= duration else { return }
                line.append(0x0a)
                try output.write(contentsOf: line)
                last = event.t
            }
            while let chunk = try input?.read(upToCount: 64 * 1024), !chunk.isEmpty {
                for byte in chunk {
                    if byte == 0x0a { try flush() }
                    else if !oversized {
                        if line.count < 1_048_576 { line.append(byte) }
                        else { oversized = true; line.removeAll(keepingCapacity: true) }
                    }
                }
            }
            if !line.isEmpty || oversized { try flush() }
        }
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
