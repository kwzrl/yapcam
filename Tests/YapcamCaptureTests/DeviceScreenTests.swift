import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import YapcamCapture

private func phone(_ id: String = "usb-test-phone") -> DeviceScreenDiscovery.Device {
    .init(id: id, name: "Test iPhone", width: 1170, height: 2532)
}

@Test func usbDiscoveryOptsInFiltersNonScreenDevicesAndDeduplicates() throws {
    var enabled = false
    let good = DeviceScreenDiscovery.Candidate(device: phone(), external: true, muxed: true,
                                               connected: true, continuityCamera: false)
    var webcam = good; webcam.device.id = "webcam"; webcam.muxed = false
    var continuity = good; continuity.device.id = "continuity"; continuity.continuityCamera = true
    var builtIn = good; builtIn.device.id = "built-in"; builtIn.external = false
    var unplugged = good; unplugged.device.id = "disconnected"; unplugged.connected = false
    var audioOnly = good; audioOnly.device.id = "audio-only"; audioOnly.device.width = 0
    let devices = try DeviceScreenDiscovery.load(enable: { enabled = true }, discover: {
        #expect(enabled) // Must opt in before AVFoundation discovery.
        return [good, webcam, continuity, builtIn, unplugged, audioOnly, good]
    })
    #expect(devices == [phone()])
    #expect(try DeviceScreenDiscovery.require("usb-test-phone", devices: devices) == phone())
}

private final class USBRoutingSink: CaptureTrackSink, @unchecked Sendable {
    let url: URL
    let firstNs: Int64
    init(url: URL, sample: CMSampleBuffer) {
        self.url = url; firstNs = CaptureClock.nanoseconds(sample.presentationTimeStamp)
    }
    func append(_ sample: CMSampleBuffer) throws -> Bool { true }
    func finish(atHostNs: Int64?) async throws {}
}

@Test func usbSamplesShareHostClockKeepAudioOffsetAndActualAudioFormat() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-usb-routing-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let samples = try InjectedCaptureSamples()
    let origin: Int64 = 9_000_000_000
    let writer = SegmentWriter(directory: directory, hostStartNs: origin - 100_000_000, maxFPS: 60) {
        USBRoutingSink(url: $0, sample: $2)
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        writer.queue.async {
            do {
                let clock = CMClockGetHostTimeClock()
                // Phone audio arriving before the first video must not add a blank lead-in.
                try DeviceScreenSamples.append(samples.audio(at: origin - 10_000_000), video: false, clock: clock, pixels: [64, 64], writer: writer)
                try DeviceScreenSamples.append(samples.video(at: origin), video: true, clock: clock, pixels: [64, 64], writer: writer)
                try DeviceScreenSamples.append(samples.audio(at: origin + 50_000_000), video: false, clock: clock, pixels: [64, 64], writer: writer)
                #expect(throws: CaptureError.self) {
                    try DeviceScreenSamples.append(samples.video(at: origin + 100_000_000), video: true, clock: clock, pixels: [62, 64], writer: writer)
                }
                continuation.resume()
            } catch { continuation.resume(throwing: error) }
        }
    }
    writer.end(at: origin + 1_000_000_000)
    let result = await writer.finish()
    #expect(result.error == nil)
    #expect(result.hostStartNs == origin)
    #expect(result.starts == ["screen": 0, "system_audio": 50_000_000])
    #expect(result.files == ["screen": "screen.mov", "system_audio": "system.m4a"])
    #expect(result.audioFormats["system_audio"]?.sampleRate == 48_000)
    #expect(result.audioFormats["system_audio"]?.channels == 1) // Never assume stereo.
}

@Test func usbDiscoveryNoDeviceAndEnableFailureAreExplicit() throws {
    let devices = try DeviceScreenDiscovery.load(enable: {}, discover: { [] })
    #expect(devices.isEmpty)
    #expect(throws: CaptureError.deviceLost("absent")) {
        try DeviceScreenDiscovery.require("absent", devices: devices)
    }
    #expect(throws: CaptureError.writerFailed("injected CMIO error")) {
        try DeviceScreenDiscovery.load(enable: { throw CaptureError.writerFailed("injected CMIO error") }, discover: {
            Issue.record("Discovery must not run after CMIO opt-in fails")
            return []
        })
    }
}

@Test func usbSourceUsesDeviceIdentityPortraitPixelsAndNoMacDisplay() throws {
    let source = try phone().source()
    let json = try #require(JSONSerialization.jsonObject(with: PackageIO.encoder.encode(source)) as? [String: Any])
    #expect(json["kind"] as? String == "device")
    #expect(json["display_id"] as? Int == 0) // Compatibility sentinel, not a host screen.
    #expect(json["display_name"] as? String == "Test iPhone")
    #expect(json["device_id"] as? String == "usb-test-phone")
    #expect(json["device_name"] as? String == "Test iPhone")
    #expect(json["content_rect_points"] as? [Int] == [0, 0, 1170, 2532])
    #expect(json["scale"] as? Int == 1)
    let decoded = try JSONDecoder().decode(SourceMetadata.self, from: PackageIO.encoder.encode(source))
    #expect(decoded.deviceID == source.deviceID && decoded.deviceName == source.deviceName)
    let options = RecordingOptions(target: .device("usb-test-phone"), outputDirectory: URL(fileURLWithPath: "/tmp"))
    #expect(try JSONDecoder().decode(RecordingOptions.self, from: JSONEncoder().encode(options)).target == options.target)
}

@Test func usbSelfTestSelectionNeedsNoMacDisplay() throws {
    let sources = CaptureSources(displays: [], windows: [], cameras: [], microphones: [],
                                deviceScreens: [CaptureDevice(id: "usb-test-phone", name: "Test iPhone", isDefault: true)])
    let options = try CaptureSelfTestOverrides(environment: ["YAPCAM_CAPTURE_SELFTEST_TARGET": "device:usb-test-phone"],
                                               sources: sources, seconds: 5)
    #expect(options.target == .device("usb-test-phone"))
    #expect(throws: CaptureError.deviceLost("missing")) {
        try CaptureSelfTestOverrides(environment: ["YAPCAM_CAPTURE_SELFTEST_TARGET": "device:missing"], sources: sources, seconds: 5)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["YAPCAM_CAPTURE_DEVICE_TESTS"] == "1"))
func actualUSBDiscoveryWithNoConnectedIOSDevice() throws {
    let devices = try CaptureSources.loadDeviceScreens()
    #expect(devices.isEmpty) // This fleet host has no iPhone/iPad connected.
    print("CAPTURE_USB_DISCOVERY devices=\(devices.count)")
}
