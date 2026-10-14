import CoreGraphics
import ScreenCaptureKit

/// Desktop appearance is changed in the recording filter only. No Finder defaults
/// or desktop preferences are modified, so stop/cancel/crash needs no restoration.
struct CaptureFilterPolicy {
    let options: RecordingOptions
    let ownProcessID: Int32

    init(options: RecordingOptions, ownProcessID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.options = options; self.ownProcessID = ownProcessID
    }

    func excludesApplication(bundleID: String?, processID: Int32) -> Bool {
        (options.excludeYapcamWindows && processID == ownProcessID)
        || (options.hideDesktopIcons && bundleID == "com.apple.finder")
        || (!options.captureNotifications && bundleID == "com.apple.notificationcenterui")
    }

    func keepsWindow(bundleID: String?, processID: Int32, layer: Int) -> Bool {
        // The Finder owns desktop icons and folder windows. Retain ordinary
        // Finder windows as exceptions to excluding its desktop surfaces.
        guard options.hideDesktopIcons, bundleID == "com.apple.finder",
              !(options.excludeYapcamWindows && processID == ownProcessID) else { return false }
        return layer >= Int(CGWindowLevelForKey(.normalWindow))
    }

    func filter(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let excluded = content.applications.filter {
            excludesApplication(bundleID: $0.bundleIdentifier, processID: $0.processID)
        }
        let exceptions = content.windows.filter {
            guard let app = $0.owningApplication else { return false }
            return keepsWindow(bundleID: app.bundleIdentifier, processID: app.processID, layer: $0.windowLayer)
        }
        return SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: exceptions)
    }
}
