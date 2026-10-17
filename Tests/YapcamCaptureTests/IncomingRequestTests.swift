import Foundation
import Speech
import Testing
@testable import YapcamCapture

@Test func cameraSizePreviewUsesRecordingRateAndCapInsteadOfLargestImageOnly() throws {
    let formats: [CameraFormatCandidate] = [
        .init(width: 3840, height: 2160, rates: [1...24]), // Would fail recording.
        .init(width: 1920, height: 1080, rates: [29.97...29.97]),
        .init(width: 1280, height: 720, rates: [59.94...59.94]),
        .init(width: 640, height: 480, rates: [30...30])
    ]
    for cap in CameraMaxResolution.allCases {
        for fps in [30, 60] {
            var queried: [String] = []
            let size = try #require(CameraFormatPolicy.effectiveSize(deviceID: "camera", maximum: cap, fps: fps, formatsForDevice: {
                queried.append($0); return formats
            }))
            let recording = try CameraFormatPolicy.choose(formats, maximum: cap, fps: fps)
            #expect(size.width == recording.width && size.height == recording.height)
            #expect(queried == ["camera"])
            #expect(size.width <= 1920) // Never advertise the unsupported 4K mode.
        }
    }
    let low = try #require(CameraFormatPolicy.effectiveSize(deviceID: "camera", maximum: .uhd4K, fps: 60,
        formatsForDevice: { _ in [.init(width: 640, height: 480, rates: [30...30])] }))
    #expect(low.width == 640 && low.height == 480) // No upscale to requested cap.
}

@Test func cameraSizePreviewReturnsUnavailableForMissingOrIncompatibleFormats() {
    #expect(CameraFormatPolicy.effectiveSize(deviceID: "gone", maximum: .hd1080, fps: 60, formatsForDevice: { _ in nil }) == nil)
    #expect(CameraFormatPolicy.effectiveSize(deviceID: "empty", maximum: .hd1080, fps: 60, formatsForDevice: { _ in [] }) == nil)
    #expect(CameraFormatPolicy.effectiveSize(deviceID: "camera", maximum: .hd720, fps: 60,
        formatsForDevice: { _ in [.init(width: 3840, height: 2160, rates: [30...60])] }) == nil)
    #expect(CameraFormatPolicy.effectiveSize(deviceID: "camera", maximum: .hd1080, fps: 120,
        formatsForDevice: { _ in [.init(width: 1280, height: 720, rates: [30...60])] }) == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["YAPCAM_CAPTURE_LOCALE_TESTS"] == "1"))
func speechPickerLocalesComeFromNativeRecognizerWithoutRequestingAuthorization() {
    let permission = SFSpeechRecognizer.authorizationStatus()
    let locales = TranscriptionService.supportedLocales()
    #expect(Set(locales) == SFSpeechRecognizer.supportedLocales())
    #expect(locales.map(\.identifier) == locales.map(\.identifier).sorted())
    #expect(SFSpeechRecognizer.authorizationStatus() == permission)
}
