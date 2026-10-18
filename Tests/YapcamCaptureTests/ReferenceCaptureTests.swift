import Foundation
import ScreenCaptureKit
import Testing
@testable import YapcamCapture

@Test func audioOptionsDefaultOffAndMigrateExplicitLegacyValues() throws {
    var options = RecordingOptions(target: .display(1), outputDirectory: URL(fileURLWithPath: "/tmp"))
    #expect(!options.systemAudio && options.systemAudioSelection == .off)
    options.systemAudioSelection = .applications(bundleIDs: ["org.example.player"])
    options.systemAudio = true
    #expect(options.systemAudioSelection == .applications(bundleIDs: ["org.example.player"]))
    let data = try JSONEncoder().encode(options)
    #expect(try JSONDecoder().decode(RecordingOptions.self, from: data).systemAudioSelection == options.systemAudioSelection)
    var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    old.removeValue(forKey: "systemAudioSelection")
    #expect(try JSONDecoder().decode(RecordingOptions.self, from: JSONSerialization.data(withJSONObject: old)).systemAudioSelection == .allApplications)
    old["systemAudio"] = false
    #expect(try JSONDecoder().decode(RecordingOptions.self, from: JSONSerialization.data(withJSONObject: old)).systemAudioSelection == .off)
    options.systemAudio = false
    options.systemAudio = true
    #expect(options.systemAudioSelection == .allApplications)
}

@Test func audioChecklistNeverBroadensWhenEmptyOrApplicationMissing() throws {
    let available: Set<String> = ["a", "b", "c"]
    #expect(try SystemAudioPolicy.selectedBundleIDs(.off, available: available) == [])
    #expect(try SystemAudioPolicy.selectedBundleIDs(.allApplications, available: available) == nil)
    #expect(try SystemAudioPolicy.selectedBundleIDs(.applications(bundleIDs: ["b", "b", "a"]), available: available) == ["a", "b"])
    #expect(throws: CaptureError.self) { try SystemAudioPolicy.selectedBundleIDs(.applications(bundleIDs: []), available: available) }
    #expect(throws: CaptureError.self) { try SystemAudioPolicy.selectedBundleIDs(.applications(bundleIDs: ["missing", "a"]), available: available) }
    let apps = SystemAudioPolicy.applications([.init(bundleID: "b", name: "Beta"), .init(bundleID: "a", name: "Alpha"),
        .init(bundleID: "b", name: "Beta helper"), .init(bundleID: "own", name: "Yapcam"), .init(bundleID: "", name: "Unknown")], ownBundleID: "own")
    #expect(apps.map(\.bundleID) == ["a", "b"])
}

@MainActor private final class ControlledCaptureStream: CaptureSessionStream {
    var starts = 0
    var stops = 0
    var failStart = false
    var failStop = false
    func startCapture() async throws {
        starts += 1
        if failStart { throw CaptureError.sourceUnavailable }
    }
    func stopCapture() async throws {
        stops += 1
        if failStop { throw CaptureError.writerFailed("injected stop") }
    }
    func updateContentFilter(_ filter: SCContentFilter) async throws {}
}

@Test @MainActor func independentAudioStreamCleansUpOnVideoStartFailure() async throws {
    let video = ControlledCaptureStream(), audio = ControlledCaptureStream()
    video.failStart = true
    let streams = CaptureStreamGroup(video: video, audio: audio)
    await #expect(throws: CaptureError.sourceUnavailable) { try await streams.startCapture() }
    #expect(audio.starts == 1 && audio.stops == 1 && video.stops == 1)
    try await streams.stopCapture()
    #expect(audio.stops == 1)
}

@Test @MainActor func independentAudioStreamStopsBothAfterOneStopFails() async throws {
    let video = ControlledCaptureStream(), audio = ControlledCaptureStream()
    video.failStop = true
    let streams = CaptureStreamGroup(video: video, audio: audio)
    try await streams.startCapture()
    await #expect(throws: CaptureError.self) { try await streams.stopCapture() }
    #expect(video.stops == 1 && audio.stops == 1)
}

@Test @MainActor func independentAudioFailureNeverStartsVideo() async throws {
    let video = ControlledCaptureStream(), audio = ControlledCaptureStream()
    audio.failStart = true
    let streams = CaptureStreamGroup(video: video, audio: audio)
    await #expect(throws: CaptureError.sourceUnavailable) { try await streams.startCapture() }
    #expect(video.starts == 0 && audio.stops == 1)
}

@Test func cameraResolutionCapsChooseNativeFormatsWithoutUpscaling() throws {
    let formats = [(640, 480), (1280, 720), (1920, 1080), (3840, 2160), (4096, 2160)].map {
        CameraFormatCandidate(width: $0.0, height: $0.1, rates: [30...60])
    }
    for (maximum, index) in [(CameraMaxResolution.hd720, 1), (.hd1080, 2), (.uhd4K, 3)] {
        let choice = try CameraFormatPolicy.choose(formats, maximum: maximum, fps: 60)
        #expect(choice.index == index && choice.fps == 60)
    }
    let small = try CameraFormatPolicy.choose([formats[0]], maximum: .uhd4K, fps: 30)
    #expect(small.width == 640 && small.height == 480)
    let portrait = try CameraFormatPolicy.choose([.init(width: 1080, height: 1920, rates: [30...30])], maximum: .hd1080, fps: 60)
    #expect(portrait.fps == 30 && portrait.width == 1080 && portrait.height == 1920)
}

@Test func cameraFormatRejectsUnsupportedCapAndRate() throws {
    let only4K = CameraFormatCandidate(width: 3840, height: 2160, rates: [30...60])
    #expect(throws: CaptureError.self) { try CameraFormatPolicy.choose([only4K], maximum: .hd720, fps: 60) }
    #expect(throws: CaptureError.self) { try CameraFormatPolicy.choose([], maximum: .hd1080, fps: 60) }
    #expect(throws: CaptureError.self) { try CameraFormatPolicy.choose([.init(width: 1920, height: 1080, rates: [1...24])], maximum: .hd1080, fps: 60) }
    let choices = [CameraFormatCandidate(width: 1920, height: 1080, rates: [30...30]),
                   CameraFormatCandidate(width: 1920, height: 1080, rates: [30...60])]
    #expect(try CameraFormatPolicy.choose(choices, maximum: .hd1080, fps: 60).index == 1)
    #expect(try CameraFormatPolicy.choose(choices, maximum: .hd1080, fps: 30).index == 0)
}

@Test func cameraResolutionOptionsRoundTripAndLegacyDefault() throws {
    for cap in CameraMaxResolution.allCases {
        for rate in CameraFrameRate.allCases {
            let options = RecordingOptions(target: .display(1), cameraMaxResolution: cap, cameraFrameRate: rate,
                                           outputDirectory: URL(fileURLWithPath: "/tmp"))
            let decoded = try JSONDecoder().decode(RecordingOptions.self, from: JSONEncoder().encode(options))
            #expect(decoded.cameraMaxResolution == cap)
            #expect(decoded.cameraFrameRate == rate)
        }
    }
    let options = RecordingOptions(target: .display(1), outputDirectory: URL(fileURLWithPath: "/tmp"))
    #expect(options.cameraMaxResolution == .hd1080)
    #expect(options.cameraFrameRate == .fps30)
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
    legacy.removeValue(forKey: "cameraMaxResolution")
    legacy.removeValue(forKey: "cameraFrameRate")
    let decodedLegacy = try JSONDecoder().decode(RecordingOptions.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decodedLegacy.cameraMaxResolution == .hd1080)
    #expect(decodedLegacy.cameraFrameRate == .fps30)
}

@Test func cameraFrameRateDefaultsToThirtyIndependentOfScreenCadence() throws {
    let formats = [CameraFormatCandidate(width: 1920, height: 1080, rates: [30...60])]
    let defaultSize = try #require(CameraFormatPolicy.effectiveSize(
        deviceID: "camera", maximum: .hd1080, fps: CameraFrameRate.fps30.rawValue,
        formatsForDevice: { _ in formats }))
    #expect(defaultSize.width == 1920 && defaultSize.height == 1080)
    #expect(try CameraFormatPolicy.choose(formats, maximum: .hd1080,
                                          fps: CameraFrameRate.fps30.rawValue).fps == 30)
    #expect(try CameraFormatPolicy.choose(formats, maximum: .hd1080,
                                          fps: CameraFrameRate.fps60.rawValue).fps == 60)
    for screenFPS in [30, 60, 120, 144] {
        #expect(CameraFormatPolicy.captureFPS(.fps30, screenMaxFPS: screenFPS) == 30)
        #expect(CameraFormatPolicy.captureFPS(.fps60, screenMaxFPS: screenFPS) == 60)
    }
}

@Test @MainActor func markerJournalSurvivesRecoveryAndTrimsUnreadableTail() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-markers-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = InputEventRecorder(directory: directory, rect: CGRect(x: 0, y: 0, width: 100, height: 100), hostStartNs: 100, keys: false)
    try recorder.openEventLog()
    let time = try recorder.addMarker(id: "marker-one", hostNs: 110)
    #expect(time == 10)
    _ = try recorder.addMarker(id: "marker-two", hostNs: 120)
    try recorder.stop()
    let url = directory.appendingPathComponent("events.jsonl")
    let file = try FileHandle(forWritingTo: url)
    try file.seekToEnd()
    try file.write(contentsOf: Data("{\"t\":21,\"type\":\"marker\",\"marker_id\":".utf8))
    try file.close()
    try Recovery.repairEvents(at: url, duration: 15)
    let event = try JSONDecoder().decode(CaptureEvent.self, from: Data(contentsOf: url))
    #expect(event.markerID == "marker-one" && event.t == 10 && event.type == "marker")
    #expect(throws: CaptureError.self) { try recorder.addMarker(id: "closed", hostNs: 130) }
}

@MainActor private func preflightSources() -> CaptureSources {
    CaptureSources(displays: [], windows: [], cameras: [.init(id: "cam", name: "Test camera", isDefault: true)],
        microphones: [.init(id: "internal", name: "Internal mic", isDefault: true, isBuiltIn: true),
                      .init(id: "external", name: "External mic", isDefault: false)])
}

@Test @MainActor func preflightDistinguishesMutedCameraMissingInputsAndPermissions() {
    var options = RecordingOptions(target: .window(2), cameraID: "cam", outputDirectory: URL(fileURLWithPath: "/tmp"))
    var issues = CapturePreflight.issues(options: options, sources: preflightSources(), lidClosed: nil, permission: { _ in .granted })
    #expect(issues.map(\.kind) == [.cameraWithoutMicrophone])
    options.microphoneID = "external"
    #expect(CapturePreflight.issues(options: options, sources: preflightSources(), lidClosed: true, permission: { _ in .granted }).isEmpty)
    options.cameraID = "unplugged-camera"; options.microphoneID = "unplugged-mic"
    issues = CapturePreflight.issues(options: options, sources: preflightSources(), lidClosed: nil, permission: { _ in .denied })
    #expect(issues.filter { $0.kind == .permissionRequired }.map(\.permission) == [.screen, .camera, .microphone])
    #expect(issues.contains { $0.kind == .cameraMissing } && issues.contains { $0.kind == .microphoneMissing })
    #expect(!issues.contains { $0.kind == .cameraWithoutMicrophone })
    #expect(Set(issues.map(\.id)).count == issues.count)
}

@Test @MainActor func preflightLidWarningOnlyAppliesToInternalMicrophone() {
    var options = RecordingOptions(target: .display(2), microphoneID: "internal", outputDirectory: URL(fileURLWithPath: "/tmp"))
    #expect(CapturePreflight.issues(options: options, sources: preflightSources(), lidClosed: true, permission: { _ in .granted }).map(\.kind) == [.microphoneLidClosed])
    #expect(CapturePreflight.issues(options: options, sources: preflightSources(), lidClosed: nil, permission: { _ in .granted }).isEmpty)
    #expect(CapturePreflight.issues(options: options, sources: preflightSources(), lidClosed: false, permission: { _ in .granted }).isEmpty)
    options.microphoneID = "external"
    #expect(CapturePreflight.issues(options: options, sources: preflightSources(), lidClosed: true, permission: { _ in .granted }).isEmpty)
    #expect(CapturePreflight.resizeIssue(accessibility: .granted) == nil)
    #expect(CapturePreflight.resizeIssue(accessibility: .denied)?.permission == .accessibility)
}

@Test @MainActor func preflightUSBPermissionChecksAreIndependentOfMacScreenAndAudioChecklist() {
    var options = RecordingOptions(target: .device("phone"), systemAudio: true, cameraID: "cam", outputDirectory: URL(fileURLWithPath: "/tmp"))
    var issues = CapturePreflight.issues(options: options, sources: preflightSources(), lidClosed: nil, permission: { $0 == .screen ? .denied : .granted })
    #expect(issues.isEmpty)
    options.systemAudioSelection = .applications(bundleIDs: ["a"])
    issues = CapturePreflight.issues(options: options, sources: preflightSources(), lidClosed: nil, permission: { _ in .notDetermined })
    #expect(issues.filter { $0.kind == .permissionRequired }.map(\.permission) == [.camera, .microphone])
    #expect(issues.contains { $0.kind == .applicationAudioUnavailable })
    options.target = .display(2)
    #expect(CapturePreflight.issues(options: options, sources: preflightSources(), lidClosed: nil, permission: { _ in .granted }).contains { $0.kind == .applicationAudioUnavailable })
}

@Test func fractionalUSBWebcamRatesKeepTheirNativeClock() throws {
    let formats = [CameraFormatCandidate(width: 1920, height: 1080, rates: [29.970...29.970]),
                   CameraFormatCandidate(width: 1280, height: 720, rates: [59.940...59.940])]
    let hd = try CameraFormatPolicy.choose(formats, maximum: .hd1080, fps: 60)
    #expect(hd.fps == 30 && hd.frameRate == 29.970)
    let low = try CameraFormatPolicy.choose(formats, maximum: .hd720, fps: 60)
    #expect(low.fps == 60 && low.frameRate == 59.940)
    #expect(throws: CaptureError.self) {
        try CameraFormatPolicy.choose([.init(width: 1280, height: 720, rates: [24...25])], maximum: .hd720, fps: 60)
    }
}
