import SwiftUI
import AppKit
import YapcamRender

/// Export from anywhere: ⌘⇧E opens the picker, ⌥⌘S exports to a file straight away, ⌥⌘C copies the export to the clipboard,
/// and ⌘K lists the export settings (format, size, frame rate, compression, target, history).
public enum ExportAction: Sendable { case picker, saveToFile, copyToClipboard, history }

extension EditorModel {
    /// Runs one export action with the current export settings. The picker/history actions open the export sheet.
    public func performExport(_ action: ExportAction) {
        guard let export = exportModel else { lastError = "Export isn't available in this window."; return }
        if export.isRunning { return }                                        // one export at a time per document
        switch action {
        case .picker: showExportPickerHandler?()
        case .history: export.target = .clipboard; export.refreshHistory(); showExportPickerHandler?()
        case .copyToClipboard: export.copyToClipboard(); showExportPickerHandler?()          // the sheet shows the progress
        case .saveToFile:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [export.format == .gif ? .gif : export.format.fileExtension == "mov" ? .quickTimeMovie : .mpeg4Movie]
            panel.nameFieldStringValue = exportTitle + "." + export.format.fileExtension
            panel.canCreateDirectories = true
            if let last = UserDefaults.standard.string(forKey: "yapcam.export.lastFolder") { panel.directoryURL = URL(fileURLWithPath: last, isDirectory: true) }
            export.target = .file
            if panel.runModal() == .OK, let url = panel.url {
                UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "yapcam.export.lastFolder")
                export.start(to: url); showExportPickerHandler?()
            }
        }
    }

    /// ⌘K entries for the export settings; each changes the same model the sheet edits.
    var exportCommands: [PaletteCommand] {
        var out: [PaletteCommand] = []
        func add(_ title: String, shortcut: String = "", enabled: Bool = true, _ run: @escaping @MainActor () -> Void) { out.append(PaletteCommand(title: title, shortcut: shortcut, enabled: enabled, run: run)) }
        let busy = exportModel?.isRunning ?? true
        add("Export…", shortcut: "⇧⌘E", enabled: !busy) { [self] in performExport(.picker) }
        add("Export to file…", shortcut: "⌥⌘S", enabled: !busy) { [self] in performExport(.saveToFile) }
        add("Copy export to clipboard", shortcut: "⌥⌘C", enabled: !busy) { [self] in performExport(.copyToClipboard) }
        add("Show recent clipboard copies", enabled: !busy) { [self] in performExport(.history) }
        guard let e = exportModel else { return out }
        for t in ExportTarget.allCases { add("Export target: \(t.label)", enabled: e.target != t && !busy) { e.target = t } }
        for f in e.availableFormats { add("Export format: \(f.label)", enabled: e.format != f && !busy) { e.format = f } }
        for h in e.options.heights { add("Export size: \(ExportSettings.heightTitle(h))", enabled: e.height != h && !busy) { e.height = h } }
        for r in e.options.fps { add("Export frame rate: \(r) fps", enabled: e.fps != r && !busy) { e.fps = r } }
        for p in e.availablePresets { add("Export compression: \(p.label)", enabled: e.preset != p && !busy) { e.preset = p } }
        if e.format.supportsAudio { add(e.includeAudio ? "Export without audio" : "Export with audio", enabled: !busy) { e.includeAudio.toggle() } }
        return out
    }
}
