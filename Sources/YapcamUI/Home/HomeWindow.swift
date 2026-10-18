import AppKit
import SwiftUI
import YapcamDesign

/// The projects home: the editor side's front door when no project is open. Replaces the old Recordings window.
@MainActor final class HomeWindow: NSObject, NSWindowDelegate {
    static let shared = HomeWindow()
    private(set) var window: NSWindow?
    let model = ProjectsModel.shared

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        model.reload()
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 880, height: 600),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Yapcam Editor"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = Yap.nsGround
            w.minSize = CGSize(width: 560, height: 380)
            w.contentView = NSHostingView(rootView: HomeView(model: model))
            w.setFrameAutosaveName("YapcamHome")
            w.center()
            w.delegate = self
            RecordingController.shared.engine.registerExcluded(w)
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() { window?.orderOut(nil) }
}

struct HomeView: View {
    @ObservedObject var model: ProjectsModel
    @State private var query = ""
    @State private var sort = ProjectSort.date
    @State private var selection: URL?
    @State private var message: String?

    private var shown: [ProjectEntry] { ProjectsModel.arrange(model.projects, query: query, sort: sort) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Yap.hairline).frame(height: 1)
            if !model.interrupted.isEmpty { interruptedBanner }
            if model.projects.isEmpty && model.interrupted.isEmpty { emptyState } else { grid }
            if !model.onThisMac.isEmpty { macSection }
            if let message { Text(message).font(Yap.Font.caption).foregroundStyle(.orange).padding(8) }
        }
        .background(Yap.ground)
        .foregroundStyle(Yap.label)
        .onAppear { model.reload() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Projects").font(Yap.Font.title(20)).foregroundStyle(Yap.title)
            Spacer(minLength: 12)
            if !model.projects.isEmpty {
                TextField("Search", text: $query).textFieldStyle(.plain)
                    .padding(.horizontal, 10).frame(width: 180, height: 28)
                    .background(RoundedRectangle(cornerRadius: Yap.Radius.control, style: .continuous).fill(Yap.recess))
                    .accessibilityLabel("Search projects")
                Picker("Sort", selection: $sort) { ForEach(ProjectSort.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.menu).labelsHidden().frame(width: 84).accessibilityLabel("Sort projects")
                    .help("Sort by date or name")
            }
            Button { model.scanMac() } label: { Image(systemName: "magnifyingglass.circle") }
                .buttonStyle(CircleButtonStyle(size: 28)).help("Find projects on this Mac").accessibilityLabel("Find projects on this Mac").disabled(model.scanning)
            Button { NSWorkspace.shared.open(AppSettings.shared.storageDirectory) } label: { Image(systemName: "folder") }
                .buttonStyle(CircleButtonStyle(size: 28)).help("Show the recordings folder in Finder").accessibilityLabel("Show folder in Finder")
            Button("Import Video…") { ProjectActions.importVideo() }
                .buttonStyle(CapsuleButtonStyle(.secondary, height: 30)).help("Edit an existing video")
            Button { PlaceCoordinator.shared.newRecording() } label: {
                HStack(spacing: 6) { Circle().fill(Yap.record).frame(width: 9, height: 9); Text("New Recording") }
            }
            .buttonStyle(CapsuleButtonStyle(.primary, height: 30)).help("Show the recording toolbar (⌘N)")
        }
        .padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 12)
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            if shown.isEmpty {
                Text("Nothing matches “\(query)”.").font(Yap.Font.body).foregroundStyle(Yap.caption).frame(maxWidth: .infinity).padding(40)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 14)], spacing: 14) {
                    ForEach(shown) { p in
                        Card(entry: p, thumbnail: model.thumbnails[p.url], duration: model.durations[p.url], selected: selection == p.url,
                             select: { selection = p.url }, open: { open(p) }, model: model)
                            .onAppear { model.loadThumbnail(p) }
                    }
                }
                .padding(16)
            }
        }
        .focusable()
        .onKeyPress(.return) {
            guard let sel = selection, let p = shown.first(where: { $0.url == sel }) else { return .ignored }
            open(p); return .handled
        }
    }

    private func open(_ p: ProjectEntry) {
        guard p.available else { message = "“\(p.name)” can't be opened: it is not a complete Yapcam project."; return }
        message = nil
        RecordingController.shared.engine.openEditor(package: p.url)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack").font(.system(size: 34)).foregroundStyle(Yap.faint)
            Text("No projects yet").font(Yap.Font.title(16)).foregroundStyle(Yap.title)
            Text("Record your screen, or bring in a video to edit. Projects are saved in \((AppSettings.shared.storageDirectory.path as NSString).abbreviatingWithTildeInPath).")
                .font(Yap.Font.body).foregroundStyle(Yap.caption).multilineTextAlignment(.center).frame(maxWidth: 380)
            HStack(spacing: 8) {
                Button("Import Video…") { ProjectActions.importVideo() }.buttonStyle(CapsuleButtonStyle(.secondary, height: 30))
                Button { PlaceCoordinator.shared.newRecording() } label: {
                    HStack(spacing: 6) { Circle().fill(Yap.record).frame(width: 9, height: 9); Text("New Recording") }
                }.buttonStyle(CapsuleButtonStyle(.primary, height: 30))
            }.padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var macSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(Yap.hairline).frame(height: 1)
            Text("On your Mac").font(Yap.Font.label).foregroundStyle(Yap.title).padding(.top, 8)
            ForEach(model.onThisMac.prefix(20)) { p in
                HStack {
                    Text(p.name).lineLimit(1)
                    Text((p.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath).font(Yap.Font.caption).foregroundStyle(Yap.caption).lineLimit(1)
                    Spacer()
                    Button("Open") { open(p) }
                    Button("Show") { FinderReveal.show(p.url) }
                }.controlSize(.small)
            }
        }.padding(.horizontal, 16).padding(.bottom, 10).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var interruptedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(model.interrupted.count) interrupted recording\(model.interrupted.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(Yap.Font.label)
            Text("Yapcam stopped before these were finished. Recover keeps everything that was written to disk.")
                .font(Yap.Font.caption).foregroundStyle(Yap.caption)
            ForEach(model.interrupted, id: \.self) { u in
                HStack {
                    Text(u.deletingPathExtension().lastPathComponent).lineLimit(1)
                    Spacer()
                    Button("Recover") { recover(u) }
                    Button("Show") { FinderReveal.show(u) }
                }.controlSize(.small)
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

    // MARK: Card

    private struct Card: View {
        let entry: ProjectEntry
        let thumbnail: NSImage?
        let duration: TimeInterval?
        let selected: Bool
        let select: () -> Void
        let open: () -> Void
        let model: ProjectsModel
        @State private var hover = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: Yap.Radius.control, style: .continuous).fill(Yap.recess)
                    if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFill() }
                    else { Image(systemName: entry.available ? "film" : "exclamationmark.triangle").font(.system(size: 22)).foregroundStyle(Yap.faint) }
                    if let text = ProjectsModel.durationText(duration) {
                        Text(text).font(Yap.Font.technical).foregroundStyle(Yap.technical)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.6))).padding(6)
                    }
                }
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Yap.Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(Yap.Font.label).foregroundStyle(Yap.title).lineLimit(1)
                    Text(entry.available ? entry.modified.formatted(date: .abbreviated, time: .shortened) : "Unavailable")
                        .font(Yap.Font.caption).foregroundStyle(entry.available ? Yap.caption : Color.orange)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: Yap.Radius.card, style: .continuous).fill(selected ? Yap.platter : hover ? Yap.platterHover : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Yap.Radius.card, style: .continuous).strokeBorder(selected ? Yap.hairline : Color.clear, lineWidth: 1))
            .opacity(entry.available ? 1 : 0.6)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(count: 2, perform: open)
            .onTapGesture(perform: select)
            .contextMenu {
                if entry.available { Button("Open", action: open) }
                Button("Show in Finder") { FinderReveal.show(entry.url) }
                if entry.available {
                    Button("Rename…") { model.rename(entry) }
                    Button("Duplicate") { model.duplicate(entry) }
                }
                Button("Remove from List") { model.removeFromRecents(entry) }
                if entry.available {
                    Button("Save As…") { ProjectActions.saveAs(entry.url) }
                    Button("Copy and Zip") { ProjectActions.copyAndZip(entry.url) }
                    Button("Extract Raw Files…") { model.extractRaw(entry) }
                }
                Divider()
                Button("Move to Trash", role: .destructive) { model.trash(entry) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(entry.available ? entry.name : "\(entry.name), unavailable")
            .accessibilityAddTraits(.isButton)
        }
    }
}
