import Foundation
import Testing
@testable import YapcamCapture

private let selfTestSources = CaptureSources(
    displays: [DisplaySource(id: 7, name: "Left", frame: CGRect(x: -1680, y: 0, width: 1680, height: 1050),
                             scale: 2, pixelSize: CGSize(width: 3360, height: 2100))],
    windows: [WindowSource(id: 42, title: "Test", appName: "TextEdit", bundleID: "com.apple.TextEdit",
                           frame: CGRect(x: -1500, y: 20, width: 800, height: 600), thumbnail: nil)],
    cameras: [], microphones: [])

@Test func selfTestEnvironmentChoosesAreaWindowCadenceAndPause() throws {
    let defaults = try CaptureSelfTestOverrides(environment: [:], sources: selfTestSources, seconds: 6)
    #expect(defaults.target == nil && defaults.maxFPS == nil && defaults.pauseAfter == nil)
    let area = try CaptureSelfTestOverrides(environment: [
        "YAPCAM_CAPTURE_SELFTEST_TARGET": "area:100,100,800,600",
        "YAPCAM_CAPTURE_SELFTEST_FPS": "30",
        "YAPCAM_CAPTURE_SELFTEST_PAUSE_AFTER": "2"
    ], sources: selfTestSources, seconds: 6)
    #expect(area.target == .area(display: 7, rect: CGRect(x: 100, y: 100, width: 800, height: 600)))
    #expect(area.maxFPS == 30 && area.pauseAfter == 2)
    for selector in ["window:42", "window:com.apple.TextEdit"] {
        let window = try CaptureSelfTestOverrides(environment: ["YAPCAM_CAPTURE_SELFTEST_TARGET": selector],
                                                 sources: selfTestSources, seconds: 6)
        #expect(window.target == .window(42))
    }
}

@Test(arguments: [
    ["YAPCAM_CAPTURE_SELFTEST_TARGET": "window:999"],
    ["YAPCAM_CAPTURE_SELFTEST_TARGET": "area:100,100,800,"],
    ["YAPCAM_CAPTURE_SELFTEST_TARGET": "area:nan,0,800,600"],
    ["YAPCAM_CAPTURE_SELFTEST_TARGET": "area:-1,0,800,600"],
    ["YAPCAM_CAPTURE_SELFTEST_TARGET": "area:100,100,1800,600"],
    ["YAPCAM_CAPTURE_SELFTEST_TARGET": "unknown"],
    ["YAPCAM_CAPTURE_SELFTEST_FPS": "120"],
    ["YAPCAM_CAPTURE_SELFTEST_PAUSE_AFTER": "nan"],
    ["YAPCAM_CAPTURE_SELFTEST_PAUSE_AFTER": "0"],
    ["YAPCAM_CAPTURE_SELFTEST_PAUSE_AFTER": "6"]
]) func selfTestRejectsInvalidEnvironment(environment: [String: String]) {
    #expect(throws: CaptureError.self) {
        _ = try CaptureSelfTestOverrides(environment: environment, sources: selfTestSources, seconds: 6)
    }
}

@Test func selfTestAudioCameraAndMarkerOverrides() throws {
    let values = try CaptureSelfTestOverrides(environment: [
        "YAPCAM_CAPTURE_SELFTEST_AUDIO": "apps:com.example.a,com.example.b",
        "YAPCAM_CAPTURE_SELFTEST_CAMERA_MAX": "2160", "YAPCAM_CAPTURE_SELFTEST_CAMERA_ID": "camera",
        "YAPCAM_CAPTURE_SELFTEST_MICROPHONE_ID": "mic", "YAPCAM_CAPTURE_SELFTEST_MARKERS": "1"
    ], sources: selfTestSources, seconds: 6)
    #expect(values.systemAudioSelection == .applications(bundleIDs: ["com.example.a", "com.example.b"]))
    #expect(values.cameraMaxResolution == .uhd4K && values.cameraID == "camera" && values.microphoneID == "mic")
    #expect(values.addMarkers == true)
    for (text, selection) in [("off", SystemAudioSelection.off), ("all", .allApplications)] {
        #expect(try CaptureSelfTestOverrides(environment: ["YAPCAM_CAPTURE_SELFTEST_AUDIO": text], sources: selfTestSources, seconds: 6).systemAudioSelection == selection)
    }
}

@Test(arguments: [
    ["YAPCAM_CAPTURE_SELFTEST_AUDIO": "apps:"],
    ["YAPCAM_CAPTURE_SELFTEST_AUDIO": "apps:a,,b"],
    ["YAPCAM_CAPTURE_SELFTEST_AUDIO": "apps: a"],
    ["YAPCAM_CAPTURE_SELFTEST_AUDIO": "none"],
    ["YAPCAM_CAPTURE_SELFTEST_CAMERA_MAX": "4096"],
    ["YAPCAM_CAPTURE_SELFTEST_CAMERA_ID": ""],
    ["YAPCAM_CAPTURE_SELFTEST_MICROPHONE_ID": ""],
    ["YAPCAM_CAPTURE_SELFTEST_MARKERS": "yes"]
]) func selfTestRejectsInvalidAudioCameraOverrides(environment: [String: String]) {
    #expect(throws: CaptureError.self) { _ = try CaptureSelfTestOverrides(environment: environment, sources: selfTestSources, seconds: 6) }
}
