import AppKit

/// Zero in RecordingOptions.maxFPS means follow the source display at start.
/// A positive value remains an explicit cap for legacy callers and diagnostics.
enum CaptureFrameRatePolicy {
    static func displayRate(reported: Double, maximum: Int) -> Double {
        if reported.isFinite, (1...1000).contains(reported) { return reported }
        return (1...1000).contains(maximum) ? Double(maximum) : 60
    }

    static func resolve(maxFPS: Int, refreshRate: Double) throws -> Int {
        guard (0...1000).contains(maxFPS) else { throw CaptureError.writerFailed("Frame rate must be automatic (0) or between 1 and 1000") }
        if maxFPS > 0 { return maxFPS }
        // 59.94/119.88 panels must not become 59/119 fps upper limits.
        return Int(displayRate(reported: refreshRate, maximum: 60).rounded(.up))
    }

    @MainActor static func refreshRate(for displayID: CGDirectDisplayID) -> Double {
        let maximum = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID
        }?.maximumFramesPerSecond ?? 60
        return displayRate(reported: CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0, maximum: maximum)
    }
}
