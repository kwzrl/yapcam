import AVFoundation
import AppKit
import SwiftUI

struct ProjectEntry: Identifiable, Equatable {
    let url: URL
    let modified: Date
    let bytes: Int64
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor final class RecentProjectsModel: ObservableObject {
    @Published private(set) var projects: [ProjectEntry] = []
    @Published private(set) var interrupted: [URL] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    private var requested = Set<URL>()

    func reload() {
        let dir = AppSettings.shared.storageDirectory
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let engine = RecordingController.shared.engine
        interrupted = engine.interruptedPackages(in: dir)
        let intr = Set(interrupted)
        let removed = AppSettings.shared.removedRecents
        projects = urls.filter { $0.pathExtension == "yapcam" && !intr.contains($0) && !removed.contains($0.path) }.map { u in
            ProjectEntry(url: u,
                         modified: (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast,
                         bytes: Self.size(of: u))
        }.sorted { $0.modified > $1.modified }
    }

    private static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    func loadThumbnail(_ p: ProjectEntry) {
        guard !requested.contains(p.url) else { return }
        requested.insert(p.url)
        Task.detached {
            let rec = p.url.appending(path: "recording")
            let seg = (try? FileManager.default.contentsOfDirectory(at: rec, includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.hasPrefix("seg-") }.sorted { $0.path < $1.path }.first
            guard let movie = seg?.appending(path: "screen.mov"), FileManager.default.fileExists(atPath: movie.path) else { return }
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 320, height: 200)
            if let (img, _) = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) {
                let ns = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
                await MainActor.run { self.thumbnails[p.url] = ns }
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
        do { if let dest = try ProjectActions.extractRaw(p.url) { NSWorkspace.shared.activateFileViewerSelecting([dest]) } }
        catch { RecordingController.shared.alert = AppAlert(title: "Could not extract files", error: error) }
    }

    /// Hides a recording from the lists without deleting it.
    func removeFromRecents(_ p: ProjectEntry) {
        AppSettings.shared.removedRecents.insert(p.url.path)
        reload()
    }

    func trash(_ p: ProjectEntry) {
        try? FileManager.default.trashItem(at: p.url, resultingItemURL: nil)
        reload()
    }
}

@MainActor final class RecentProjectsWindow {
    static let shared = RecentProjectsWindow()
    private var window: NSWindow?
    let model = RecentProjectsModel()

    func show() {
        model.reload()
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 460),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Recordings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: RecentProjectsView(model: model))
            w.setFrameAutosaveName("RecentProjects")
            w.center()
            RecordingController.shared.engine.registerExcluded(w)
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct RecentProjectsView: View {
    @ObservedObject var model: RecentProjectsModel
    @State private var message: String?
    @State private var query = ""
    private var filtered: [ProjectEntry] { query.isEmpty ? model.projects : model.projects.filter { $0.name.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        VStack(spacing: 0) {
            if !model.interrupted.isEmpty { interruptedBanner }
            if !model.projects.isEmpty {
                TextField("Search recordings", text: $query).textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12).padding(.vertical, 8).accessibilityLabel("Search recordings")
            }
            if model.projects.isEmpty && model.interrupted.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack").font(.system(size: 32)).foregroundStyle(.tertiary)
                    Text("No recordings yet").font(.headline)
                    Text("Recordings you make are saved in \((AppSettings.shared.storageDirectory.path as NSString).abbreviatingWithTildeInPath).")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { p in
                    Row(entry: p, thumbnail: model.thumbnails[p.url], open: { open(p) },
                        reveal: { NSWorkspace.shared.activateFileViewerSelecting([p.url]) },
                        rename: { model.rename(p) }, duplicate: { model.duplicate(p) }, removeFromRecents: { model.removeFromRecents(p) },
                        extract: { model.extractRaw(p) }, trash: { model.trash(p) })
                        .onAppear { model.loadThumbnail(p) }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange).padding(8) }
        }
        .frame(minWidth: 480, minHeight: 320)
        .toolbar {
            ToolbarItem { Button { ProjectActions.importVideo() } label: { Image(systemName: "square.and.arrow.down") }.help("Import a video") }
            ToolbarItem { Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh") }
            ToolbarItem { Button { NSWorkspace.shared.open(AppSettings.shared.storageDirectory) } label: { Image(systemName: "folder") }.help("Show folder in Finder") }
        }
    }

    private func open(_ p: ProjectEntry) { RecordingController.shared.engine.openEditor(package: p.url) }

    private var interruptedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(model.interrupted.count) interrupted recording\(model.interrupted.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.headline)
            Text("Yapcam stopped before these were finished. Recover keeps everything that was written to disk.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(model.interrupted, id: \.self) { u in
                HStack {
                    Text(u.deletingPathExtension().lastPathComponent).lineLimit(1)
                    Spacer()
                    Button("Recover") { recover(u) }
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
    }

    private func recover(_ u: URL) {
        do {
            let url = try RecordingController.shared.engine.recover(u)
            model.reload()
            RecordingController.shared.engine.openEditor(package: url)
        } catch { message = "Could not recover “\(u.deletingPathExtension().lastPathComponent)”. \(UserMessage.describe(error))" }
    }

    private struct Row: View {
        let entry: ProjectEntry
        let thumbnail: NSImage?
        let open: () -> Void
        let reveal: () -> Void
        let rename: () -> Void
        let duplicate: () -> Void
        let removeFromRecents: () -> Void
        let extract: () -> Void
        let trash: () -> Void
        var body: some View {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07))
                    if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFill() }
                    else { Image(systemName: "film").foregroundStyle(.tertiary) }
                }
                .frame(width: 96, height: 60).clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("\(entry.modified.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open", action: open)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: open)
            .contextMenu {
                Button("Open", action: open)
                Button("Show in Finder", action: reveal)
                Button("Rename…", action: rename)
                Button("Duplicate", action: duplicate)
                Button("Remove from Recents", action: removeFromRecents)
                Button("Extract Raw Files…", action: extract)
                Divider()
                Button("Move to Trash", role: .destructive, action: trash)
            }
        }
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


/// The toolbar's Folder button: a short list of recent recordings with search.
struct RecentsPopover: View {
    let dismiss: () -> Void
    @ObservedObject var model = RecentProjectsWindow.shared.model
    @State private var query = ""
    private var shown: [ProjectEntry] {
        let all = query.isEmpty ? model.projects : model.projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return Array(all.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PopoverHeader(title: "Recent recordings")
            TextField("Search", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("Search recordings")
            if shown.isEmpty {
                Text(model.projects.isEmpty ? "No recordings yet." : "Nothing matches.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(spacing: 2) {
                    ForEach(shown) { p in
                        HStack {
                            Button {
                                RecordingController.shared.engine.openEditor(package: p.url); dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(p.modified.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button { model.removeFromRecents(p) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove from Recents")
                                .accessibilityLabel("Remove \(p.name) from recents")
                        }
                        .padding(.vertical, 3).padding(.horizontal, 6)
                    }
                }
            }
            Divider()
            HStack {
                Button("All Recordings…") { RecentProjectsWindow.shared.show(); dismiss() }
                Spacer()
                Button("Show Folder") {
                    try? FileManager.default.createDirectory(at: AppSettings.shared.storageDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AppSettings.shared.storageDirectory); dismiss()
                }
            }.controlSize(.small)
        }
        .padding(14).frame(width: 300)
        .onAppear { model.reload() }
    }
}
