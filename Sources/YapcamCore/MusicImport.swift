import Foundation
@preconcurrency import AVFoundation

extension Project {
    /// Copy a local audio asset into the package and add its model in one undo
    /// step. Decoding, copying and validation occur outside the core state lock.
    @discardableResult public func importMusic(_ file: URL, startNs: Int64 = 0, endNs: Int64? = nil, gainDb: Double = -18, loop: Bool = true) async throws -> ChangeSet {
        guard file.isFileURL else { throw CoreError.status(1, "Music import requires a local file") }
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CoreError.status(1, "Music file has no audio track") }
        let range = try await track.load(.timeRange)
        let ns = CMTimeConvertScale(range.duration, timescale: 1_000_000_000, method: .roundHalfAwayFromZero)
        let fileStart = CMTimeConvertScale(range.start, timescale: 1_000_000_000, method: .roundHalfAwayFromZero)
        guard ns.isNumeric && ns.value > 0 && fileStart.isNumeric && fileStart.value >= 0 && fileStart.value <= Int64.max - ns.value else { throw CoreError.status(1, "Music duration is invalid") }
        let directory = packageURL.appendingPathComponent("assets")
        let root = packageURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw CoreError.status(1, "Music asset directory escapes package") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = file.pathExtension.isEmpty ? "audio" : file.pathExtension.lowercased()
        let relative = "assets/music-\(UUID().uuidString).\(suffix)"
        let staged = packageURL.appendingPathComponent(relative)
        try FileManager.default.copyItem(at: file, to: staged)
        do {
            let music = MusicTrack(startNs: startNs, endNs: endNs ?? durationNs, path: relative, fileStartNs: fileStart.value, fileDurationNs: fileStart.value + ns.value, gainDb: gainDb, loop: loop)
            return try apply(.batch([.addMedia(path: relative, asBackground: false), .addMusic(music)]))
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }
}
