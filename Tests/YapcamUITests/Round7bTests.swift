import Foundation
import Testing
import YapcamCapture
import YapcamCore
@testable import YapcamUI

@MainActor @Suite struct Round7bTests {
    private func package(mic: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "r7b-\(UUID()).yapcam", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir.appending(path: "recording"), withIntermediateDirectories: true)
        try Data(#"{"tracks":{"mic":\#(mic)}}"#.utf8).write(to: dir.appending(path: "recording/session.json"))
        return dir
    }

    @Test func sessionJSONMicFlagsAreRead() throws {
        let on = try package(mic: #"{"speech_enhancement":true,"stereo_mic":true,"channels":2}"#)
        let off = try package(mic: #"{"channels":1}"#)
        defer { try? FileManager.default.removeItem(at: on); try? FileManager.default.removeItem(at: off) }
        #expect(ProjectActions.micFlags(in: on) == (true, true))
        #expect(ProjectActions.micFlags(in: off) == (false, false))
        #expect(ProjectActions.micFlags(in: URL(fileURLWithPath: "/tmp/fixture/none.yapcam")) == (false, false))
    }

    @Test func recordTimeMicChoicesReachCaptureOnlyWithAMic() {
        func opts(mic: String?) -> UIRecordingOptions {
            UIRecordingOptions(target: .display(1), systemAudio: false, microphoneID: mic, cameraID: nil,
                               cleanVoiceOnRecord: true, recordStereoMicrophone: true, recordKeystrokes: false, maxFPS: 30,
                               outputDirectory: URL(fileURLWithPath: "/tmp"))
        }
        let with = LiveEngine.captureOptions(for: opts(mic: "m"))
        #expect(with.cleanVoiceOnRecord && with.recordStereoMicrophone)
        let without = LiveEngine.captureOptions(for: opts(mic: nil))
        #expect(!without.cleanVoiceOnRecord && !without.recordStereoMicrophone)
    }

    @Test func stereoMicSettingDefaultsOffAndResets() {
        let s = AppSettings(store: UserDefaults(suiteName: "r7b-\(UUID())")!)
        #expect(!s.recordStereoMicrophone)
        s.recordStereoMicrophone = true; s.resetToDefaults()
        #expect(!s.recordStereoMicrophone)
    }

    @Test func autoLanguageIsPassedToCaptureLiterally() {
        #expect(TranscriptionWiring.localeIdentifier(for: "auto", system: "en_US") == "auto")
        #expect(TranscriptionWiring.localeIdentifier(for: "", system: "en_US") == "auto")
        #expect(TranscriptionWiring.localeIdentifier(for: "de-DE", system: "en_US") == "de-DE")
    }

    @Test func previewUsesItsOwnSessionOnlyUntilCaptureOwnsTheCamera() {
        for p in [RecordingPhase.idle, .countdown(3), .finishing] { #expect(CameraPreviewPanel.source(for: p) == .standalone) }
        for p in [RecordingPhase.starting, .recording, .paused] { #expect(CameraPreviewPanel.source(for: p) == .recording) }
    }

    @Test func lostCameraShowsAPlaceholderWithTheReason() {
        #expect(CameraPreviewPanel.disconnectedText("") == "Camera disconnected")
        #expect(CameraPreviewPanel.disconnectedText("Unplugged") == "Camera disconnected\nUnplugged")
        let panel = CameraPreviewPanel()
        #expect(panel.placeholderText == nil)
        panel.receive(.unavailable("Unplugged"))
        #expect(panel.placeholderText == "Camera disconnected\nUnplugged")
    }
}
