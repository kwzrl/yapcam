import AppKit
import ScreenCaptureKit

extension CaptureSources {
    /// Refresh a visible picker thumbnail without rediscovering every device.
    public static func thumbnail(for windowID: CGWindowID, maxSize: CGSize = CGSize(width: 320, height: 200)) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.sourceUnavailable }
        return try await CaptureThumbnails.image(window, maxSize: maxSize)
    }
}

enum CaptureThumbnails {
    // SCWindow is an immutable framework discovery snapshot (all its properties
    // are readonly). Sharing it for screenshots does not mutate the source list.
    private struct WindowSnapshot: @unchecked Sendable { let window: SCWindow }

    static func pixelSize(for content: CGSize, maximum: CGSize) throws -> CGSize {
        guard content.width.isFinite, content.height.isFinite, content.width > 0, content.height > 0,
              maximum.width.isFinite, maximum.height.isFinite,
              maximum.width >= 1, maximum.height >= 1, maximum.width <= 4096, maximum.height <= 4096 else {
            throw CaptureError.sourceUnavailable
        }
        let scale = min(1, maximum.width / content.width, maximum.height / content.height)
        return CGSize(width: max(1, (content.width * scale).rounded(.down)),
                      height: max(1, (content.height * scale).rounded(.down)))
    }

    static func image(_ window: SCWindow, maxSize: CGSize = CGSize(width: 320, height: 200)) async throws -> CGImage {
        try Task.checkCancellation()
        let size = try pixelSize(for: window.frame.size, maximum: maxSize)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width); configuration.height = Int(size.height)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.scalesToFit = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        try Task.checkCancellation()
        return image
    }

    static func sources(_ windows: [SCWindow], includeImages: Bool) async throws -> [WindowSource] {
        var images: [CGWindowID: CGImage] = [:]
        if includeImages {
            // Four in flight keeps source pickers responsive without opening a
            // screenshot request for every window at the same time.
            images = await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                var next = 0
                var images: [CGWindowID: CGImage] = [:]
                func addNext() {
                    guard next < windows.count, !Task.isCancelled else { return }
                    let snapshot = WindowSnapshot(window: windows[next]); next += 1
                    group.addTask { (snapshot.window.windowID, try? await image(snapshot.window)) }
                }
                for _ in 0..<min(4, windows.count) { addNext() }
                while let (id, image) = await group.next() {
                    if let image { images[id] = image }
                    addNext()
                }
                return images
            }
        }
        try Task.checkCancellation()
        // A window closing during discovery has a nil thumbnail; it must not make
        // the entire display/device picker fail.
        return windows.map {
            WindowSource(id: $0.windowID, title: $0.title ?? "", appName: $0.owningApplication?.applicationName ?? "",
                         bundleID: $0.owningApplication?.bundleIdentifier, frame: $0.frame, thumbnail: images[$0.windowID])
        }
    }
}
