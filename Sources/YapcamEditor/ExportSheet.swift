import SwiftUI
import AppKit
import YapcamRender

struct ExportSheet: View {
    @ObservedObject var export: ExportModel
    var suggestedName: String
    @Environment(\.dismiss) private var dismiss
    @State private var destination: URL?
    @State private var confirmStop = false

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
                    ProgressView(value: p) { Text(export.target == .clipboard ? "Copying… \(Int(p * 100))%" : "Rendering… \(Int(p * 100))%") }
                    SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(Self.timing(since: export.startedAt, fraction: p, now: ctx.date)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                HStack { Spacer(); Button("Cancel") { confirmStop = true }.keyboardShortcut(.cancelAction) }
                    .confirmationDialog("Stop the export?", isPresented: $confirmStop, titleVisibility: .visible) {
                        Button("Stop export", role: .destructive) { export.cancel() }
                        Button("Keep exporting", role: .cancel) {}
                    } message: { Text("What has been rendered so far is discarded.") }
            case .done(let url):
                Label(export.target == .clipboard ? "Copied to the clipboard" : "Export finished", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(url.lastPathComponent).font(.callout).foregroundStyle(.secondary)
                if export.target == .clipboard { Text("Paste it into a message or a folder. A copy stays in Recent copies.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Done") { export.reset(); dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
                .onAppear { if export.target == .file { NSWorkspace.shared.activateFileViewerSelecting([url]) } }   // the finished file is revealed
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

    /// Reference layout: target at the top; one row with format and frame rate; one row with size and compression (or the GIF
    /// switches); advanced formats (HEVC, paired H.264 + HEVC, MOV) under "Advanced"; history of clipboard copies.
    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            if case .cancelled = export.state { Text("Export cancelled.").foregroundStyle(.secondary) }
            PillPicker(selection: $export.target, options: ExportTarget.allCases.map { ($0.label, $0) }, accessibilityTitle: "Export to")
            HStack(alignment: .top, spacing: EditorMetrics.m) {
                labeled("Format") {
                    Picker("Format", selection: $export.format) {
                        ForEach(ExportFormat.primary.filter { export.availableFormats.contains($0) }) { Text($0.label).tag($0) }
                        Divider()
                        ForEach(ExportFormat.advanced.filter { export.availableFormats.contains($0) }) { Text($0.label).tag($0) }
                    }.pickerStyle(.menu).labelsHidden()
                }
                labeled("Frame rate") {
                    Picker("Frame rate", selection: $export.fps) { ForEach(export.options.fps, id: \.self) { Text("\($0) fps").tag($0) } }.pickerStyle(.menu).labelsHidden()
                }
            }
            HStack(alignment: .top, spacing: EditorMetrics.m) {
                labeled("Size") {
                    Picker("Size", selection: $export.height) { ForEach(export.options.heights, id: \.self) { Text(ExportSettings.heightTitle($0)).tag($0) } }.pickerStyle(.menu).labelsHidden()
                }
                if !export.availablePresets.isEmpty {
                    labeled("Compression") {
                        Picker("Compression", selection: $export.preset) { ForEach(export.availablePresets) { Text($0.label).tag($0) } }.pickerStyle(.menu).labelsHidden()
                    }
                } else {
                    labeled("GIF") {
                        VStack(alignment: .leading, spacing: EditorMetrics.xs) {
                            Toggle("High quality", isOn: $export.gifHighQuality)
                            Toggle("Play once", isOn: $export.gifDisableLoop)
                        }
                    }
                }
            }
            if !export.availablePresets.isEmpty { Text(export.preset.hint).font(.caption).foregroundStyle(.secondary) }
            if export.format.supportsAudio { Toggle("Include audio", isOn: $export.includeAudio) }
            if export.showsLargeGIFWarning {
                Label("A 1080p GIF can become very large. 480p or 720p is usually plenty.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if export.format.fileTargetOnly {
                Text("Writes two files: this one, and a copy ending in “-h265”.").font(.caption).foregroundStyle(.secondary)
            }
            if export.usesVariableFrameRate {
                Text("Experimental variable frame rate is on (Settings): identical frames are left out, so the file has fewer frames than the frame rate suggests.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let e = export.estimate {
                Text("\(e.width)×\(e.height) · about \(ByteCountFormatter.string(fromByteCount: e.bytes, countStyle: .file)) · roughly \(Self.duration(e.renderSeconds)) to export")
                    .font(.caption).foregroundStyle(.secondary).accessibilityLabel("Estimate")
            }
            if export.target == .clipboard {
                DisclosureGroup("Recent copies") {
                    if export.history.isEmpty { Text("Nothing copied yet.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(export.history.prefix(6), id: \.self) { url in
                        HStack {
                            Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Copy again") { export.copyAgain(url) }.buttonStyle(.borderless)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show in Finder")
                        }
                    }
                }
                .onAppear { export.refreshHistory() }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if export.target == .clipboard {
                    Button("Copy to Clipboard") { export.copyToClipboard() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                } else {
                    Button("Export…") { choose() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: EditorMetrics.xs) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Label column + control, aligned like the inspector rows.
    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: EditorMetrics.s) {
            Text(title).frame(width: SliderRow<EmptyView>.labelWidth, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "0:42 elapsed · about 1:10 left" from the start time and the fraction rendered.
    static func timing(since start: Date?, fraction: Double, now: Date) -> String {
        guard let start else { return "" }
        let elapsed = max(0, now.timeIntervalSince(start))
        func clock(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
        guard fraction > 0.03 else { return "\(clock(elapsed)) elapsed" }
        return "\(clock(elapsed)) elapsed · about \(clock(elapsed / fraction * (1 - fraction))) left"
    }

    static func duration(_ s: Double) -> String { s < 90 ? "\(max(1, Int(s.rounded()))) s" : "\(Int((s / 60).rounded())) min" }

    private static let folderKey = "yapcam.export.lastFolder"
    private func choose() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [export.format == .gif ? .gif : export.format.fileExtension == "mov" ? .quickTimeMovie : .mpeg4Movie]
        panel.nameFieldStringValue = suggestedName + "." + export.format.fileExtension      // the project's name
        panel.canCreateDirectories = true
        if let last = UserDefaults.standard.string(forKey: Self.folderKey) { panel.directoryURL = URL(fileURLWithPath: last, isDirectory: true) }
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.folderKey)
            export.start(to: url)
        }
    }
}
