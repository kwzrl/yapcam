import AppKit
import AVFoundation
import SwiftUI
import YapcamCore
import YapcamEditor
import YapcamRender

/// What happens after Stop: finish the project (markers, notes, automatic zooms), then do what the
/// "After recording" choice says: open the editor (default), or export and copy / save.
@MainActor enum PostRecording {
    static func process(package: URL, notes: String, markers: [Int64], controller: RecordingController) async {
        let settings = AppSettings.shared
        if !markers.isEmpty { writeMarkers(markers, to: package) }
        let hasNotes = !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasNotes || settings.createAutoZooms {
            do {
                let project = FileManager.default.fileExists(atPath: package.appending(path: "project.json").path)
                    ? try Project.open(package: package) : try Project.create(package: package)
                if hasNotes {
                    do { try project.apply(.set(path: "notes", value: .string(notes))); controller.clearNotes() }
                    catch { controller.alert = AppAlert(title: "Notes were not saved", message: "The recording is fine, but its speaker notes could not be stored: \(UserMessage.describe(error))") }
                }
                if settings.createAutoZooms { do { try project.apply(.autoZooms) } catch { Probe.log("auto zooms failed: \(error)") } }
                try project.save()
            } catch {
                controller.alert = AppAlert(title: "The recording is saved, but its project could not be prepared", error: error)
            }
        }
        switch settings.afterRecording {
        case .createProject:
            if settings.showQuickExportWidget { QuickExportWidget.shared.show(for: package) }
            else { controller.engine.openEditor(package: package) }
        case .exportCopy: await QuickExport.shared.export(package, action: .copy)
        case .exportSave: await QuickExport.shared.export(package, action: .save)
        }
    }

    /// Marker times are recording time in ns (pauses excluded), the same basis as the events.
    static func writeMarkers(_ markers: [Int64], to package: URL) {
        let dir = package.appending(path: "recording", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: dir.path),
              let data = try? JSONSerialization.data(withJSONObject: ["markers_ns": markers.map { NSNumber(value: $0) }], options: [.prettyPrinted]) else { return }
        try? data.write(to: dir.appending(path: "markers.json"), options: .atomic)
    }
}

/// Export a recording at 1080p MP4 without opening the editor, then copy it to the clipboard or save it.
@MainActor final class QuickExport: ObservableObject {
    static let shared = QuickExport()
    enum Action { case copy, save }
    enum State: Equatable { case idle, working(Double), done(String), failed(String) }
    @Published private(set) var state: State = .idle
    private var running = false

    static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/Yapcam/QuickExport", directoryHint: .isDirectory)
    }

    func runOnLast(_ action: Action) {
        guard let pkg = RecordingController.shared.lastPackage ?? ProjectActions.newestPackage() else {
            RecordingController.shared.alert = AppAlert(title: "Nothing to export", message: "Record something first, or open a recording and export it from the editor.")
            return
        }
        Task { await export(pkg, action: action) }
    }

    func export(_ package: URL, action: Action) async {
        guard !running else { return }
        running = true; defer { running = false }
        state = .working(0)
        QuickExportWidget.shared.showProgress()
        do {
            let project = FileManager.default.fileExists(atPath: package.appending(path: "project.json").path)
                ? try Project.open(package: package) : try Project.create(package: package)
            try FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
            let name = package.deletingPathExtension().lastPathComponent
            let out = Self.cacheDirectory.appending(path: "\(name).mp4")
            try? FileManager.default.removeItem(at: out)
            let exporter = try Exporter(project: project,
                                        settings: ExportSettings(format: .mp4, codec: .h264, outputHeight: 1080, fps: 30, quality: 0.8, includeAudio: true),
                                        destination: out)
            _ = try await exporter.run(progress: { p in Task { @MainActor in QuickExport.shared.progress(p) } })
            switch action {
            case .copy:
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([out as NSURL])
                state = .done("Copied \(name).mp4 to the clipboard")
            case .save:
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "\(name).mp4"
                panel.directoryURL = AppSettings.shared.storageDirectory
                panel.allowedContentTypes = [.mpeg4Movie]
                if panel.runModal() == .OK, let dest = panel.url {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: out, to: dest)
                    state = .done("Saved \(dest.lastPathComponent)")
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                } else { state = .idle }
            }
        } catch {
            state = .failed(UserMessage.describe(error))
            RecordingController.shared.alert = AppAlert(title: "Export failed", error: error)
        }
        QuickExportWidget.shared.refresh()
    }

    fileprivate func progress(_ p: Double) { if case .working = state { state = .working(p) } }
}

// MARK: - The small post-recording widget

@MainActor final class QuickExportWidget {
    static let shared = QuickExportWidget()
    private var panel: NSPanel?
    private let model = QuickExportWidgetModel()

    func show(for package: URL) {
        model.package = package
        model.loadThumbnail()
        present()
    }

    func showProgress() { if model.package == nil { model.package = RecordingController.shared.lastPackage }; present() }
    func refresh() { model.objectWillChange.send() }

    private func present() {
        if panel == nil {
            let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 340, height: 150),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .floating; p.isMovableByWindowBackground = true; p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: QuickExportWidgetView(model: model, close: { [weak self] in self?.panel?.orderOut(nil) })
                .environmentObject(QuickExport.shared))
            RecordingController.shared.engine.registerExcluded(p)
            panel = p
        }
        if let s = NSScreen.main { panel?.setFrameOrigin(CGPoint(x: s.visibleFrame.minX + 24, y: s.visibleFrame.minY + 24)) }
        panel?.orderFrontRegardless()
    }
}

@MainActor final class QuickExportWidgetModel: ObservableObject {
    @Published var package: URL?
    @Published var thumbnail: NSImage?
    func loadThumbnail() {
        thumbnail = nil
        guard let pkg = package else { return }
        Task.detached {
            let seg = (try? FileManager.default.contentsOfDirectory(at: pkg.appending(path: "recording"), includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.hasPrefix("seg-") }.sorted { $0.path < $1.path }.first
            guard let movie = seg?.appending(path: "screen.mov") else { return }
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: movie)); gen.maximumSize = CGSize(width: 480, height: 300)
            if let (img, _) = try? await gen.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)) {
                let ns = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
                await MainActor.run { self.thumbnail = ns }
            }
        }
    }
}

struct QuickExportWidgetView: View {
    @ObservedObject var model: QuickExportWidgetModel
    let close: () -> Void
    @EnvironmentObject var export: QuickExport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08))
                    if let t = model.thumbnail { Image(nsImage: t).resizable().scaledToFill() }
                    else { Image(systemName: "film").foregroundStyle(.tertiary) }
                }
                .frame(width: 96, height: 60).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.package?.deletingPathExtension().lastPathComponent ?? "Recording").font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("Will export 1080p MP4 with audio").font(.caption).foregroundStyle(.secondary)
                    status
                }
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close").accessibilityLabel("Close")
            }
            HStack(spacing: 8) {
                Button("Copy") { run(.copy) }
                Button("Save…") { run(.save) }
                Spacer()
                Button("Edit") { if let p = model.package { RecordingController.shared.engine.openEditor(package: p); close() } }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small).disabled(isWorking)
        }
        .padding(14).frame(width: 340)
        .panelSurface(cornerRadius: 14)
    }

    private var isWorking: Bool { if case .working = export.state { true } else { false } }

    @ViewBuilder private var status: some View {
        switch export.state {
        case .working(let p): ProgressView(value: p).controlSize(.small).frame(maxWidth: 160)
        case .done(let m): Label(m, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).lineLimit(1)
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).lineLimit(2)
        case .idle: EmptyView()
        }
    }

    private func run(_ a: QuickExport.Action) {
        guard let p = model.package else { return }
        Task { await QuickExport.shared.export(p, action: a) }
    }
}
