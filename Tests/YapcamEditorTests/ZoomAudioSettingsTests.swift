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

@MainActor @Suite struct CheckedTimelineEditTests {
    @Test func coreRejectsTooShortItemsAndKeepsState() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ck-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        let zooms = m.zooms.count
        m.perform(.addZoom(startNs: 1_000_000_000, endNs: 1_050_000_000, scale: 2, focusX: 0.5, focusY: 0.5))   // 50 ms < 100 ms minimum
        #expect(m.lastError != nil && m.zooms.count == zooms)
        m.lastError = nil
        m.perform(.addZoom(startNs: 1_000_000_000, endNs: 2_000_000_000, scale: 2, focusX: 0.5, focusY: 0.5))
        #expect(m.lastError == nil && m.zooms.count == zooms + 1)
    }
}

@MainActor @Suite struct InsertionStyleTests {
    @Test func newZoomsInheritTheLastEditedStyle() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("is-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        m.seek(toNs: 500_000_000); m.addZoomAtPlayhead()
        guard case .zoom(let id) = m.selection else { Issue.record("no zoom selected"); return }
        m.setZoomScale(id: id, 3.5)
        m.seek(toNs: 4_000_000_000); m.addZoomAtPlayhead()
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        guard case .zoom(let second) = m.selection, let z = m.zooms.first(where: { $0.id == second }) else { Issue.record("no second zoom"); return }
        #expect(z.scale == 3.5)                                                     // remembered from the edit of the first zoom
    }
}
