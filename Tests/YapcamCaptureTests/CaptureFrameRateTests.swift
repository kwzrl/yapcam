import AVFoundation
import Foundation
import Testing
import VideoToolbox
@testable import YapcamCapture

@Test(arguments: [24.0, 50.0, 59.94, 60.0, 75.0, 119.88, 120.0, 144.0, 240.0])
func automaticCaptureFollowsDisplayRatherThanSixtyCap(_ hz: Double) throws {
    #expect(try CaptureFrameRatePolicy.resolve(maxFPS: 0, refreshRate: hz) == Int(hz.rounded(.up)))
    #expect(try CaptureFrameRatePolicy.resolve(maxFPS: 30, refreshRate: hz) == 30)
    #expect(try CaptureFrameRatePolicy.resolve(maxFPS: 60, refreshRate: hz) == 60)
}

@Test func automaticDisplayRateFallsBackForDynamicOrUnknownRefresh() throws {
    #expect(CaptureFrameRatePolicy.displayRate(reported: 0, maximum: 120) == 120)
    #expect(CaptureFrameRatePolicy.displayRate(reported: .nan, maximum: 75) == 75)
    #expect(CaptureFrameRatePolicy.displayRate(reported: .infinity, maximum: 0) == 60)
    #expect(throws: CaptureError.self) { try CaptureFrameRatePolicy.resolve(maxFPS: -1, refreshRate: 60) }
    #expect(throws: CaptureError.self) { try CaptureFrameRatePolicy.resolve(maxFPS: 1001, refreshRate: 60) }
}

@Test func parityDefaultsAndLegacyExplicitOptionsSurviveSerialization() throws {
    let options = RecordingOptions(target: .display(2), outputDirectory: URL(fileURLWithPath: "/tmp"))
    #expect(options.maxFPS == 0 && options.recordKeystrokes && !options.systemAudio)
    var values = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
    values.removeValue(forKey: "maxFPS"); values.removeValue(forKey: "recordKeystrokes")
    var restored = try JSONDecoder().decode(RecordingOptions.self, from: JSONSerialization.data(withJSONObject: values))
    #expect(restored.maxFPS == 0 && restored.recordKeystrokes)
    restored.maxFPS = 30; restored.recordKeystrokes = false
    let explicit = try JSONDecoder().decode(RecordingOptions.self, from: JSONEncoder().encode(restored))
    #expect(explicit.maxFPS == 30 && !explicit.recordKeystrokes)
}

@Test(arguments: [30, 60, 120, 144]) func videoEncodingPolicyUsesDistinctQualitiesAndFrameAndTimeLimits(_ fps: Int) throws {
    let screen = try #require(CaptureMediaPolicy.videoSettings(width: 1626, height: 1014, key: "screen", maxFPS: fps)[AVVideoCompressionPropertiesKey] as? [String: Any])
    #expect(screen[kVTCompressionPropertyKey_Quality as String] as? Double == 0.85)
    #expect(screen[AVVideoMaxKeyFrameIntervalKey] as? Int == fps * 2)
    #expect(screen[AVVideoExpectedSourceFrameRateKey] as? Int == fps)
    #expect(screen[AVVideoMaxKeyFrameIntervalDurationKey] as? Double == 2)
    #expect(screen[AVVideoQualityKey] as? Double == 0.85)
    #expect(screen[AVVideoAllowFrameReorderingKey] as? Bool == false)
    let camera = try #require(CaptureMediaPolicy.videoSettings(width: 1920, height: 1080, key: "camera", maxFPS: fps)[AVVideoCompressionPropertiesKey] as? [String: Any])
    #expect(camera[kVTCompressionPropertyKey_Quality as String] as? Double == 0.6)
    #expect(camera[AVVideoMaxKeyFrameIntervalKey] as? Int == (fps >= 60 ? 120 : 60))
}
