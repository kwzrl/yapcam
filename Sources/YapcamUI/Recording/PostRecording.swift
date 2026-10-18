import AppKit
@preconcurrency import UserNotifications
import UniformTypeIdentifiers
import AVFoundation
import SwiftUI
import YapcamDesign
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
    @Published private(set) var state: State = .idle {
        didSet { Self.updateDock(state) }
    }
    /// The finished file (the saved copy, or the cached render for Copy): the widget's "Show in Finder".
    @Published private(set) var lastOutput: URL?
    @Published private(set) var startedAt: Date?
    private var running = false
    private var cancelFlag = CancelFlag()

    /// Asks the running export to stop (the widget confirms first).
    func cancel() { cancelFlag.set() }
    var isRunning: Bool { running }

    /// "42%" on the Dock icon while exporting; nil otherwise (a recording keeps its own ● badge).
    nonisolated static func dockBadge(for progress: Double?) -> String? { progress.map { "\(Int(min(max($0, 0), 1) * 100))%" } }
    private static func updateDock(_ s: State) {
        guard RecordingController.shared.phase != .recording, RecordingController.shared.phase != .paused else { return }
        if case .working(let p) = s { NSApp?.dockTile.badgeLabel = dockBadge(for: p) } else { NSApp?.dockTile.badgeLabel = nil }
    }

    /// "about 20 s left" from elapsed time and progress; nil until there is enough progress to estimate.
    nonisolated static func remainingText(elapsed: TimeInterval, progress: Double) -> String? {
        guard progress >= 0.03, progress < 1, elapsed > 1, elapsed.isFinite else { return nil }
        let left = Int((elapsed / progress * (1 - progress)).rounded())
        return left < 60 ? "about \(max(left, 1)) s left" : "about \((left + 59) / 60) min left"
    }

    /// Completion notice (the system banner when allowed; the widget always shows it too). Overridden in tests.
    nonisolated(unsafe) static var notify: (String, String) -> Void = { title, body in
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }          // denied: the widget and Dock badge still show the result
            let c = UNMutableNotificationContent(); c.title = title; c.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
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
        cancelFlag = CancelFlag(); startedAt = Date(); lastOutput = nil
        let name = package.deletingPathExtension().lastPathComponent
        Self.pruneCache()
        let started = Date()
        Probe.log("quick-export start \(action) package=\(name)")
        QuickExportWidget.shared.showProgress()
        do {
            let out = try await Self.runGuarded(package: package, name: name, cancel: cancelFlag)
            Probe.log("quick-export rendered \(out.lastPathComponent) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            switch action {
            case .copy:
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([out as NSURL])
                lastOutput = out
                state = .done("Copied \(out.lastPathComponent) to the clipboard")
                Self.notify("Copied to the clipboard", out.lastPathComponent)
            case .save:
                if let dest = Self.testSaveURL {
                    try Self.replaceFile(at: dest, with: out)
                    lastOutput = dest
                    state = .done("Saved \(dest.lastPathComponent)")
                } else {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = out.lastPathComponent
                    panel.directoryURL = AppSettings.shared.storageDirectory
                    panel.allowedContentTypes = [UTType(filenameExtension: out.pathExtension) ?? .mpeg4Movie]
                    if panel.runModal() == .OK, let dest = panel.url {
                        try Self.replaceFile(at: dest, with: out)
                        lastOutput = dest
                        state = .done("Saved \(dest.lastPathComponent)")
                        Self.notify("Export saved", dest.lastPathComponent)
                        if AppSettings.shared.actionAfterQuickExport == .revealInFinder { FinderReveal.show(dest) }
                    } else { state = .idle }
                }
            }
            Probe.log("quick-export done \(action): \(state)")
        } catch {
            let message = (error as? QuickExportError)?.message ?? UserMessage.describe(error)
            if case QuickExportError.cancelled = error { state = .idle; QuickExportWidget.shared.refresh(); return }
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
        case cancelled
        var message: String {
            switch self {
            case .cancelled: return "Export cancelled."
            case .stalled(let s): return "The export stopped making progress for \(s) seconds and was cancelled. The recording is safe: open it in the editor and export from there."
            }
        }
    }

    /// The user's quick export settings (Settings → Quick export) plus the experimental variable-frame-rate switch.
    /// "1080p MP4 · 30 fps · Social · with audio": the widget's "Will export" line.
    static func summary(_ e: ExportSettings) -> String {
        var parts = [e.summary(for: .file)]
        if e.format != .gif { parts.append(e.includeAudio ? "with audio" : "no audio") }
        return parts.joined(separator: " • ")
    }

    static func quickExportSettings(base: ExportSettings = AppSettings.defaultQuickExport, variableFrameRate: Bool, hardwareEncoding: Bool = true) -> ExportSettings {
        var e = base
        e.hardwareEncodingEnabled = hardwareEncoding
        e.variableFrameRate = base.format == .gif ? false : variableFrameRate
        return e
    }

    /// The export runs off the main thread and races a watchdog, so neither a slow encoder nor a hung one can
    /// freeze the app or leave the widget "working" forever.
    private static func runGuarded(package: URL, name: String, cancel: CancelFlag) async throws -> URL {
        let dir = cacheDirectory
        // A new file per run: a cancelled worker that is still writing can never collide with the next export.
        let runDir = dir.appending(path: UUID().uuidString.prefix(8).description, directoryHint: .isDirectory)
        let exportSettings = await MainActor.run { quickExportSettings(base: AppSettings.shared.quickExport, variableFrameRate: AppSettings.shared.experimentalVariableFrameRate, hardwareEncoding: !AppSettings.shared.disableHardwareEncoding) }
        let out = runDir.appending(path: "\(name).\(exportSettings.format.rawValue)")
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
                                                settings: exportSettings,
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
                    try? await Task.sleep(for: .milliseconds(500))
                    if once.isFinished { return }
                    if cancel.isSet {
                        work.cancel()
                        once.resume(.failure(QuickExportError.cancelled))
                        _ = await work.value
                        try? FileManager.default.removeItem(at: runDir)
                        return
                    }
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

    /// The widget's close button: after a Copy or Save (and nothing else holding the project) it asks Keep or Trash.
    func requestClose() {
        let pkg = model.package
        let decision = QuickExportCloseRule.decide(state: QuickExport.shared.state, alwaysKeep: AppSettings.shared.alwaysKeepProjectAfterQuickExport,
                                                    hasPackage: pkg != nil, openInEditor: pkg.map { EditorWindows.isOpen(package: $0) } ?? false)
        guard decision == .askKeepOrTrash, let pkg else { panel?.orderOut(nil); return }
        switch Self.confirmKeepOrTrash(pkg) {
        case .keep(let dontAskAgain):
            if dontAskAgain { AppSettings.shared.alwaysKeepProjectAfterQuickExport = true }
            panel?.orderOut(nil)
        case .trash:
            do { try ProjectActions.trash(pkg); panel?.orderOut(nil); RecentProjectsWindow.shared.model.reload() }
            catch { RecordingController.shared.alert = AppAlert(title: "Could not move to the Trash", error: error) }
        }
    }

    enum KeepChoice: Equatable { case keep(dontAskAgain: Bool), trash }
    /// Replaceable so tests never show the alert.
    static var confirmKeepOrTrash: @MainActor (URL) -> KeepChoice = { pkg in
        let a = NSAlert()
        a.messageText = "Keep the project or move it to the Trash?"
        a.informativeText = "“\(pkg.deletingPathExtension().lastPathComponent)” was exported with the widget. Keeping it lets you edit it later."
        a.addButton(withTitle: "Keep"); a.addButton(withTitle: "Move to Trash")
        a.showsSuppressionButton = true; a.suppressionButton?.title = "Don't ask again"
        a.layout(); RecordingController.shared.engine.registerExcluded(a.window); defer { RecordingController.shared.engine.unregisterExcluded(a.window) }
        let r = a.runModal()
        return r == .alertSecondButtonReturn ? .trash : .keep(dontAskAgain: a.suppressionButton?.state == .on)
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
            let host = NSHostingView(rootView: QuickExportWidgetView(model: model, close: { [weak self] in self?.requestClose() })
                .environmentObject(QuickExport.shared))
            host.sizingOptions = [.intrinsicContentSize]
            p.contentView = host
            p.setContentSize(host.fittingSize)
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
    /// The raw screen movie of the first segment: the widget loops a silent preview of it.
    @Published var movie: URL?
    @Published var renameError: String?

    var title: String { package?.deletingPathExtension().lastPathComponent ?? "Recording" }

    /// Renames the recording's project from the widget. An unchanged or empty name keeps the old one;
    /// a name that is taken or cannot be used leaves the project as it was and says why.
    func rename(to raw: String) {
        guard let pkg = package else { return }
        let clean = ProjectActions.cleanName(raw)
        guard !clean.isEmpty, clean != title else { renameError = nil; return }
        do { package = try ProjectActions.rename(pkg, to: clean); renameError = nil; loadThumbnail() }
        catch { renameError = UserMessage.describe(error) }
    }

    func loadThumbnail() {
        thumbnail = nil; movie = nil
        guard let pkg = package else { return }
        if let seg = (try? FileManager.default.contentsOfDirectory(at: pkg.appending(path: "recording"), includingPropertiesForKeys: nil))?
            .filter({ $0.lastPathComponent.hasPrefix("seg-") }).sorted(by: { $0.path < $1.path }).first {
            let m = seg.appending(path: "screen.mov")
            if FileManager.default.fileExists(atPath: m.path) { movie = m }
        }
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

/// The recording's name in the widget: click to rename, Return to keep.
private struct TitleField: View {
    @ObservedObject var model: QuickExportWidgetModel
    let locked: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain).focused($focused)
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Yap.title).lineLimit(1)
            .disabled(locked)
            .onAppear { draft = model.title }
            .onChange(of: model.package) { _, _ in if !focused { draft = model.title } }
            .onChange(of: focused) { _, now in if !now { model.rename(to: draft); draft = model.title } }
            .onSubmit { model.rename(to: draft); draft = model.title }
            .help(model.renameError ?? (locked ? "The name can change when the export is done" : "Click to rename this recording"))
            .accessibilityLabel("Recording name")
    }
}

struct QuickExportWidgetView: View {
    @ObservedObject var model: QuickExportWidgetModel
    let close: () -> Void
    @EnvironmentObject var export: QuickExport
    @ObservedObject private var settings = AppSettings.shared

    // Panel corner 22, content inset 12: inner corners are concentric (10).
    private let radius: CGFloat = 22, inset: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Color.white.opacity(0.06)
                    if let m = model.movie { LoopingPreview(url: m) }
                    else if let t = model.thumbnail { Image(nsImage: t).resizable().scaledToFill() }
                    else { Image(systemName: "film").foregroundStyle(Yap.faint) }
                }
                .frame(width: 112, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: Yap.concentric(radius, inset: inset), style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    TitleField(model: model, locked: isWorking)
                    Text(QuickExport.summary(settings.quickExport)).technical().lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    status
                }
                .padding(.top, 2)
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Button { SettingsWindow.shared.show(tab: .quickExport) } label: { Image(systemName: "gearshape") }
                        .buttonStyle(CircleButtonStyle(size: 26)).help("Quick export settings").accessibilityLabel("Quick export settings")
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(CircleButtonStyle(size: 26)).help("Close").accessibilityLabel("Close")
                }
            }
            HStack(spacing: 8) {
                Button("Copy") { run(.copy) }.buttonStyle(CapsuleButtonStyle(.secondary, height: 30))
                Button("Save…") { run(.save) }.buttonStyle(CapsuleButtonStyle(.secondary, height: 30))
                Spacer()
                Button("Edit") { if let p = model.package { RecordingController.shared.engine.openEditor(package: p); close() } }
                    .buttonStyle(CapsuleButtonStyle(.primary, height: 30))
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(isWorking)
        }
        .padding(inset).frame(width: 380)
        .panelSurface(cornerRadius: radius)
    }

    private var isWorking: Bool { if case .working = export.state { true } else { false } }

    @ViewBuilder private var status: some View {
        switch export.state {
        case .working(let p):
            HStack(spacing: 8) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Yap.recess)
                        Capsule().fill(Color.white).frame(width: max(g.size.width * p, 6))
                    }
                }
                .frame(width: 90, height: 5)
                .accessibilityElement().accessibilityLabel("Export progress").accessibilityValue("\(Int(p * 100)) percent")
                Text(QuickExport.remainingText(elapsed: Date().timeIntervalSince(export.startedAt ?? Date()), progress: p) ?? "\(Int(p * 100))%")
                    .font(Yap.Font.technical).foregroundStyle(Yap.technical).lineLimit(1)
                Button("Stop") { confirmStop() }.buttonStyle(.plain).font(Yap.Font.caption).foregroundStyle(Yap.label)
            }
        case .done(let m):
            HStack(spacing: 6) {
                Label(m, systemImage: "checkmark").font(Yap.Font.caption).foregroundStyle(Yap.label).lineLimit(1)
                if let u = export.lastOutput { Button("Show in Finder") { FinderReveal.show(u) }.buttonStyle(.plain).font(Yap.Font.caption).foregroundStyle(Yap.body) }
            }
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle").font(Yap.Font.caption).foregroundStyle(Yap.technical).lineLimit(2)
        case .idle: Text("Ready to edit or export").font(Yap.Font.caption).foregroundStyle(Yap.caption).lineLimit(1)
        }
    }

    private func confirmStop() {
        let a = NSAlert()
        a.messageText = "Stop exporting?"
        a.informativeText = "The recording stays as it is. You can export again any time."
        a.addButton(withTitle: "Keep Exporting"); a.addButton(withTitle: "Stop Export")
        if a.runModal() == .alertSecondButtonReturn { export.cancel() }
    }

    private func run(_ a: QuickExport.Action) {
        guard let p = model.package else { return }
        Task { await QuickExport.shared.export(p, action: a) }
    }
}

/// Set from the main actor when the user stops an export; read by the watchdog.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
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

/// Silent, looping preview of a movie (the quick export widget).
struct LoopingPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSView {
        let v = PlayerHost()
        v.play(url)
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { if let h = v as? PlayerHost, h.url != url { h.play(url) } }

    final class PlayerHost: NSView {
        private(set) var url: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private let layerHost = AVPlayerLayer()
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layerHost.videoGravity = .resizeAspectFill; layer = layerHost }
        required init?(coder: NSCoder) { fatalError() }
        func play(_ url: URL) {
            self.url = url
            let q = AVQueuePlayer(); q.isMuted = true
            looper = AVPlayerLooper(player: q, templateItem: AVPlayerItem(url: url))
            player = q; layerHost.player = q
            q.play()
        }
        override func removeFromSuperview() { player?.pause(); super.removeFromSuperview() }
    }
}
