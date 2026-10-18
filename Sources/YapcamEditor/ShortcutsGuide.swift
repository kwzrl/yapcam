import AppKit
import SwiftUI
import YapcamDesign

/// Keyboard shortcuts guide (REC B-09), opened with ⌘/. Rebindable keys come from `EditorKeyBindings`; the rest are the fixed
/// bindings handled in `handleShortcut` and the menus.
public enum ShortcutsGuide {
    public struct Entry: Equatable, Identifiable, Sendable { public var title: String, keys: String; public var id: String { title } }
    public struct Category: Equatable, Identifiable, Sendable { public var title: String; public var entries: [Entry]; public var id: String { title } }

    public static func categories(bindings: EditorKeyBindings = .shared) -> [Category] {
        func key(_ id: String) -> String { String(bindings.key(for: id)).uppercased() }
        func e(_ t: String, _ k: String) -> Entry { Entry(title: t, keys: k) }
        func a(_ id: String) -> Entry { e(EditorKeyBindings.actions.first { $0.id == id }?.title ?? id, key(id)) }
        return [
            Category(title: "Playback", entries: [e("Play / pause", "Space"), a("shuttleBack"), a("shuttleStop"), a("shuttleForward"),
                                                  e("Next / previous edit point", "⌥→ / ⌥←")]),
            Category(title: "Editing", entries: [a("split"), a("ripple"), a("trimStart"), a("trimEnd"), a("speed"), a("volume"),
                                                 e("Delete selection", "⌫"), e("Cut selection", "⌘X"), e("Copy item settings", "⌘C"),
                                                 e("Paste item settings", "⌘V"), e("Undo / redo", "⌘Z / ⇧⌘Z"),
                                                 e("Move selection by 0.1 s", "⌃← / ⌃→")]),
            Category(title: "Zoom", entries: [a("addZoom"), a("zoomAuto"), a("zoomManual"), a("zoomToggle"), e("Duplicate zoom", "⌘D"),
                                              e("Zoom level 1–9", "1 … 9"), e("Default zoom level", "0"), e("Level up / down", "= / −")]),
            Category(title: "Timeline", entries: [e("Zoom timeline in / out", "⌘= / ⌘−"), e("Fit timeline", "⇧Z"),
                                                  e("Select next / previous item", "↓ / ↑")]),
            Category(title: "Inspector and panels", entries: [e("Open an inspector section", "⌘1 … ⌘0"), e("Command palette", "⌘K"),
                                                              e("This guide", "⌘/")]),
            Category(title: "Export", entries: [e("Export…", "⇧⌘E"), e("Save to file", "⌥⌘S"), e("Copy to clipboard", "⌥⌘C"),
                                                e("Copy current frame", "⇧⌘C")]),
        ]
    }

    @MainActor private static var panel: NSPanel?

    /// Shows (or brings forward) the guide window.
    @MainActor public static func show() {
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560), styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = "Keyboard Shortcuts"
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: ShortcutsGuideView())
        p.center()
        panel = p
        p.makeKeyAndOrderFront(nil)
    }
}

struct ShortcutsGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(ShortcutsGuide.categories()) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(c.title).font(Yap.Font.label).foregroundStyle(Yap.title)
                        ForEach(c.entries) { e in
                            HStack {
                                Text(e.title).font(Yap.Font.body).foregroundStyle(Yap.label)
                                Spacer(minLength: 12)
                                Text(e.keys).technical()
                            }
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 460, minHeight: 360)
    }
}
