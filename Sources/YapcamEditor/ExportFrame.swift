import AppKit
import UniformTypeIdentifiers
import YapcamCore

/// "Export current frame as image…": renders the frame under the playhead with the shared compositor and writes PNG or JPEG.
public enum FrameImageFormat {
    /// The file type for a destination URL: .jpg/.jpeg gives JPEG, anything else PNG.
    public static func type(for url: URL) -> UTType {
        ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
    }
    /// Re-encodes PNG data for the destination; PNG data passes through unchanged.
    public static func encode(png: Data, for url: URL) throws -> Data {
        guard type(for: url) == .jpeg else { return png }
        guard let rep = NSBitmapImageRep(data: png),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { throw FrameExportError.encoding }
        return jpeg
    }
    /// "Frame 00-12.40.png"-style default name next to the project title.
    public static func defaultName(title: String, ns: Int64) -> String {
        let t = max(0, Double(ns) / 1e9)
        let clean = title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        return String(format: "%@ – %d.%02d.png", clean.isEmpty ? "Frame" : clean, Int(t) / 60, Int(t) % 60)
            .replacingOccurrences(of: ":", with: "-")
    }
}

public enum FrameExportError: LocalizedError {
    case encoding, unavailable
    public var errorDescription: String? {
        switch self {
        case .encoding: "The image could not be encoded."
        case .unavailable: "This project can't render a still image."
        }
    }
}

extension EditorModel {
    /// True when the project can render a still (not for the fake backends used in unit tests).
    public var canExportFrame: Bool { project is CoreEditingProject }

    /// Renders the playhead frame and returns PNG data.
    func currentFramePNG() throws -> Data {
        guard let core = project as? CoreEditingProject else { throw FrameExportError.unavailable }
        return try FrameSnapshot.png(source: ProjectRenderSource(core.project), atNs: playheadNs)
    }

    /// Asks where to save, then writes the frame. Errors surface in `lastError`.
    public func exportCurrentFrame() {
        do {
            let png = try currentFramePNG()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png, .jpeg]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = FrameImageFormat.defaultName(title: exportTitle, ns: playheadNs)
            panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try FrameImageFormat.encode(png: png, for: url).write(to: url, options: .atomic)
        } catch { lastError = "Couldn't export the frame: \(error.localizedDescription)" }
    }
}
