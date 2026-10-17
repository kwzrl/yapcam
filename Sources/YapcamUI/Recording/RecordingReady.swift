import AppKit
import AVKit
import SwiftUI
import YapcamDesign

/// Shown when a recording stops: plays the take back and offers Edit (default, Return),
/// Show in Finder and Move to Trash. Esc closes and keeps the recording.
@MainActor final class RecordingReadyWindow: NSObject, NSWindowDelegate {
    static let shared = RecordingReadyWindow()
    private(set) var window: NSWindow?
    private var model: RecordingReadyModel?

    func show(package: URL, openEditor: @escaping (URL) -> Void) {
        close()
        let model = RecordingReadyModel(package: package)
        self.model = model
        let view = RecordingReadyView(model: model,
                                      edit: { [weak self] in self?.close(); openEditor(package) },
                                      reveal: { [weak self] in self?.close(); NSWorkspace.shared.activateFileViewerSelecting([package]) },
                                      trash: { [weak self] in self?.close(); NSWorkspace.shared.recycle([package]) },
                                      dismiss: { [weak self] in self?.close() })
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 470),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Recording Ready"
        w.titleVisibility = .hidden
        w.applyYapChrome()
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        let host = NSHostingView(rootView: view.yapWindow())
        w.contentView = host
        w.setContentSize(host.fittingSize)
        w.center()
        RecordingController.shared.engine.registerExcluded(w)
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        model.player.play()
    }

    func close() {
        model?.player.pause()
        window?.orderOut(nil)
        window = nil
        model = nil
    }

    func windowWillClose(_ notification: Notification) { model?.player.pause(); model = nil; window = nil }
}

@MainActor final class RecordingReadyModel: ObservableObject {
    let package: URL
    let player = AVPlayer()
    @Published private(set) var duration: Double = 0
    @Published private(set) var bytes: Int64 = 0
    var name: String { package.deletingPathExtension().lastPathComponent }

    init(package: URL) {
        self.package = package
        player.isMuted = true
        player.actionAtItemEnd = .none
        Task { await load() }
    }

    /// Chains every segment's screen.mov (one per pause) into a single muted preview.
    private func load() async {
        let rec = package.appending(path: "recording")
        let segs = ((try? FileManager.default.contentsOfDirectory(at: rec, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("seg-") }.sorted { $0.path < $1.path }
        let comp = AVMutableComposition()
        for seg in segs {
            let asset = AVURLAsset(url: seg.appending(path: "screen.mov"))
            guard let d = try? await asset.load(.duration) else { continue }
            try? await comp.insertTimeRange(CMTimeRange(start: .zero, duration: d), of: asset, at: comp.duration)
        }
        duration = comp.duration.seconds.isFinite ? comp.duration.seconds : 0
        bytes = RecordingReadyModel.size(of: package)
        player.replaceCurrentItem(with: AVPlayerItem(asset: comp))
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.player.seek(to: .zero); self?.player.play() }
        }
        player.play()
    }

    private static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}

struct RecordingReadyView: View {
    @ObservedObject var model: RecordingReadyModel
    let edit: () -> Void, reveal: () -> Void, trash: () -> Void, dismiss: () -> Void

    private var meta: String {
        let t = Int(model.duration.rounded())
        let size = ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)
        return String(format: "%d:%02d", t / 60, t % 60) + "  ·  " + size
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PlayerSurface(player: model.player)
                .frame(width: 560, height: 350)
                .background(Yap.surface)
                .clipShape(RoundedRectangle(cornerRadius: Yap.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Yap.Radius.card, style: .continuous).strokeBorder(Yap.hairline))
                .accessibilityLabel("Preview of the recording")

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Yap.text).lineLimit(1).truncationMode(.middle)
                    Text(meta).font(.system(size: 12).monospacedDigit()).foregroundStyle(Yap.textSecondary)
                }
                Spacer(minLength: 12)
                IconButton(symbol: "trash", help: "Move to Trash", action: trash)
                IconButton(symbol: "folder", help: "Show in Finder", action: reveal)
                Button(action: edit) {
                    Text("Edit").font(.system(size: 13, weight: .semibold)).foregroundStyle(Yap.onAccent)
                        .padding(.horizontal, 22).frame(height: 32)
                        .background(Capsule().fill(Yap.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Opens the editor")
            }
            .frame(width: 560)
        }
        .padding(.horizontal, 20).padding(.top, 36).padding(.bottom, 20)
        .background(Yap.bg)
        .onExitCommand(perform: dismiss)
    }
}

private struct IconButton: View {
    let symbol: String, help: String, action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(hover ? Yap.text : Yap.textSecondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(hover ? Yap.raised : Yap.surface))
                .overlay(Circle().strokeBorder(Yap.hairline))
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(help).accessibilityLabel(help)
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = false
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}
