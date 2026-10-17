@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// Extract Raw Recording Files…: one file per recorded track, in a "<project> raw" folder. Segments of a paused
/// recording are joined without re-encoding; a single segment is copied as is.
enum RawExtract {
    struct Track: Equatable { let outputName: String; let sources: [URL] }

    static let trackFiles: [(file: String, out: String)] = [
        ("screen.mov", "Screen.mov"), ("camera.mov", "Camera.mov"), ("mic.m4a", "Microphone.m4a"), ("system.m4a", "System audio.m4a"),
    ]

    /// Which files make up each track, segments in order. Missing tracks are left out; `screenOnly` keeps just the screen.
    static func plan(package: URL, screenOnly: Bool = false) -> [Track] {
        let rec = package.appending(path: "recording")
        let segments = ((try? FileManager.default.contentsOfDirectory(at: rec, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("seg-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return trackFiles.filter { !screenOnly || $0.file == "screen.mov" }.compactMap { t in
            let sources = segments.map { $0.appending(path: t.file) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            return sources.isEmpty ? nil : Track(outputName: t.out, sources: sources)
        }
    }

    enum ExtractError: LocalizedError {
        case nothingToExtract, cancelled
        var errorDescription: String? {
            switch self {
            case .nothingToExtract: "This recording has no raw media to extract."
            case .cancelled: "Extraction cancelled."
            }
        }
    }

    /// Writes every track into `folder` (created). Off the main thread; throws `.cancelled` when `isCancelled` turns true.
    static func run(_ tracks: [Track], into folder: URL, isCancelled: @Sendable () -> Bool = { false }) async throws {
        guard !tracks.isEmpty else { throw ExtractError.nothingToExtract }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for t in tracks {
            if isCancelled() { throw ExtractError.cancelled }
            let dest = folder.appending(path: t.outputName)
            if t.sources.count == 1 { try FileManager.default.copyItem(at: t.sources[0], to: dest); continue }
            try await join(t.sources, to: dest)
        }
    }

    /// Passthrough join: the samples are copied, never re-encoded.
    static func join(_ sources: [URL], to dest: URL) async throws {
        let comp = AVMutableComposition()
        var cursor = CMTime.zero
        for url in sources {
            let asset = AVURLAsset(url: url)
            let dur = try await asset.load(.duration)
            for type in [AVMediaType.video, .audio] {
                for src in try await asset.loadTracks(withMediaType: type) {
                    let dst = comp.tracks(withMediaType: type).first ?? comp.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
                    try dst?.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: cursor)
                }
            }
            cursor = cursor + dur
        }
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw ExtractError.nothingToExtract }
        try await session.export(to: dest, as: dest.pathExtension == "m4a" ? .m4a : .mov)
    }
}

/// A small floating panel with a spinner and Cancel while the extraction runs.
@MainActor final class RawExtractRunner: ObservableObject {
    static let shared = RawExtractRunner()
    @Published var message = ""
    private var panel: NSPanel?
    private var task: Task<Void, Never>?
    private var cancelled = false

    func start(package: URL, screenOnly: Bool) {
        guard task == nil else { return }
        let tracks = RawExtract.plan(package: package, screenOnly: screenOnly)
        guard !tracks.isEmpty else {
            RecordingController.shared.alert = AppAlert(title: "Nothing to extract", message: RawExtract.ExtractError.nothingToExtract.localizedDescription); return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.title = "Select a folder for the raw recording files"; panel.prompt = "Extract"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let name = package.deletingPathExtension().lastPathComponent + (screenOnly ? " screen" : " raw")
        let dest = ProjectActions.uniqueFolderForExtract(in: parent, name: name)
        cancelled = false; message = "Extracting \(tracks.count) file\(tracks.count == 1 ? "" : "s")…"
        showPanel()
        task = Task { [weak self] in
            do {
                try await RawExtract.run(tracks, into: dest, isCancelled: { [weak self] in MainActor.assumeIsolated { self?.cancelled ?? true } })
                self?.finish(); FinderReveal.show(dest)
            } catch {
                try? FileManager.default.removeItem(at: dest)
                self?.finish()
                if (error as? RawExtract.ExtractError) != .cancelled { RecordingController.shared.alert = AppAlert(title: "Could not extract", error: error) }
            }
        }
    }

    func cancel() { cancelled = true }
    private func finish() { task = nil; self.panel?.orderOut(nil); self.panel = nil }

    private func showPanel() {
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 110), styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        p.title = "Extract"; p.level = .floating; p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: ExtractProgressView(runner: self))
        p.center(); p.makeKeyAndOrderFront(nil)
        panel = p
    }
}

private struct ExtractProgressView: View {
    @ObservedObject var runner: RawExtractRunner
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(runner.message).font(.callout)
            Button("Cancel") { runner.cancel() }
        }.padding(16).frame(width: 320)
    }
}
