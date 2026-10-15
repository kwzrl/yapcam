import Testing
import Foundation
import YapcamCore
@testable import YapcamEditor

@MainActor @Suite struct ZoomAudioSettingsTests {
    @Test func zoomAndMicPresetSettingsRoundTrip() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("za-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        m.set("zoom_settings.start_early", bool: true); m.set("zoom_settings.default_scale", number: 3)
        m.set("audio.mic_preset", string: "podcast")
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.bool("zoom_settings.start_early") && m.number("zoom_settings.default_scale", default: 2) == 3 && m.string("audio.mic_preset") == "podcast")
    }
}
