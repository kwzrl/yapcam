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
    lazy var agentRunner = AgentPromptRunner(model: model, package: project.packageURL)
    let adapter: PreviewPlayerAdapter

    /// Opens `package/project.json`, or creates a project when only a recording exists.
    /// A leftover autosave journal is applied by core; pass `restoreUnsavedChanges: false`
    /// to discard it first (see `EditorWindows` for the prompt).
    public init(package: URL, restoreUnsavedChanges: Bool = true, presets: PresetStore = EditorPresets.currentStore) throws {
        if !restoreUnsavedChanges { Self.discardJournal(package) }
        let restored = restoreUnsavedChanges && Self.hasUnsavedJournal(package)
        let fm = FileManager.default
        // A journal alone is a recoverable project: it must win over `create`, which would start a fresh timeline.
        let hasProject = ["project.json", "project.json.prev", "autosave/project.json"]
            .contains { fm.fileExists(atPath: package.appendingPathComponent($0).path) }
        project = hasProject ? try Project.open(package: package) : try Project.create(package: package)
        // New projects start from the preset marked "use as default for new projects", if there is one.
        if !hasProject { EditorPresets.applyDefaultPreset(to: project, from: presets) }
        let source = ProjectRenderSource(project)
        player = try PreviewPlayer(project: source)
        adapter = PreviewPlayerAdapter(player: player)
        model = EditorModel(project: CoreEditingProject(project: project), player: adapter)
        export = ExportModel(engine: RenderExportEngine(source: source))
        export.speechProvider = { [weak model] in model?.speechEnhancement }
        title = package.deletingPathExtension().lastPathComponent
        if !hasProject { try? project.save() }
        if restored { model.markRecoveredUnsaved() }   // journal-only state must be written on close
        model.exportModel = export; model.exportTitle = title
        export.remember(in: .dialog, defaults: presets.defaults)
        model.presetStore = presets; model.defaults = presets.defaults
        model.loadStoredPreviewOptions()
        model.loadLaneVisibility()
        model.favoriteWallpapers = Set(presets.defaults.stringArray(forKey: "editor.favoriteWallpapers") ?? [])
        model.smoothWaveform = presets.defaults.bool(forKey: "editor.smoothWaveform")
        model.showWaveform = presets.defaults.object(forKey: "editor.showWaveform") as? Bool ?? true
        struct Library: Decodable { struct Item: Decodable { var id: String }; var sets: [Item] }
        model.cursorSetIDs = ((try? project.query("{\"q\":\"cursor_library\"}", as: Library.self))?.sets ?? []).map(\.id)
        model.fitTimeline(width: 900)
        model.agentConnectCommand = { AgentConnection.shared.claudeCommand }
        model.agentHooks.undoDepth = { [weak project] in (try? project?.historyState().undoSteps) ?? 0 }
        model.agentPromptHandler = { [weak self] prompt in self?.agentRunner.send(prompt) }
        model.copyFrameHandler = { [weak self] in self?.copyCurrentFrame() }
        model.exportFrameHandler = { [weak self] in self?.exportCurrentFrame() }
        let transcriptURL = package.appendingPathComponent("recording/transcript.json")
        model.captionSourceWithOptions = { options, force in
            // An existing transcript is reused unless the user asked to regenerate it.
            if !force, let data = try? Data(contentsOf: transcriptURL) { return data }
            if let t = EditorWindows.transcriberWithOptions { return try await t(package, options) }
            guard let t = EditorWindows.transcriber else { throw EditorError.transcriptionUnavailable }
            return try await t(package)
        }
        model.captionSource = {
            // An existing transcript is used as is; otherwise the app-provided on-device transcriber runs.
            if let data = try? Data(contentsOf: transcriptURL) { return data }
            guard let transcriber = EditorWindows.transcriber else { throw EditorError.transcriptionUnavailable }
            return try await transcriber(package)
        }
    }

    public func handleMCP(_ request: Data) throws -> Data {
        let before = project.revision
        let result = try project.mcp(request)
        if project.revision != before {
            (model.project as? CoreEditingProject)?.refresh()
            model.noteExternalEdit()
            model.selection = .none
        }
        if let req = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
           let params = req["params"] as? [String: Any], params["name"] as? String == "save",
           let response = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
           let body = response["result"] as? [String: Any], body["isError"] as? Bool == false { model.saveNow() }
        return result
    }

    /// Applies a saved preset (.yapcampreset) to this project as an edit: undoable, marks the project dirty, redraws the preview.
    public func applyPreset(from url: URL) { model.applyPreset(at: url) }

    /// Renders the current timeline frame with the shared compositor and puts a PNG on the clipboard.
    public func copyCurrentFrame() {
        do {
            let png = try FrameSnapshot.png(source: ProjectRenderSource(project), atNs: model.playheadNs)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
        } catch { model.lastError = "Couldn't copy the frame: \(error.localizedDescription)" }
    }

    /// Save panel for the current timeline frame as a PNG, named "<project> <timecode>.png" (S-EDT-47).
    public func exportCurrentFrame() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Self.frameFileName(title: title, atNs: model.playheadNs)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FrameSnapshot.png(source: ProjectRenderSource(project), atNs: model.playheadNs).write(to: url, options: .atomic)
        } catch { model.lastError = "Couldn't save the frame: \(error.localizedDescription)" }
    }
    static func frameFileName(title: String, atNs ns: Int64) -> String {
        let code = formatTimecode(ns, showFraction: false).replacingOccurrences(of: ":", with: "-")
        return "\(title) \(code).png"
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
        EditorContent(model: document.model, export: document.export, title: document.title, packageURL: document.project.packageURL) {
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
