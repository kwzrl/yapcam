import AppKit
import ScreenCaptureKit

struct CaptureGeometry: Sendable {
    let rect: CGRect
    let scale: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int

    init(rect: CGRect, scale: CGFloat) throws {
        guard !rect.isNull, !rect.isInfinite, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width >= 2, rect.height >= 2, scale.isFinite, scale > 0,
              rect.width * scale <= 32768, rect.height * scale <= 32768 else {
            throw CaptureError.sourceUnavailable
        }
        self.rect = rect; self.scale = scale
        pixelWidth = max(2, Int((rect.width * scale).rounded()))
        pixelHeight = max(2, Int((rect.height * scale).rounded()))
    }
    func local(_ global: CGPoint) -> CGPoint { CGPoint(x: global.x - rect.minX, y: global.y - rect.minY) }
}

/// Maps global points into the logical coordinate system of the fixed video
/// surface, including letterboxing when a captured window changes size.
struct CaptureCoordinateMapping: Sendable {
    var source: CGRect
    var destination: CGRect
    var cursorScale: CGFloat { destination.width / source.width }
    func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: destination.minX + (point.x - source.minX) * destination.width / source.width,
                y: destination.minY + (point.y - source.minY) * destination.height / source.height)
    }
    static func fitted(source: CGRect, outputSize: CGSize) -> CaptureCoordinateMapping {
        let scale = min(outputSize.width / source.width, outputSize.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CaptureCoordinateMapping(source: source, destination: CGRect(
            x: (outputSize.width - size.width) / 2, y: (outputSize.height - size.height) / 2,
            width: size.width, height: size.height))
    }
}

@MainActor struct ResolvedCapture {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    let geometry: CaptureGeometry
    let source: SourceMetadata

    static func resolve(_ options: RecordingOptions) async throws -> ResolvedCapture {
        guard options.maxFPS == 30 || options.maxFPS == 60 else { throw CaptureError.writerFailed("Frame rate must be 30 or 60") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let geometry: CaptureGeometry
        let source: SourceMetadata
        var crop: CGRect?
        switch options.target {
        case .display(let id), .area(let id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.sourceUnavailable }
            let bounds = CGDisplayBounds(id)
            let scale = CGFloat(SCContentFilter(display: display, excludingWindows: []).pointPixelScale)
            var rect = bounds
            let kind: String
            if case .area(_, let area) = options.target {
                guard area.origin.x.isFinite, area.origin.y.isFinite, area.width.isFinite, area.height.isFinite,
                      area.width > 0, area.height > 0,
                      CGRect(origin: .zero, size: bounds.size).contains(area) else { throw CaptureError.sourceUnavailable }
                crop = area
                rect = area.offsetBy(dx: bounds.minX, dy: bounds.minY)
                kind = "area"
            } else { kind = "display" }
            geometry = try CaptureGeometry(rect: rect, scale: scale)
            // Exclude the application as well as registered windows, so newly opened
            // Yapcam overlays cannot leak into an already-running display stream.
            if options.excludeYapcamWindows {
                let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            } else { filter = SCContentFilter(display: display, excludingWindows: []) }
            let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == id }?.localizedName ?? "Display"
            source = SourceMetadata(kind: kind, displayID: id, displayName: name,
                contentRectPoints: [rect.minX, rect.minY, rect.width, rect.height], scale: scale)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }),
                  !options.excludeYapcamWindows || (window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
                      && !CaptureExclusions.windowNumbers.contains(Int(id))) else { throw CaptureError.sourceUnavailable }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            geometry = try CaptureGeometry(rect: window.frame, scale: scale)
            let display = content.displays.max { a, b in
                a.frame.intersection(window.frame).area < b.frame.intersection(window.frame).area
            }
            source = SourceMetadata(kind: "window", displayID: display?.displayID,
                contentRectPoints: [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height], scale: scale,
                windowTitle: window.title, appBundleID: window.owningApplication?.bundleIdentifier)
        }
        let config = SCStreamConfiguration()
        config.width = geometry.pixelWidth; config.height = geometry.pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.maxFPS))
        config.showsCursor = false
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000; config.channelCount = 2
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.captureResolution = .best
        config.scalesToFit = true
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        if let crop { config.sourceRect = crop }
        return ResolvedCapture(filter: filter, configuration: config, geometry: geometry, source: source)
    }
}

private extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }
