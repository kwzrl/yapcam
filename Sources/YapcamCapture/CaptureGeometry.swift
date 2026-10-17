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
        // NV12/HEVC capture uses even dimensions. Choose that surface before
        // configuring SCStream and persisting pixel_size, so the manifest cannot
        // retain an odd request that ScreenCaptureKit silently rounds down.
        // Logical points stay unchanged for selection and cursor coordinates.
        pixelWidth = max(2, Int(rect.width * scale) / 2 * 2)
        pixelHeight = max(2, Int(rect.height * scale) / 2 * 2)
    }
    func local(_ global: CGPoint) -> CGPoint { CGPoint(x: global.x - rect.minX, y: global.y - rect.minY) }

    func sourceMetadata(kind: String, displayID: UInt32?, displayNames: [UInt32: String],
                        windowTitle: String? = nil, appBundleID: String? = nil) -> SourceMetadata {
        SourceMetadata(kind: kind, displayID: displayID,
            displayName: displayID.flatMap { displayNames[$0] } ?? "Display",
            contentRectPoints: [rect.minX, rect.minY, rect.width, rect.height], scale: scale,
            windowTitle: windowTitle, appBundleID: appBundleID)
    }

    /// UI selection is display-local points; persisted/input geometry is global
    /// top-left-origin points. Scale applies to output pixels, never the origin.
    static func area(displayBounds: CGRect, localRect: CGRect, scale: CGFloat) throws -> CaptureGeometry {
        guard !displayBounds.isNull, !displayBounds.isInfinite,
              displayBounds.origin.x.isFinite, displayBounds.origin.y.isFinite,
              displayBounds.width.isFinite, displayBounds.height.isFinite,
              displayBounds.width > 0, displayBounds.height > 0,
              localRect.origin.x.isFinite, localRect.origin.y.isFinite,
              localRect.width.isFinite, localRect.height.isFinite,
              localRect.width >= 150, localRect.height >= 150,
              CGRect(origin: .zero, size: displayBounds.size).contains(localRect) else {
            throw CaptureError.sourceUnavailable
        }
        return try CaptureGeometry(rect: localRect.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY), scale: scale)
    }
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
    let audioFilter: SCContentFilter?
    let configuration: SCStreamConfiguration
    let geometry: CaptureGeometry
    let source: SourceMetadata
    let maxFPS: Int

    static func resolve(_ options: RecordingOptions) async throws -> ResolvedCapture {
        _ = try CaptureFrameRatePolicy.resolve(maxFPS: options.maxFPS, refreshRate: 60)
        // Ordinary window capture does not require Accessibility. Raise only when
        // already authorized, then rediscover bounds after the target responds.
        if case .window(let id) = options.target, CapturePermissions.state(.accessibility) == .granted {
            try? CaptureWindowControl.raise(windowID: id)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayNames = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (UInt32, String)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return (id, screen.localizedName)
        })
        let filter: SCContentFilter
        let geometry: CaptureGeometry
        let source: SourceMetadata
        var crop: CGRect?
        switch options.target {
        case .device:
            throw CaptureError.writerFailed("USB device capture uses AVFoundation, not ScreenCaptureKit")
        case .display(let id), .area(let id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.sourceUnavailable }
            let bounds = CGDisplayBounds(id)
            let scale = CGFloat(SCContentFilter(display: display, excludingWindows: []).pointPixelScale)
            let kind: String
            if case .area(_, let area) = options.target {
                geometry = try CaptureGeometry.area(displayBounds: bounds, localRect: area, scale: scale)
                crop = area
                kind = "area"
            } else {
                kind = "display"
                geometry = try CaptureGeometry(rect: bounds, scale: scale)
            }
            // Exclude the application as well as registered windows, so newly opened
            // Yapcam overlays cannot leak into an already-running display stream.
            filter = CaptureFilterPolicy(options: options).filter(display: display, content: content)
            source = geometry.sourceMetadata(kind: kind, displayID: id, displayNames: displayNames)
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
            source = geometry.sourceMetadata(kind: "window", displayID: display?.displayID, displayNames: displayNames,
                windowTitle: window.title, appBundleID: window.owningApplication?.bundleIdentifier)
        }
        let fps = try CaptureFrameRatePolicy.resolve(maxFPS: options.maxFPS,
            refreshRate: source.displayID.map { CaptureFrameRatePolicy.refreshRate(for: $0) } ?? 60)
        let config = SCStreamConfiguration()
        config.width = geometry.pixelWidth; config.height = geometry.pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = false
        config.capturesAudio = false // The independent audio stream owns the app selection.
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000; config.channelCount = 2
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.captureResolution = .best
        config.scalesToFit = true
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        if let crop { config.sourceRect = crop }
        let audioFilter: SCContentFilter?
        if options.systemAudio {
            guard let display = content.displays.first(where: { $0.displayID == source.displayID }) ?? content.displays.first else {
                throw CaptureError.sourceUnavailable
            }
            audioFilter = try SystemAudioPolicy.filter(selection: options.systemAudioSelection, display: display, content: content)
        } else { audioFilter = nil }
        return ResolvedCapture(filter: filter, audioFilter: audioFilter, configuration: config, geometry: geometry, source: source, maxFPS: fps)
    }
}

private extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }
