import CoreGraphics
import Foundation
import Testing
@testable import YapcamCapture

@Test func thumbnailBoundsPreserveAspectAndRejectInvalidSizes() throws {
    #expect(try CaptureThumbnails.pixelSize(for: CGSize(width: 1680, height: 1050), maximum: CGSize(width: 320, height: 200)) == CGSize(width: 320, height: 200))
    #expect(try CaptureThumbnails.pixelSize(for: CGSize(width: 400, height: 800), maximum: CGSize(width: 320, height: 200)) == CGSize(width: 100, height: 200))
    #expect(try CaptureThumbnails.pixelSize(for: CGSize(width: 100, height: 50), maximum: CGSize(width: 320, height: 200)) == CGSize(width: 100, height: 50))
    #expect(throws: CaptureError.self) { try CaptureThumbnails.pixelSize(for: .zero, maximum: CGSize(width: 320, height: 200)) }
    #expect(throws: CaptureError.self) { try CaptureThumbnails.pixelSize(for: CGSize(width: 800, height: 600), maximum: CGSize(width: CGFloat.infinity, height: 200)) }
}

@Test func newCaptureOptionsDecodeOlderPreferencesAndRoundTrip() throws {
    let options = RecordingOptions(target: .display(2), hideDesktopIcons: true, captureNotifications: false, outputDirectory: URL(fileURLWithPath: "/tmp"))
    let data = try JSONEncoder().encode(options)
    let roundTrip = try JSONDecoder().decode(RecordingOptions.self, from: data)
    #expect(roundTrip.hideDesktopIcons)
    #expect(!roundTrip.captureNotifications)
    var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    old.removeValue(forKey: "hideDesktopIcons"); old.removeValue(forKey: "captureNotifications")
    let decodedOld = try JSONDecoder().decode(RecordingOptions.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(!decodedOld.hideDesktopIcons)
    #expect(decodedOld.captureNotifications)
    #expect(decodedOld.excludeYapcamWindows)
    #expect(!decodedOld.recordKeystrokes)
}

@Test func desktopIconFilterKeepsFinderFoldersAndExcludesOnlyRequestedApps() {
    let options = RecordingOptions(target: .display(2), hideDesktopIcons: true, captureNotifications: false, outputDirectory: URL(fileURLWithPath: "/tmp"))
    let policy = CaptureFilterPolicy(options: options, ownProcessID: 100)
    #expect(policy.excludesApplication(bundleID: "mov.yapcam.Yapcam", processID: 100))
    #expect(policy.excludesApplication(bundleID: "com.apple.finder", processID: 200))
    #expect(policy.excludesApplication(bundleID: "com.apple.notificationcenterui", processID: 300))
    #expect(!policy.excludesApplication(bundleID: "com.apple.TextEdit", processID: 400))
    #expect(policy.keepsWindow(bundleID: "com.apple.finder", processID: 200, layer: Int(CGWindowLevelForKey(.normalWindow))))
    #expect(!policy.keepsWindow(bundleID: "com.apple.finder", processID: 200, layer: Int(CGWindowLevelForKey(.desktopIconWindow))))
    #expect(!policy.keepsWindow(bundleID: "mov.yapcam.Yapcam", processID: 100, layer: 0))
}

@Test func defaultCaptureAppearanceKeepsDesktopIconsAndNotifications() {
    let options = RecordingOptions(target: .display(2), outputDirectory: URL(fileURLWithPath: "/tmp"))
    let policy = CaptureFilterPolicy(options: options, ownProcessID: 100)
    #expect(!policy.excludesApplication(bundleID: "com.apple.finder", processID: 200))
    #expect(!policy.excludesApplication(bundleID: "com.apple.notificationcenterui", processID: 300))
    #expect(!policy.keepsWindow(bundleID: "com.apple.finder", processID: 200, layer: 0))
}
