import Foundation

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
