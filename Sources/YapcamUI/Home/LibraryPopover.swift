import AppKit
import SwiftUI
import YapcamDesign

/// The toolbar's Library button: recent recordings with search, each one a click away from the editor.
struct RecentsPopover: View {
    let dismiss: () -> Void
    @ObservedObject var model = ProjectsModel.shared
    @State private var query = ""
    private var shown: [ProjectEntry] {
        let all = query.isEmpty ? model.projects : model.projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return Array(all.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PopoverHeader(title: "Library")
            TextField("Search", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("Search recordings")
            if shown.isEmpty {
                Text(model.projects.isEmpty ? "No recordings yet." : "Nothing matches.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(spacing: 2) {
                    ForEach(shown) { p in
                        LibraryRow(entry: p, thumbnail: model.thumbnails[p.url],
                                   edit: { RecordingController.shared.engine.openEditor(package: p.url); dismiss() },
                                   remove: { model.removeFromRecents(p) })
                            .onAppear { model.loadThumbnail(p) }
                    }
                }
            }
            Divider()
            HStack {
                Button("All Projects…") { HomeWindow.shared.show(); dismiss() }
                Spacer()
                Button("Show Folder") {
                    try? FileManager.default.createDirectory(at: AppSettings.shared.storageDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AppSettings.shared.storageDirectory); dismiss()
                }
            }.controlSize(.small)
        }
        .padding(14).frame(width: 320)
        .onAppear { model.reload() }
    }
}

/// One recording in the Library popover: first frame, name, date and Edit. Double-click edits too;
/// the rest lives in the context menu.
private struct LibraryRow: View {
    let entry: ProjectEntry
    let thumbnail: NSImage?
    let edit: () -> Void
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        let thumb = RoundedRectangle(cornerRadius: 5, style: .continuous)
        HStack(spacing: 10) {
            ZStack {
                thumb.fill(Color.white.opacity(0.06))
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFill() }
                else { Image(systemName: "film").foregroundStyle(.tertiary) }
            }
            .frame(width: 56, height: 35).clipShape(thumb)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(entry.modified.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button("Edit", action: edit).buttonStyle(CapsuleButtonStyle(.secondary, height: 24))
                .accessibilityLabel("Edit \(entry.name)")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hover ? 0.06 : 0)))
        .animation(hover ? .snappy(duration: 0.14) : .smooth(duration: 0.3), value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: edit)
        .contextMenu {
            Button("Edit", action: edit)
            Button("Show in Finder") { FinderReveal.show(entry.url) }
            Button("Remove from Library", action: remove)
        }
    }
}
