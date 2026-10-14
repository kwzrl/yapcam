import AppKit
import ScreenCaptureKit

struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let appName: String
    let frame: CGRect
    var displayTitle: String { title.isEmpty ? appName : title }
}

/// Lists recordable windows (UI-local, via ScreenCaptureKit) and loads thumbnails lazily.
@MainActor final class WindowList: ObservableObject {
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var scWindows: [CGWindowID: SCWindow] = [:]
    private var requested = Set<CGWindowID>()

    func reload() async {
        guard CGPreflightScreenCaptureAccess() else { error = "Screen recording permission is needed to list windows."; return }
        loading = true; defer { loading = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let own = Bundle.main.bundleIdentifier
            let list = content.windows.filter {
                $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width >= 80 && $0.frame.height >= 60
                    && $0.owningApplication?.bundleIdentifier != own && $0.owningApplication != nil
            }
            scWindows = Dictionary(uniqueKeysWithValues: list.map { ($0.windowID, $0) })
            windows = list.map {
                WindowInfo(id: $0.windowID, title: $0.title ?? "", appName: $0.owningApplication?.applicationName ?? "App", frame: $0.frame)
            }
            error = windows.isEmpty ? "No windows available to record." : nil
        } catch {
            self.error = "Could not list windows: \(error.localizedDescription)"
        }
    }

    func loadThumbnail(for id: CGWindowID) {
        guard !requested.contains(id), let w = scWindows[id] else { return }
        requested.insert(id)
        Task {
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let cfg = SCStreamConfiguration()
            let scale = min(1, 360 / max(w.frame.width, 1))
            cfg.width = max(1, Int(w.frame.width * scale)); cfg.height = max(1, Int(w.frame.height * scale))
            cfg.showsCursor = false
            if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) {
                thumbnails[id] = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            }
        }
    }
}
