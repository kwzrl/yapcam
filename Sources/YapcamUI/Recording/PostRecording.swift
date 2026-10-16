import AppKit
import AVFoundation
import SwiftUI
import YapcamCore
import YapcamEditor
import YapcamRender

/// What happens after Stop: finish the project (markers, notes, automatic zooms), then do what the
/// "After recording" choice says: open the editor (default), or export and copy / save.
@MainActor enum PostRecording {
    /// Writes what only the UI knows (markers, notes, automatic zooms). Quick and local: it runs inside the
    /// stop operation so quitting right after Stop cannot lose it.
    static func prepare(package: URL, notes: String, markers: [Int64], controller: RecordingController) {
        let settings = AppSettings.shared
        if !markers.isEmpty { writeMarkers(markers, to: package) }
        let hasNotes = !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasNotes || settings.createAutoZooms {
            do {
                let project = try ProjectActions.openOrCreateProject(package)
                if hasNotes {
                    do { try project.apply(.set(path: "notes", value: .string(notes))); if controller.notes == notes { controller.clearNotes() } }
                    catch { controller.alert = AppAlert(title: "Notes were not saved", message: "The recording is fine, but its speaker notes could not be stored: \(UserMessage.describe(error))") }
                }
                if settings.createAutoZooms { do { try project.apply(.autoZooms) } catch { Probe.log("auto zooms failed: \(error)") } }
                try project.save()
            } catch {
                controller.alert = AppAlert(title: "The recording is saved, but its project could not be prepared", error: error)
            }
        }
    }

    /// The engine ended the recording by itself: keep what only the UI holds (markers, speaker notes) next to the
    /// recovered files. No project is created here; recovery builds it.
    static func salvage(package: URL, notes: String, markers: [Int64]) {
        if !markers.isEmpty { writeMarkers(markers, to: package) }
        let dir = package.appending(path: "recording", directoryHint: .isDirectory)
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, FileManager.default.fileExists(atPath: dir.path) {
            try? notes.write(to: dir.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// What the "After recording" choice says: open the editor (default), or export and copy / save.
    /// May take minutes (export, save panel), so it never runs inside the capture queue.
    static func deliver(package: URL, controller: RecordingController) async {
        let settings = AppSettings.shared
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
    /// Self-tests save here instead of showing the save panel (a panel would block a headless run).
    nonisolated(unsafe) static var testSaveURL: URL?

    nonisolated static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/Yapcam/QuickExport", directoryHint: .isDirectory)
    }

    func runOnLast(_ action: Action) {
        guard let pkg = RecordingController.shared.lastPackage ?? ProjectActions.newestPackage() else {
            RecordingController.shared.alert = AppAlert(title: "Nothing to export", message: "Record something first, or open a recording and export it from the editor.")
            return
        }
        Task { await export(pkg, action: action) }
    }

    /// Only a lack of progress stops an export, never its total length (a long recording legitimately
    /// takes many minutes). Before the first progress callback (project open, exporter and audio setup)
    /// the allowance is `setupLimit`; afterwards `stallLimit` without any change in progress.
    nonisolated static let stallLimit: TimeInterval = 60
    nonisolated static let setupLimit: TimeInterval = 180

    nonisolated static func isStalled(idleFor idle: TimeInterval, hasProgress: Bool) -> Bool {
        idle > (hasProgress ? stallLimit : setupLimit)
    }

    func export(_ package: URL, action: Action) async {
        guard !running else { return }
        running = true; defer { running = false }
        state = .working(0)
        let name = package.deletingPathExtension().lastPathComponent
        Self.pruneCache()
        let started = Date()
        Probe.log("quick-export start \(action) package=\(name)")
        QuickExportWidget.shared.showProgress()
        do {
            let out = try await Self.runGuarded(package: package, name: name)
            Probe.log("quick-export rendered \(name).mp4 in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            switch action {
            case .copy:
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([out as NSURL])
                state = .done("Copied \(name).mp4 to the clipboard")
            case .save:
                if let dest = Self.testSaveURL {
                    try Self.replaceFile(at: dest, with: out)
                    state = .done("Saved \(dest.lastPathComponent)")
                } else {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "\(name).mp4"
                    panel.directoryURL = AppSettings.shared.storageDirectory
                    panel.allowedContentTypes = [.mpeg4Movie]
                    if panel.runModal() == .OK, let dest = panel.url {
                        try Self.replaceFile(at: dest, with: out)
                        state = .done("Saved \(dest.lastPathComponent)")
                        NSWorkspace.shared.activateFileViewerSelecting([dest])
                    } else { state = .idle }
                }
            }
            Probe.log("quick-export done \(action): \(state)")
        } catch {
            let message = (error as? QuickExportError)?.message ?? UserMessage.describe(error)
            state = .failed(message)
            Probe.log("quick-export FAILED \(action): \(error)")
            RecordingController.shared.alert = AppAlert(title: "Export failed", message: message)
        }
        QuickExportWidget.shared.refresh()
    }

    /// Copies `source` over `dest` without ever leaving the user without a file: the copy is staged next to
    /// `dest` and swapped in only when it is complete, so a full disk or a dropped share keeps the original.
    nonisolated static func replaceFile(at dest: URL, with source: URL) throws {
        let fm = FileManager.default
        let stage = dest.deletingLastPathComponent().appending(path: ".\(dest.lastPathComponent).yapcam-\(UUID().uuidString.prefix(8)).tmp")
        do {
            try fm.copyItem(at: source, to: stage)
            if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: stage) }
            else { try fm.moveItem(at: stage, to: dest) }
        } catch {
            try? fm.removeItem(at: stage)
            throw error
        }
    }

    /// Quick-export files older than a week are removed (the newest ones may still be on the clipboard).
    nonisolated static func pruneCache(olderThan age: TimeInterval = 7 * 24 * 3600, in dir: URL = cacheDirectory) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for u in items {
            if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(d) > age {
                try? fm.removeItem(at: u)
            }
        }
    }

    enum QuickExportError: Error {
        case stalled(Int)
        var message: String {
            switch self {
            case .stalled(let s): return "The export stopped making progress for \(s) seconds and was cancelled. The recording is safe: open it in the editor and export from there."
            }
        }
    }

    /// The export runs off the main thread and races a watchdog, so neither a slow encoder nor a hung one can
    /// freeze the app or leave the widget "working" forever.
    private static func runGuarded(package: URL, name: String) async throws -> URL {
        let dir = cacheDirectory
        // A new file per run: a cancelled worker that is still writing can never collide with the next export.
        let runDir = dir.appending(path: UUID().uuidString.prefix(8).description, directoryHint: .isDirectory)
        let out = runDir.appending(path: "\(name).mp4")
        let tracker = ProgressTracker()
        let result: Result<URL, Error> = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let work = Task.detached(priority: .userInitiated) {
                do {
                    let project = FileManager.default.fileExists(atPath: package.appending(path: "project.json").path)
                        ? try Project.open(package: package)
                        : try await MainActor.run { try ProjectActions.openOrCreateProject(package) }
                    try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
                    let exporter = try Exporter(project: project,
                                                settings: ExportSettings(format: .mp4, codec: .h264, outputHeight: 1080, fps: 30, quality: 0.8, includeAudio: true),
                                                destination: out)
                    _ = try await exporter.run(progress: { p in
                        tracker.update(p)
                        Task { @MainActor in QuickExport.shared.progress(p) }
                    })
                    once.resume(.success(out))
                } catch { once.resume(.failure(error)) }
            }
            Task.detached {
                while true {
                    try? await Task.sleep(for: .seconds(2))
                    if once.isFinished { return }
                    let idle = Date().timeIntervalSince(tracker.lastChange)
                    if isStalled(idleFor: idle, hasProgress: tracker.hasProgress) {
                        let limit = Int(tracker.hasProgress ? stallLimit : setupLimit)
                        work.cancel()
                        once.resume(.failure(QuickExportError.stalled(limit)))
                        // Delete the partial file only after the worker has really stopped writing.
                        _ = await work.value
                        try? FileManager.default.removeItem(at: runDir)
                        return
                    }
                }
            }
        }
        return try result.get()
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

    var isVisible: Bool { panel?.isVisible ?? false }

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

/// Remembers the last progress value and when it changed; logs every 10 %.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    private var changed = Date()
    private var loggedDecile = -1
    var lastChange: Date { lock.lock(); defer { lock.unlock() }; return changed }
    var hasProgress: Bool { lock.lock(); defer { lock.unlock() }; return last >= 0 }
    func update(_ p: Double) {
        lock.lock()
        if p != last { last = p; changed = Date() }
        let decile = Int(p * 10)
        let log = decile > loggedDecile
        if log { loggedDecile = decile }
        lock.unlock()
        if log { Probe.log("quick-export progress \(Int(p * 100))%") }
    }
}

/// Resumes a continuation exactly once, from whichever of the worker and the watchdog gets there first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<URL, Error>, Never>?
    init(_ c: CheckedContinuation<Result<URL, Error>, Never>) { continuation = c }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return continuation == nil }
    func resume(_ r: Result<URL, Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: r)
    }
}
