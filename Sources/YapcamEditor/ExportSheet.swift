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
                switch export.queueStatus {
                case .waiting?:
                    ProgressView { Text("Waiting for another export to finish…") }
                case .preparing?:
                    ProgressView { Text("Preparing the export…") }
                default:
                    ProgressView(value: p) { Text("Rendering… \(Int(p * 100))%") }
                }
                HStack { Spacer(); Button("Cancel") { export.cancel() }.keyboardShortcut(.cancelAction) }
            case .done(let url):
                Label("Export finished", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(url.lastPathComponent).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Done") { export.reset(); dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
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
            row("Format") { Picker("Format", selection: $export.format) { ForEach(ExportFormat.allCases) { Text($0.label).tag($0) } }.pickerStyle(.menu).labelsHidden() }
            row("Resolution") {
                Picker("Resolution", selection: $export.height) { ForEach(export.options.heights, id: \.self) { Text($0 == 2160 ? "4K" : "\($0)p").tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            row("Frame rate") { Picker("Frame rate", selection: $export.fps) { ForEach(export.options.fps, id: \.self) { Text("\($0) fps").tag($0) } }.pickerStyle(.menu).labelsHidden() }
            if !export.availablePresets.isEmpty {
                row("Compression") { Picker("Compression", selection: $export.preset) { ForEach(export.availablePresets) { Text($0.label).tag($0) } }.pickerStyle(.menu).labelsHidden() }
                Text(export.preset.hint).font(.caption).foregroundStyle(.secondary).padding(.leading, SliderRow<EmptyView>.labelWidth + EditorMetrics.s)
            }
            if export.format.supportsAudio { row("Audio") { Toggle("Include audio", isOn: $export.includeAudio) } }
            if export.format == .gif {
                row("GIF") {
                    VStack(alignment: .leading, spacing: EditorMetrics.xs) {
                        Toggle("High quality (own palette)", isOn: $export.gifHighQuality)
                        Toggle("Play once (don't loop)", isOn: $export.gifDisableLoop)
                    }
                }
            }
            if export.usesVariableFrameRate {
                Text("Experimental variable frame rate is on (Settings): identical frames are left out, so the file has fewer frames than the frame rate suggests.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let e = export.estimate {
                Text("\(e.width)×\(e.height) · about \(ByteCountFormatter.string(fromByteCount: e.bytes, countStyle: .file)) · roughly \(Self.duration(e.renderSeconds)) to export")
                    .font(.caption).foregroundStyle(.secondary).accessibilityLabel("Estimate")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { choose() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Label column + control, aligned like the inspector rows.
    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: EditorMetrics.s) {
            Text(title).frame(width: SliderRow<EmptyView>.labelWidth, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func duration(_ s: Double) -> String { s < 90 ? "\(max(1, Int(s.rounded()))) s" : "\(Int((s / 60).rounded())) min" }

    private func choose() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [export.format == .gif ? .gif : export.format == .movh264 ? .quickTimeMovie : .mpeg4Movie]
        panel.nameFieldStringValue = suggestedName + "." + export.format.fileExtension
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { export.start(to: url) }
    }
}
