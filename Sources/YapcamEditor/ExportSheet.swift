import SwiftUI
import AppKit

struct ExportSheet: View {
    @ObservedObject var export: ExportModel
    var suggestedName: String
    @Environment(\.dismiss) private var dismiss
    @State private var destination: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title2.weight(.semibold))
            switch export.state {
            case .idle, .cancelled: settings
            case .running(let p):
                ProgressView(value: p) { Text("Exporting… \(Int(p * 100))%") }
                HStack { Spacer(); Button("Cancel") { export.cancel() }.keyboardShortcut(.cancelAction) }
            case .done(let url):
                Label("Export finished", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(url.lastPathComponent).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Done") { export.reset(); dismiss() }.keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                Label("Export failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(message).font(.callout).textSelection(.enabled)
                if export.failedWithAudio { Text("If the problem is the audio, you can export the video without it.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("Close") { export.reset(); dismiss() }
                    if export.failedWithAudio { Button("Export without audio") { export.retryWithoutAudio() } }
                    Button("Try again") { export.reset() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(width: 400)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            if case .cancelled = export.state { Text("Export cancelled.").foregroundStyle(.secondary) }
            Picker("Format", selection: $export.format) { ForEach(ExportFormat.allCases) { Text($0.label).tag($0) } }.pickerStyle(.menu)
            Picker("Resolution", selection: $export.height) { ForEach(export.options.heights, id: \.self) { Text($0 == 2160 ? "4K" : "\($0)p").tag($0) } }
            Picker("Frame rate", selection: $export.fps) { ForEach(export.options.fps, id: \.self) { Text("\($0) fps").tag($0) } }
            if export.format.supportsAudio { Toggle("Include audio", isOn: $export.includeAudio) }
            if !export.availablePresets.isEmpty {
                Picker("Compression", selection: $export.preset) { ForEach(export.availablePresets) { Text($0.label).tag($0) } }.pickerStyle(.menu)
                Text(export.preset.hint).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { choose() }.keyboardShortcut(.defaultAction)
            }
        }.pickerStyle(.segmented)
    }

    private func choose() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [export.format == .gif ? .gif : export.format == .movh264 ? .quickTimeMovie : .mpeg4Movie]
        panel.nameFieldStringValue = suggestedName + "." + export.format.fileExtension
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { export.start(to: url) }
    }
}
