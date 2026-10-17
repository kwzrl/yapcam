import Foundation
import YapcamRender

/// Writes to a fresh sibling temp file and replaces the destination only after `produce`
/// succeeded (the exporter verifies its own output). Cancel or failure leaves an existing
/// destination untouched and removes the temp file.
enum AtomicExport {
    static func run(to destination: URL, produce: (URL) async throws -> URL) async throws -> URL {
        let fm = FileManager.default
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".yapcam-replace-\(UUID().uuidString).\(destination.pathExtension)")
        defer { try? fm.removeItem(at: temp) }
        let written = try await produce(temp)
        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: written)
        } else {
            try fm.moveItem(at: written, to: destination)
        }
        return destination
    }
}

extension AtomicExport {
    /// The H.264 + HEVC pair: both files are rendered into a private temporary folder; only when the render succeeded do they
    /// replace the destination pair (the primary and its "-h265" sibling). A failure or cancel leaves existing files alone.
    static func runPair(to destination: URL, settings: ExportSettings, produce: (URL) async throws -> URL) async throws -> URL {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent().appendingPathComponent(".yapcam-pair-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let temp = folder.appendingPathComponent(destination.lastPathComponent)
        _ = try await produce(temp)
        try Task.checkCancellation()
        let from = settings.destinations(for: temp), to = settings.destinations(for: destination)
        for (src, dst) in zip(from, to) {
            guard fm.fileExists(atPath: src.path) else { throw RenderError.write("The paired export did not produce \(src.lastPathComponent)") }
            if fm.fileExists(atPath: dst.path) { _ = try fm.replaceItemAt(dst, withItemAt: src) } else { try fm.moveItem(at: src, to: dst) }
        }
        return destination
    }
}
