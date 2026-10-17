import AppKit
import YapcamEditor
import UniformTypeIdentifiers
import YapcamCore

/// "Show in Finder" for every button that has one; the side effect is replaceable so the buttons' real target is testable.
@MainActor enum FinderReveal {
    static var perform: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    static func show(_ url: URL) { perform([url]) }
}

/// File-level operations on .yapcam packages and diagnostics, shared by menus and the Recordings window.
@MainActor enum ProjectActions {
    /// Destinations claimed by imports that are still running, so two imports of
    /// same-named videos never pick the same package and never delete each other's.
    /// Keys are lowercased, Unicode-normalized paths: on a case-insensitive volume `Demo.yapcam`
    /// and `demo.yapcam` are the same destination.
    private static var reserved = Set<String>()
    private static func key(_ url: URL) -> String { url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased() }

    static func uniqueURL(in dir: URL, name: String) -> URL {
        var url = dir.appending(path: "\(name).yapcam", directoryHint: .isDirectory)
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) || reserved.contains(key(url)) {
            url = dir.appending(path: "\(name) \(i).yapcam", directoryHint: .isDirectory); i += 1
        }
        return url
    }

    /// Picks a free package URL and holds it until `release` is called.
    static func reserveURL(in dir: URL, name: String) -> URL {
        let url = uniqueURL(in: dir, name: name)
        reserved.insert(key(url))
        return url
    }
    static func release(_ url: URL) { reserved.remove(key(url)) }

    static func rename(_ url: URL, to newName: String) throws -> URL {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { throw EngineError.failed("The name can't be empty.") }
        let dest = url.deletingLastPathComponent().appending(path: "\(clean).yapcam", directoryHint: .isDirectory)
        guard dest != url else { return url }
        // A case-only change ("demo" → "Demo") names the same file on a case-insensitive volume: go through a temp name.
        let caseOnly = dest.lastPathComponent.lowercased() == url.lastPathComponent.lowercased()
        guard caseOnly || !FileManager.default.fileExists(atPath: dest.path) else { throw EngineError.failed("A recording named “\(clean)” already exists.") }
        closeEditor(showing: url)
        if caseOnly {
            let tmp = url.deletingLastPathComponent().appending(path: ".rename-\(UUID().uuidString).yapcam", directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: url, to: tmp)
            do { try FileManager.default.moveItem(at: tmp, to: dest) } catch { try? FileManager.default.moveItem(at: tmp, to: url); throw error }
        } else {
            try FileManager.default.moveItem(at: url, to: dest)
        }
        return dest
    }

    /// An editor showing this package holds its path and would save to the old location: close it (it saves
    /// on close) before the package is renamed or trashed.
    static func closeEditor(showing package: URL) {
        if EditorWindows.isOpen(package: package) { EditorWindows.close(package: package) }
    }

    static func trash(_ url: URL) throws {
        closeEditor(showing: url)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    static func duplicate(_ url: URL) throws -> URL {
        let dest = uniqueURL(in: url.deletingLastPathComponent(), name: url.deletingPathExtension().lastPathComponent + " copy")
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    /// A project file name from what the user typed: trimmed, without path separators or the characters macOS refuses,
    /// and without a trailing ".yapcam" (added back by the caller). nil when nothing usable is left.
    static func cleanProjectName(_ typed: String) -> String? {
        var t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasSuffix(".yapcam") { t = String(t.dropLast(7)) }
        t = String(t.unicodeScalars.filter { !"/\\:*?\"<>|".unicodeScalars.contains($0) && !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return t.isEmpty ? nil : t
    }

    /// Save As…: a copy of the package under a new name in `directory` (the original stays untouched).
    /// Never overwrites: an existing name gets " 2", " 3", …
    static func saveCopy(of url: URL, named typed: String, in directory: URL) throws -> URL {
        guard let name = cleanProjectName(typed) else { throw EngineError.failed("Give the project a name.") }
        let dest = uniqueURL(in: directory, name: name)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    static func saveAs(_ url: URL) {
        EditorWindows.saveAll()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " copy"
        panel.directoryURL = url.deletingLastPathComponent()
        panel.message = "Save a copy of this project"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        do {
            let dest = try saveCopy(of: url, named: chosen.deletingPathExtension().lastPathComponent, in: chosen.deletingLastPathComponent())
            FinderReveal.show(dest)
        } catch { RecordingController.shared.alert = AppAlert(title: "Could not save a copy", error: error) }
    }

    /// A zip of the package (project plus recording) for sharing; the file is also put on the clipboard.
    nonisolated static func zipForSharing(_ url: URL, into directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let zip = directory.appending(path: url.deletingPathExtension().lastPathComponent + ".yapcam.zip")
        try? FileManager.default.removeItem(at: zip)
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", url.path, zip.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: zip.path) else { throw EngineError.failed("Could not zip the project.") }
        return zip
    }

    static func copyAndZip(_ url: URL) {
        EditorWindows.saveAll()
        Task.detached {
            do {
                let zip = try zipForSharing(url)
                await MainActor.run {
                    let pb = NSPasteboard.general
                    pb.clearContents(); pb.writeObjects([zip as NSURL])
                }
            } catch { await MainActor.run { RecordingController.shared.alert = AppAlert(title: "Could not copy the project", error: error) } }
        }
    }

    /// Copies the untouched recorded media (screen, audio, camera, events) to a folder the user picks.
    static func extractRaw(_ url: URL) throws -> URL? {
        let rec = url.appending(path: "recording")
        guard FileManager.default.fileExists(atPath: rec.path) else { throw EngineError.failed("This recording has no raw media folder.") }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Extract Here"
        panel.message = "Choose where to copy the raw recording files."
        guard panel.runModal() == .OK, let parent = panel.url else { return nil }
        let dest = uniqueFolder(in: parent, name: url.deletingPathExtension().lastPathComponent + " raw")
        try FileManager.default.copyItem(at: rec, to: dest)
        return dest
    }

    private static func uniqueFolder(in dir: URL, name: String) -> URL {
        var url = dir.appending(path: name, directoryHint: .isDirectory)
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appending(path: "\(name) \(i)", directoryHint: .isDirectory); i += 1 }
        return url
    }

    /// Opens the package's project, or creates it. A newly created project starts from the preset marked
    /// "use as default for new projects" (applied before anything else edits it), so a fresh recording, a quick
    /// export and an import all get the same look as one opened first in the editor.
    static func openOrCreateProject(_ package: URL) throws -> Project {
        if FileManager.default.fileExists(atPath: package.appending(path: "project.json").path) { return try Project.open(package: package) }
        let project = try Project.create(package: package)
        applyInitialLook(to: project, package: package)
        applyRecordTimeAudio(to: project, cleanVoice: AppSettings.shared.cleanVoiceOnRecord && AppSettings.shared.microphoneID != nil)
        return project
    }

    /// The microphone menu's "Clean up voice" choice becomes the new project's voice clean-up (after the look, so presets don't override it).
    static func applyRecordTimeAudio(to project: Project, cleanVoice: Bool) {
        guard cleanVoice else { return }
        try? project.apply(.set(path: "audio.speech_enhancement", value: .bool(true)))
    }

    /// A new project's starting look, in this order: a preset marked as default; else the last project's look when the
    /// user asked for that and there is one; else the standard look.
    static func applyInitialLook(to project: Project, package: URL, reuseLast: Bool = AppSettings.shared.reuseLastProjectSettings,
                                 in directory: URL = AppSettings.shared.storageDirectory, presets: YapcamEditor.PresetStore? = nil) {
        if EditorPresets.applyDefaultPreset(to: project, from: presets) { return }
        if reuseLast, let last = lastProject(excluding: package, in: directory) { _ = copyLook(from: last, to: project) }
    }

    /// The most recently saved project in `directory` other than `package`.
    static func lastProject(excluding package: URL, in directory: URL) -> URL? {
        let fm = FileManager.default
        let skip = package.standardizedFileURL.path
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        func saved(_ u: URL) -> Date? {
            try? u.appending(path: "project.json").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return urls.filter { $0.pathExtension == "yapcam" && $0.standardizedFileURL.path != skip }
            .compactMap { u in saved(u).map { (u, $0) } }.max { $0.1 < $1.1 }?.0
    }

    /// Reads the look of `source` (never saves or changes it) and applies it to `project`.
    private static func copyLook(from source: URL, to project: Project) -> Bool {
        guard let src = try? Project.open(package: source) else { return false }
        defer { src.close() }
        let tmp = FileManager.default.temporaryDirectory.appending(path: "yapcam-lastlook-\(UUID().uuidString).yapcampreset")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? src.exportPreset(to: tmp)) != nil else { return false }
        return (try? project.importPreset(from: tmp)) != nil
    }

    /// Stores speaker notes in a freshly recorded package (creates project.json if needed).
    static func attachNotes(_ notes: String, to package: URL) throws {
        let fm = FileManager.default
        let project = try openOrCreateProject(package)
        try project.apply(.set(path: "notes", value: .string(notes)))
        try project.save()
    }

    /// Newest .yapcam package in the recordings folder.
    static func newestPackage() -> URL? {
        let dir = AppSettings.shared.storageDirectory
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return urls.filter { $0.pathExtension == "yapcam" }.max { date($0) < date($1) }
    }

    static func openLast() {
        guard let pkg = RecordingController.shared.lastPackage ?? newestPackage() else {
            RecordingController.shared.alert = AppAlert(title: "No recordings yet", message: "Record something first; it then opens here.")
            return
        }
        RecordingController.shared.engine.openEditor(package: pkg)
    }

    // MARK: Import

    static func importVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.message = "Choose a video to edit in Yapcam"
        guard panel.runModal() == .OK, let video = panel.url else { return }
        importVideo(video)
    }

    static func importVideo(_ video: URL) {
        let dir = AppSettings.shared.storageDirectory
        let pkg = reserveURL(in: dir, name: video.deletingPathExtension().lastPathComponent)
        Task {
            defer { release(pkg) }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let imported = try await Project.importVideo(video, package: pkg)
                if EditorPresets.applyDefaultPreset(to: imported) { try? imported.save() }
                RecordingController.shared.engine.openEditor(package: pkg)
            } catch {
                // Never delete here: `importVideo` removes only what it created itself, and
                // `pkg` may be a package someone else made in the meantime.
                RecordingController.shared.alert = AppAlert(title: "Could not import the video", error: error)
            }
        }
    }

    /// Opens a .yapcam package (or imports a plain video) handed to the app by Finder / Open With.
    static func open(_ url: URL) {
        if url.pathExtension.lowercased() == "yapcam" {
            guard FileManager.default.fileExists(atPath: url.appending(path: "project.json").path)
                    || FileManager.default.fileExists(atPath: url.appending(path: "recording").path) else {
                RecordingController.shared.alert = AppAlert(title: "Can't open recording", message: "“\(url.lastPathComponent)” is not a complete Yapcam recording.")
                return
            }
            RecordingController.shared.engine.openEditor(package: url)
        } else { importVideo(url) }
    }

    // MARK: Diagnostics

    /// Writes a plain-text report (versions, permissions, displays, log tail) the user can attach to a bug report.
    static func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Yapcam-Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        writeDiagnostics(to: dest)
    }

    /// The diagnostics report: version, permissions, displays and the log tail.
    static func diagnosticsText() -> String {
        var out = "Yapcam diagnostics \(Date().ISO8601Format())\n"
        let info = Bundle.main.infoDictionary
        out += "Version \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))\n"
        out += "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n\nPermissions\n"
        for p in AppPermission.allCases { out += "  \(p.rawValue): \(PermissionsModel.shared.state(p))\n" }
        out += "\nDisplays\n"
        for d in Displays.all() { out += "  \(d.id) \(d.name) \(Int(d.frame.width))x\(Int(d.frame.height)) @\(d.scale)x\n" }
        let log = Probe.logURL
        if let text = try? String(contentsOf: log, encoding: .utf8) {
            out += "\nLog (last 200 lines)\n" + text.split(separator: "\n").suffix(200).joined(separator: "\n") + "\n"
        }
        return out
    }

    static func writeDiagnostics(to dest: URL) {
        let out = diagnosticsText()
        do { try out.write(to: dest, atomically: true, encoding: .utf8) }
        catch { RecordingController.shared.alert = AppAlert(title: "Could not write diagnostics", error: error) }
    }
}

/// Unfinished recordings (Yapcam or the Mac stopped mid-take): the launch prompt, File → Recover Recording…,
/// and the picker's Recover button all run this.
@MainActor enum RecoveryFlow {
    static func interrupted() -> [URL] {
        RecordingController.shared.engine.interruptedPackages(in: AppSettings.shared.storageDirectory)
    }

    static func run(silentWhenNone: Bool) {
        let engine = RecordingController.shared.engine
        let found = interrupted()
        guard !found.isEmpty else {
            if !silentWhenNone {
                let a = NSAlert(); a.messageText = "No unfinished recordings"
                a.informativeText = "Everything in the recordings folder was saved properly."
                a.runModal()
            }
            return
        }
        let a = NSAlert()
        a.messageText = found.count == 1 ? "Recording needs to be recovered" : "\(found.count) recordings need to be recovered"
        a.informativeText = "The app or your Mac stopped during recording. Recover keeps everything that was saved to disk."
        a.addButton(withTitle: "Recover now")
        a.addButton(withTitle: "Review…")
        a.addButton(withTitle: "Not Now")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            var last: URL?
            for u in found { do { last = try engine.recover(u) } catch { Probe.log("recover failed \(u.lastPathComponent): \(error)") } }
            if let last { engine.openEditor(package: last) } else { RecentProjectsWindow.shared.show() }
        case .alertSecondButtonReturn: RecentProjectsWindow.shared.show()
        default: break
        }
    }
}

/// Counts unfinished recordings for the picker's Recover button.
@MainActor final class RecoveryModel: ObservableObject {
    static let shared = RecoveryModel()
    @Published private(set) var count = 0
    func refresh() { count = RecoveryFlow.interrupted().count }
}
