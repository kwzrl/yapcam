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
