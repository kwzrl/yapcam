import SwiftUI
import AppKit
import YapcamCore
import YapcamRender

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
        let fm = FileManager.default
        let hasProject = fm.fileExists(atPath: package.appendingPathComponent("project.json").path)
            || fm.fileExists(atPath: package.appendingPathComponent("project.json.prev").path)
        project = hasProject ? try Project.open(package: package) : try Project.create(package: package)
        let source = ProjectRenderSource(project)
        player = try PreviewPlayer(project: source)
        adapter = PreviewPlayerAdapter(player: player)
        model = EditorModel(project: CoreEditingProject(project: project), player: adapter)
        export = ExportModel(engine: RenderExportEngine(source: source))
        title = package.deletingPathExtension().lastPathComponent
        if !hasProject { try? project.save() }
        model.fitTimeline(width: 900)
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
