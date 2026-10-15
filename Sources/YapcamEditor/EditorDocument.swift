import SwiftUI
import AppKit
import YapcamCore
import YapcamRender
import Metal
import ImageIO
import UniformTypeIdentifiers

/// One open `.yapcam` package: core project + preview player + editor/export models.
@MainActor public final class EditorDocument: ObservableObject {
    public let project: Project
    public let player: PreviewPlayer
    public let model: EditorModel
    public let export: ExportModel
    public let title: String
    let adapter: PreviewPlayerAdapter

    /// Opens `package/project.json`, or creates a project when only a recording exists.
    /// A leftover autosave journal is applied by core; pass `restoreUnsavedChanges: false`
    /// to discard it first (see `EditorWindows` for the prompt).
    public init(package: URL, restoreUnsavedChanges: Bool = true) throws {
        if !restoreUnsavedChanges { Self.discardJournal(package) }
        let restored = restoreUnsavedChanges && Self.hasUnsavedJournal(package)
        let fm = FileManager.default
        // A journal alone is a recoverable project: it must win over `create`, which would start a fresh timeline.
        let hasProject = ["project.json", "project.json.prev", "autosave/project.json"]
            .contains { fm.fileExists(atPath: package.appendingPathComponent($0).path) }
        project = hasProject ? try Project.open(package: package) : try Project.create(package: package)
        let source = ProjectRenderSource(project)
        player = try PreviewPlayer(project: source)
        adapter = PreviewPlayerAdapter(player: player)
        model = EditorModel(project: CoreEditingProject(project: project), player: adapter)
        export = ExportModel(engine: RenderExportEngine(source: source))
        title = package.deletingPathExtension().lastPathComponent
        if !hasProject { try? project.save() }
        if restored { model.markRecoveredUnsaved() }   // journal-only state must be written on close
        model.fitTimeline(width: 900)
        model.copyFrameHandler = { [weak self] in self?.copyCurrentFrame() }
        let transcriptURL = package.appendingPathComponent("recording/transcript.json")
        model.captionSource = {
            // An existing transcript is used as is; otherwise the app-provided on-device transcriber runs.
            if let data = try? Data(contentsOf: transcriptURL) { return data }
            guard let transcriber = EditorWindows.transcriber else { throw EditorError.transcriptionUnavailable }
            return try await transcriber(package)
        }
    }

    /// Renders the current timeline frame with the shared compositor and puts a PNG on the clipboard.
    public func copyCurrentFrame() {
        do {
            let png = try FrameSnapshot.png(source: ProjectRenderSource(project), atNs: model.playheadNs)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
        } catch { model.lastError = "Couldn't copy the frame: \(error.localizedDescription)" }
    }

    /// True when an autosave journal exists that is newer than the saved project.
    public static func hasUnsavedJournal(_ package: URL) -> Bool {
        let fm = FileManager.default
        let journal = package.appendingPathComponent("autosave/project.json")
        guard let j = try? fm.attributesOfItem(atPath: journal.path)[.modificationDate] as? Date else { return false }
        let saved = try? fm.attributesOfItem(atPath: package.appendingPathComponent("project.json").path)[.modificationDate] as? Date
        return saved.map { j > $0 } ?? true
    }

    static func discardJournal(_ package: URL) {
        try? FileManager.default.removeItem(at: package.appendingPathComponent("autosave/project.json"))
    }
}

public struct EditorView: View {
    @ObservedObject private var document: EditorDocument
    public init(document: EditorDocument) { self.document = document }
    public var body: some View {
        EditorContent(model: document.model, export: document.export, title: document.title) {
            PreviewView(player: document.player)
        }
    }
}

enum FrameSnapshot {
    static func png(source: ProjectRenderSource, atNs ns: Int64) throws -> Data {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError.metal("Metal is unavailable")
        }
        let frame = try source.frame(atNs: min(ns, max(0, source.durationNs - 1)))
        let w = Int(frame.canvas_w), h = Int(frame.canvas_h)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: desc), let cb = queue.makeCommandBuffer() else {
            throw RenderError.metal("Cannot allocate a frame texture")
        }
        try FrameCompositor(device: device, project: source).encode(frame, to: texture, in: cb)
        cb.commit(); cb.waitUntilCompleted()
        guard cb.status == .completed else { throw RenderError.metal(cb.error?.localizedDescription ?? "GPU failed") }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw RenderError.write("Cannot create the frame image")
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.write("Cannot encode PNG")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.write("Cannot encode PNG") }
        return data as Data
    }
}

public enum EditorError: LocalizedError {
    case transcriptionUnavailable
    public var errorDescription: String? { "Speech transcription isn't available in this build." }
}
