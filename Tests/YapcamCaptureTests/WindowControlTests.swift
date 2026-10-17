import Foundation
import Testing
@testable import YapcamCapture

@MainActor private final class ResizeFixture {
    var permission: PermissionState = .granted
    var actual = CGRect(x: -1300, y: -100, width: 800, height: 600)
    var requested: CGSize?
    var writable = true
    var applyAfterWait = true
    var reads = 0
    var writes = 0
    var waits = 0
    var copies = 1
    var duplicateTitle = "Document"
    var windowTitle = "Document"
    var services: WindowControlServices {
        WindowControlServices(permission: { self.permission }, target: { _ in
            WindowControlIdentity(pid: 77, frame: CGRect(x: -1300, y: -100, width: 800, height: 600), title: "Document")
        }, windows: { _ in
            (0..<self.copies).map { index in
                WindowControlHandle(frame: self.actual, title: index == 0 ? self.windowTitle : self.duplicateTitle,
                    resizable: self.writable, readFrame: { self.reads += 1; return self.actual },
                    setSize: { self.writes += 1; self.requested = $0 }, raise: {})
            }
        }, wait: {
            self.waits += 1
            if self.applyAfterWait, let requested = self.requested { self.actual.size = requested }
        })
    }
}

@Test @MainActor func exactWindowResizeWaitsForAppAndKeepsGlobalPointOrigin() async throws {
    let fixture = ResizeFixture()
    let result = try await CaptureWindowControl.resize(windowID: 1, to: CGSize(width: 1280, height: 720), services: fixture.services)
    #expect(result == CGRect(x: -1300, y: -100, width: 1280, height: 720))
    #expect(fixture.writes == 1 && fixture.waits == 1 && fixture.reads == 2)
}

@Test @MainActor func clampedWindowResizeReportsActualSizeRatherThanFalseSuccess() async throws {
    let fixture = ResizeFixture(); fixture.applyAfterWait = false
    await #expect(throws: CaptureWindowControlError.sizeNotApplied(requested: CGSize(width: 640, height: 480), actual: fixture.actual.size)) {
        try await CaptureWindowControl.resize(windowID: 1, to: CGSize(width: 640, height: 480), services: fixture.services)
    }
    #expect(fixture.waits == 10 && fixture.writes == 1)
}

@Test @MainActor func resizePermissionAndAmbiguityNeverModifyOtherWindow() async throws {
    let fixture = ResizeFixture(); fixture.permission = .denied
    await #expect(throws: CaptureError.permissionDenied(.accessibility)) {
        try await CaptureWindowControl.resize(windowID: 1, to: CGSize(width: 640, height: 480), services: fixture.services)
    }
    #expect(fixture.writes == 0)
    fixture.permission = .granted; fixture.copies = 2
    await #expect(throws: CaptureWindowControlError.ambiguousWindow) {
        try await CaptureWindowControl.resize(windowID: 1, to: CGSize(width: 640, height: 480), services: fixture.services)
    }
    #expect(fixture.writes == 0)
    fixture.duplicateTitle = "Different document"
    _ = try await CaptureWindowControl.resize(windowID: 1, to: CGSize(width: 640, height: 480), services: fixture.services)
    #expect(fixture.writes == 1)
}

@Test @MainActor func invalidOrFixedSizeWindowsAreNotModified() async throws {
    let fixture = ResizeFixture(); fixture.writable = false
    await #expect(throws: CaptureWindowControlError.notResizable) {
        try await CaptureWindowControl.resize(windowID: 1, to: CGSize(width: 640, height: 480), services: fixture.services)
    }
    for size in [CGSize.zero, CGSize(width: CGFloat.nan, height: 500), CGSize(width: 500, height: 32769)] {
        await #expect(throws: CaptureWindowControlError.invalidSize) {
            try await CaptureWindowControl.resize(windowID: 1, to: size, services: fixture.services)
        }
    }
    #expect(fixture.writes == 0)
}

@Test @MainActor func mismatchedDocumentTitleNeverResizesAnotherWindowAtSameBounds() async throws {
    let fixture = ResizeFixture(); fixture.windowTitle = "Another document"
    await #expect(throws: CaptureError.sourceUnavailable) {
        try await CaptureWindowControl.resize(windowID: 1, to: CGSize(width: 640, height: 480), services: fixture.services)
    }
    #expect(fixture.writes == 0)
}

@Test func pickerExcludesOwnAndSystemSurfacesButKeepsFinderDocuments() {
    let frame = CGRect(x: -100, y: 0, width: 800, height: 600)
    func pick(_ bundle: String?, pid: Int32? = 10, layer: Int = 0) -> Bool {
        CaptureWindowPolicy.isPickable(pid: pid, bundleID: bundle, layer: layer, frame: frame, ownPID: 42, ownBundleID: "mov.yapcam.Yapcam")
    }
    #expect(pick("com.apple.finder"))
    #expect(pick("com.apple.TextEdit"))
    #expect(!pick("mov.yapcam.Yapcam", pid: 43))
    #expect(!pick("test", pid: 42))
    #expect(!pick("com.apple.controlcenter"))
    #expect(!pick("com.apple.dock"))
    #expect(!pick(nil, pid: nil))
    #expect(!pick("com.apple.finder", layer: -1000))
}

@Test func exactWindowPresetsAreFilteredRatherThanScaledAndKeepGroupOrder() {
    let choices = CaptureWindowSizePreset.fitting(in: CGSize(width: 1680, height: 1050))
    #expect(choices.first?.size == CGSize(width: 1280, height: 720))
    #expect(!choices.contains { $0.size == CGSize(width: 1920, height: 1080) })
    #expect(!choices.contains { $0.group == .portrait })
    #expect(choices.contains { $0.group == .wide && $0.size == CGSize(width: 1680, height: 1050) })
    #expect(Set(choices.map(\.id)).count == choices.count)
    #expect(CaptureWindowSizePreset.fitting(in: .zero).isEmpty)
    #expect(CaptureWindowSizePreset.fitting(in: CGSize(width: CGFloat.infinity, height: 1000)).isEmpty)
}

@Test(arguments: [CGFloat(1), CGFloat(2)]) func areaMinimumUsesLogicalPointsAtBothScales(_ scale: CGFloat) throws {
    let bounds = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
    for size in [CGSize(width: 149, height: 150), CGSize(width: 150, height: 149), CGSize(width: 75, height: 75)] {
        #expect(throws: CaptureError.sourceUnavailable) {
            try CaptureGeometry.area(displayBounds: bounds, localRect: CGRect(origin: .zero, size: size), scale: scale)
        }
    }
    let geometry = try CaptureGeometry.area(displayBounds: bounds, localRect: CGRect(x: 10, y: 20, width: 150, height: 150), scale: scale)
    #expect(geometry.pixelWidth == Int(150 * scale) && geometry.rect.minX == -1910)
}
