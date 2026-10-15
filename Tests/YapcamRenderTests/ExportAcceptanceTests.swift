import XCTest
import AVFoundation
import YapcamCore
@testable import YapcamRender

final class ExportAcceptanceTests: XCTestCase {
    func testHighResolutionPresetTracksAndQualityBitrateOnHost() async throws {
        _ = try requireRenderDevice()
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-export-acceptance-\(UUID().uuidString)")
        let package=root.appendingPathComponent("fixture.yapcam")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture,to: package)
        defer { try? FileManager.default.removeItem(at: root) }
        let project=try Project.create(package: package)
        let frame=try project.frame(atNs: 200_000_000)
        var lowRate: Float=0,highRate: Float=0
        let cases: [(String,ExportSettings)] = [
            ("1440",.init(outputHeight: 1440,fps: 24,includeAudio: false)),
            ("4k",.init(codec: .hevc,outputHeight: 2160,fps: 60,includeAudio: false)),
            ("quality-low",.init(outputHeight: 720,fps: 30,quality: 0.1,includeAudio: false)),
            ("quality-high",.init(outputHeight: 720,fps: 30,quality: 0.9,includeAudio: false))
        ]
        for (name,var settings) in cases {
            settings.rangeStartNs=200_000_000; settings.rangeEndNs=700_000_000
            let destination=root.appendingPathComponent("\(name).mp4")
            _ = try await Exporter(project: project,settings: settings,destination: destination).run { _ in }
            let asset=AVURLAsset(url: destination)
            let videos=try await asset.loadTracks(withMediaType: .video)
            let audio=try await asset.loadTracks(withMediaType: .audio)
            let track=try XCTUnwrap(videos.first)
            let size=try await track.load(.naturalSize)
            let fps=try await track.load(.nominalFrameRate)
            let bitrate=try await track.load(.estimatedDataRate)
            let duration=try await asset.load(.duration)
            XCTAssertEqual(videos.count,1); XCTAssertTrue(audio.isEmpty)
            XCTAssertEqual(Int(size.height),settings.outputHeight)
            XCTAssertEqual(Int(size.width),try settings.outputWidth(canvasWidth: frame.canvas_w,canvasHeight: frame.canvas_h))
            XCTAssertEqual(fps,Float(settings.fps),accuracy: 0.01)
            XCTAssertEqual(duration.seconds,0.5,accuracy: 1/Double(settings.fps))
            XCTAssertGreaterThan(bitrate,0)
            print("RENDER_EXPORT_ACCEPTANCE case=\(name) height=\(settings.outputHeight) fps=\(fps) measured_bitrate=\(bitrate)")
            if name=="quality-low" { lowRate=bitrate }
            if name=="quality-high" { highRate=bitrate }
        }
        XCTAssertGreaterThanOrEqual(highRate,lowRate*0.95,"Higher target bitrate must not materially reduce this fixture's encoded bitrate")
    }
}
