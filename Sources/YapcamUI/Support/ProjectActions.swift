import AppKit
import UniformTypeIdentifiers
import YapcamCore

/// File-level operations on .yapcam packages and diagnostics, shared by menus and the Recordings window.
@MainActor enum ProjectActions {
    static func uniqueURL(in dir: URL, name: String) -> URL {
        var url = dir.appending(path: "\(name).yapcam", directoryHint: .isDirectory)
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appending(path: "\(name) \(i).yapcam", directoryHint: .isDirectory); i += 1
        }
        return url
    }

    static func rename(_ url: URL, to newName: String) throws -> URL {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { throw EngineError.failed("The name can't be empty.") }
        let dest = url.deletingLastPathComponent().appending(path: "\(clean).yapcam", directoryHint: .isDirectory)
        guard dest != url else { return url }
        guard !FileManager.default.fileExists(atPath: dest.path) else { throw EngineError.failed("A recording named “\(clean)” already exists.") }
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    static func duplicate(_ url: URL) throws -> URL {
        let dest = uniqueURL(in: url.deletingLastPathComponent(), name: url.deletingPathExtension().lastPathComponent + " copy")
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
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
        let pkg = uniqueURL(in: dir, name: video.deletingPathExtension().lastPathComponent)
        Task {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                _ = try await Project.importVideo(video, package: pkg)
                RecordingController.shared.engine.openEditor(package: pkg)
            } catch {
                try? FileManager.default.removeItem(at: pkg)
                RecordingController.shared.alert = AppAlert(title: "Could not import the video", message: error.localizedDescription)
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
        do { try out.write(to: dest, atomically: true, encoding: .utf8) }
        catch { RecordingController.shared.alert = AppAlert(title: "Could not write diagnostics", message: error.localizedDescription) }
    }
}
