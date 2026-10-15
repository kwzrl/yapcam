import AppKit
import Foundation

/// Local file clipboard export. Files outlive the pasteboard write and remain
/// available in history until the user removes them; no cloud or notifications permission.
@MainActor public enum ClipboardExport {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Yapcam/CopiedExports", isDirectory: true)
    }
    @discardableResult public static func run(project: any RenderProjectSource, settings: ExportSettings,
                                              directory: URL? = nil, pasteboard: NSPasteboard = .general,
                                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try await perform(settings: settings, directory: directory ?? defaultDirectory, render: { url in
            try await Exporter(project: project, settings: settings, destination: url).run(progress: progress)
        }, publish: { url in try copyFile(url, to: pasteboard) })
    }
    /// For a recent-export picker. Lists only this service's generated files.
    public static func previousExports(directory: URL? = nil, limit: Int = 20) throws -> [URL] {
        guard limit > 0 else { return [] }
        let directory = directory ?? defaultDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey,.contentModificationDateKey], options: [.skipsHiddenFiles])
        var rows: [(url: URL, date: Date)] = []
        for file in files where file.lastPathComponent.hasPrefix("YapcamCopy-") && ["mp4","gif","mov"].contains(file.pathExtension) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey,.contentModificationDateKey])
            if values.isRegularFile == true { rows.append((file,values.contentModificationDate ?? .distantPast)) }
        }
        return rows.sorted { $0.date == $1.date ? $0.url.lastPathComponent > $1.url.lastPathComponent : $0.date > $1.date }.prefix(limit).map(\.url)
    }
    public static func copyFile(_ url: URL, to pasteboard: NSPasteboard = .general) throws {
        guard url.isFileURL, (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw RenderError.write("Clipboard export requires a completed local file") }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else { throw RenderError.write("The rendered file could not be copied to the clipboard") }
    }
    static func perform(settings: ExportSettings, directory: URL,
                        render: @MainActor (URL) async throws -> URL, publish: @MainActor (URL) throws -> Void) async throws -> URL {
        try Task.checkCancellation()
        guard directory.isFileURL, settings.codec != .both else { throw RenderError.invalidSettings("Clipboard export requires a local directory and one codec") }
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let output = directory.appendingPathComponent("YapcamCopy-\(stamp)-\(UUID().uuidString).\(settings.format.rawValue)")
        do {
            let result = try await render(output)
            try Task.checkCancellation()
            guard result == output, (try output.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw RenderError.write("Export did not produce its expected local file") }
            try publish(output)
            return output
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
}
