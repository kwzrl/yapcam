import AVFoundation
import AppKit
import SwiftUI

struct ProjectEntry: Identifiable, Equatable {
    let url: URL
    let modified: Date
    let bytes: Int64
    /// False for a package that cannot be opened (not a folder, or neither a project nor a recording inside).
    var available = true
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    /// A package is usable when it is a folder holding a project file or a recording folder.
    static func isAvailable(_ url: URL, fm: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        return fm.fileExists(atPath: url.appending(path: "project.json").path) || fm.fileExists(atPath: url.appending(path: "recording").path)
    }
}

enum ProjectSort: String, CaseIterable, Identifiable {
    case date, name
    var id: String { rawValue }
    var label: String { self == .date ? "Date" : "Name" }
}

/// The projects Yapcam knows about: the recordings folder, read the way the old Recordings window read it.
@MainActor final class ProjectsModel: ObservableObject {
    static let shared = ProjectsModel()

    @Published private(set) var projects: [ProjectEntry] = []
    @Published private(set) var interrupted: [URL] = []
    /// Found by "On your Mac" (Spotlight) outside the recordings folder.
    @Published private(set) var onThisMac: [ProjectEntry] = []
    @Published private(set) var scanning = false
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    @Published private(set) var durations: [URL: TimeInterval] = [:]
    private var requested = Set<URL>()

    func reload() {
        reload(in: AppSettings.shared.storageDirectory, removed: AppSettings.shared.removedRecents)
    }

    func reload(in dir: URL, removed: Set<String>) {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        interrupted = RecordingController.shared.engine.interruptedPackages(in: dir)
        let intr = Set(interrupted)
        projects = urls.filter { $0.pathExtension == "yapcam" && !intr.contains($0) && !removed.contains($0.path) }.map { u in
            let ok = ProjectEntry.isAvailable(u)
            return ProjectEntry(url: u,
                                modified: (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast,
                                bytes: ok ? Self.size(of: u) : 0, available: ok)
        }.sorted { $0.modified > $1.modified }
    }

    /// What the grid shows: filtered by the search text and sorted (newest first, or by name).
    nonisolated static func arrange(_ all: [ProjectEntry], query: String, sort: ProjectSort) -> [ProjectEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let hit = q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
        switch sort {
        case .date: return hit.sorted { $0.modified > $1.modified }
        case .name: return hit.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// "1:05" / "12:03:09" under a thumbnail; nil when the length is not known.
    nonisolated static func durationText(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        let t = Int(seconds.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Package paths from `mdfind` output: only .yapcam packages, none in the Trash, none already listed.
    nonisolated static func parseScan(_ output: String, excluding known: Set<String>) -> [URL] {
        output.split(separator: "\n").map(String.init).filter {
            $0.hasSuffix(".yapcam") && !$0.contains("/.Trash/") && !known.contains($0)
        }.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// "On your Mac": asks Spotlight for .yapcam packages anywhere and lists the ones not in the recordings folder.
    func scanMac() {
        guard !scanning else { return }
        scanning = true
        let known = Set(projects.map(\.url.path))
        Task.detached {
            let p = Process()
            p.executableURL = URL(filePath: "/usr/bin/mdfind")
            p.arguments = ["kMDItemFSName == '*.yapcam'"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            var found: [ProjectEntry] = []
            if (try? p.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                found = Self.parseScan(String(decoding: data, as: UTF8.self), excluding: known).map { u in
                    ProjectEntry(url: u, modified: (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast, bytes: 0)
                }.sorted { $0.modified > $1.modified }
            }
            await MainActor.run { self.onThisMac = found; self.scanning = false }
        }
    }

    private nonisolated static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    func loadThumbnail(_ p: ProjectEntry) {
        guard p.available, !requested.contains(p.url) else { return }
        requested.insert(p.url)
        Task.detached {
            let rec = p.url.appending(path: "recording")
            let segs = ((try? FileManager.default.contentsOfDirectory(at: rec, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("seg-") }.sorted { $0.path < $1.path }
                .map { $0.appending(path: "screen.mov") }.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard let movie = segs.first else { return }
            var total = 0.0
            for m in segs { if let d = try? await AVURLAsset(url: m).load(.duration).seconds, d.isFinite { total += d } }
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 480, height: 300)
            let image = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            let ns = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            await MainActor.run {
                if let ns { self.thumbnails[p.url] = ns }
                if total > 0 { self.durations[p.url] = total }
            }
        }
    }

    func rename(_ p: ProjectEntry) {
        guard let name = Prompt.text(title: "Rename Recording", message: "New name for “\(p.name)”", initial: p.name) else { return }
        do { _ = try ProjectActions.rename(p.url, to: name) } catch { RecordingController.shared.alert = AppAlert(title: "Could not rename", error: error) }
        reload()
    }

    func duplicate(_ p: ProjectEntry) {
        do { _ = try ProjectActions.duplicate(p.url) } catch { RecordingController.shared.alert = AppAlert(title: "Could not duplicate", error: error) }
        reload()
    }

    func extractRaw(_ p: ProjectEntry) {
        do { if let dest = try ProjectActions.extractRaw(p.url) { FinderReveal.show(dest) } }
        catch { RecordingController.shared.alert = AppAlert(title: "Could not extract files", error: error) }
    }

    /// Hides a recording from the lists without deleting it.
    func removeFromRecents(_ p: ProjectEntry) {
        AppSettings.shared.removedRecents.insert(p.url.path)
        reload()
    }

    func trash(_ p: ProjectEntry) {
        do { try ProjectActions.trash(p.url) } catch { RecordingController.shared.alert = AppAlert(title: "Could not move to Trash", error: error) }
        reload()
    }
}

@MainActor enum Prompt {
    static func text(title: String, message: String, initial: String) -> String? {
        let a = NSAlert()
        a.messageText = title; a.informativeText = message
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = initial
        a.accessoryView = f
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
    }
}
