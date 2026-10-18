import SwiftUI
import AppKit
import YapcamRender
import YapcamDesign

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
                    ProgressView(value: p) { Text(export.runningTarget == .clipboard ? "Copying… \(Int(p * 100))%" : "Rendering… \(Int(p * 100))%") }
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
                Label(export.runningTarget == .clipboard ? "Copied to the clipboard" : "Export finished", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(url.lastPathComponent).font(.callout).foregroundStyle(.secondary)
                if export.runningTarget == .clipboard { Text("Paste it into a message or a folder. A copy stays in Recent copies.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("Show in Finder") { export.reveal(url) }
                    Button("Done") { export.reset(); dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
                .onAppear { if export.runningTarget == .file { export.reveal(url) } }   // the finished file is revealed
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
            segmentRow("Format") {
                HStack(spacing: 8) {
                    SegmentSwitch([(id: ExportFormat.mp4h264, title: "MP4"), (id: ExportFormat.gif, title: "GIF")],
                                  selection: Binding(get: { export.format == .gif ? .gif : .mp4h264 },
                                                     set: { f in if f == .gif || export.format == .gif { export.format = f } }), height: 26)
                    if export.availableFormats.contains(where: { !$0.isPrimary }) {
                        Menu(export.format.isPrimary ? "More formats" : export.format.label) {
                            ForEach(ExportFormat.advanced.filter { export.availableFormats.contains($0) }) { f in Button(f.label) { export.format = f } }
                        }.menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
            segmentRow("Frame rate") {
                Picker("Frame rate", selection: $export.fps) { ForEach(export.options.fps, id: \.self) { Text("\($0) fps").tag($0) } }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            segmentRow("Resolution") {
                VStack(alignment: .leading, spacing: 4) {
                    SegmentSwitch(export.options.heights.map { (id: $0, title: ExportSettings.heightTitle($0)) }, selection: $export.height, height: 26)
                    if let e = export.estimate { Text("\(e.width) × \(e.height) px").font(Yap.Font.caption).foregroundStyle(Yap.caption).monospacedDigit() }
                }
            }
            if !export.availablePresets.isEmpty {
                segmentRow("Compression") {
                    VStack(alignment: .leading, spacing: 4) {
                        SegmentSwitch(export.availablePresets.map { (id: $0, title: $0.label) }, selection: $export.preset, height: 26)
                        Text(export.preset.longHint).font(Yap.Font.caption).foregroundStyle(Yap.caption).fixedSize(horizontal: false, vertical: true)
                        Text("Compression doesn't change how long the export takes.").font(Yap.Font.caption).foregroundStyle(Yap.caption)
                    }
                }
            } else {
                segmentRow("GIF") {
                    VStack(alignment: .leading, spacing: EditorMetrics.xs) {
                        Toggle("High quality", isOn: $export.gifHighQuality)
                        Toggle("Play once", isOn: $export.gifDisableLoop)
                    }
                }
            }
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
                            Button { export.reveal(url) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show in Finder")
                        }
                    }
                }
                .onAppear { export.refreshHistory() }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if export.target != .clipboard && !export.format.fileTargetOnly {
                    Button("Copy ⌘↩") { export.copyToClipboard() }.keyboardShortcut(.return, modifiers: .command)
                        .help("Copy the export to the clipboard instead")
                }
                if export.target == .clipboard {
                    Button("Copy to Clipboard ↩") { export.copyToClipboard() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                } else {
                    Button("Export… ↩") { choose() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func segmentRow<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: EditorMetrics.s) {
            Text(title).font(Yap.Font.body).foregroundStyle(Yap.label).frame(width: 90, alignment: .leading).padding(.top, 4)
            content().frame(maxWidth: .infinity, alignment: .leading)
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
