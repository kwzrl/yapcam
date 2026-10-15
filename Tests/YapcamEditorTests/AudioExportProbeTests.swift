import Testing
import Foundation
@testable import YapcamEditor

@MainActor @Suite struct AudioExportProbeTests {
    /// The fixture's two segments with audio used to stall the exporter at ~59 %. Bounded wait so a regression fails fast.
    @Test func fixtureExportsWithAudio() async throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("aud-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("aud-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let doc = try EditorDocument(package: d)
        doc.export.height = 720; doc.export.includeAudio = true
        doc.export.start(to: out)
        let watchdog = Task { try await Task.sleep(for: .seconds(60)); doc.export.cancel() }
        await doc.export.waitUntilFinished(); watchdog.cancel()
        #expect(doc.export.state == .done(out), "\(doc.export.state)")
    }
}
