import XCTest
@testable import YapcamRender
import Metal

final class ExportSyncTests: XCTestCase {
    func capture(_ executable: String, arguments: [String]) throws -> Data {
        let task=Process(), pipe=Pipe(); task.executableURL=URL(fileURLWithPath: executable); task.arguments=arguments; task.standardOutput=pipe
        try task.run(); let data=pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit(); XCTAssertEqual(task.terminationStatus,0); return data
    }
    func testSyntheticFlashAndBeepStayWithinOneFrameAfterExport() async throws {
        _ = try requireRenderDevice()
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else { throw XCTSkip("ffmpeg is needed for independent A/V waveform verification") }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recording"),withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"segments\":[]}".utf8).write(to: root.appendingPathComponent("recording/session.json"))
        var audio=[Int16](repeating: 0,count: 48_000)
        let pulse=try ProceduralAudio.samples(for: .click(.crisp))
        for (index,value) in pulse.enumerated() { audio[9600+index]=value }
        try ProceduralAudio.wav(audio).write(to: root.appendingPathComponent("beep.wav"))
        let source=TestSource(package: root,duration: 1_000_000_000,overlays: [.init(source: .media(relativePath: "beep.wav"),startNs: 0,endNs: 1_000_000_000)]) { t in
            var frame=YcFrame(); frame.canvas_w=320; frame.canvas_h=200; frame.tl_ns=t; frame.click_progress = -1
            let c: Float=(200_000_000..<233_333_334).contains(t) ? 1 : 0
            frame.background_color=(c,c,c,1); return frame
        }
        let output=root.appendingPathComponent("sync.mp4")
        let exporter=try Exporter(project: source,settings: .init(outputHeight: 720,fps: 30),destination: output)
        _ = try await exporter.run { _ in }
        let video=try capture("/opt/homebrew/bin/ffmpeg",arguments: ["-v","error","-i",output.path,"-an","-vf","scale=1:1","-pix_fmt","gray","-f","rawvideo","pipe:1"])
        let flash=try XCTUnwrap(video.enumerated().max(by: { $0.element<$1.element })?.offset)
        let sound=try capture("/opt/homebrew/bin/ffmpeg",arguments: ["-v","error","-i",output.path,"-vn","-ac","1","-ar","48000","-f","f32le","pipe:1"])
        let samples=sound.withUnsafeBytes { bytes in Array(bytes.bindMemory(to: Float.self)) }
        let beep=try XCTUnwrap(samples.enumerated().max(by: { abs($0.element)<abs($1.element) })?.offset)
        XCTAssertLessThan(abs(Double(flash)/30-Double(beep)/48_000),1/30)
    }
    func testFixtureAudioExportCrossesSegmentBoundaryWithoutStalling() async throws {
        _ = try requireRenderDevice()
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-audio-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source=TestSource(package: fixture,duration: 5_000_000_000,clips: [.init(srcStartNs: 0,srcEndNs: 5_000_000_000)]) { t in
            var f=YcFrame(); f.tl_ns=t; f.canvas_w=320; f.canvas_h=200; f.background_color=(0,0,0,1); f.click_progress = -1
            f.screen.present=1; f.screen.segment=t<3_000_000_000 ? 0 : 1; f.screen.file_ns=t<3_000_000_000 ? t : t-3_000_000_000; f.screen.src_ns=t
            f.screen_crop = .init(x: 0,y: 0,w: 1,h: 1); f.screen_dest = .init(x: 0,y: 0,w: 320,h: 200); f.system_gain=1; return f
        }
        for (name, start, end) in [("full",Int64(0),Int64(5_000_000_000)),("boundary",2_500_000_000,3_500_000_000)] {
            let exporter=try Exporter(project: source,settings: .init(outputHeight: 720,includeAudio: true,rangeStartNs: start,rangeEndNs: end),destination: root.appendingPathComponent("\(name).mp4"))
            let task=Task { try await exporter.run { _ in } }
            let timeout=Task { try await Task.sleep(for: .seconds(20)); task.cancel() }
            defer { timeout.cancel() }
            _ = try await task.value
            XCTAssertEqual(exporter.metrics?.frames,Int((end-start)*30/1_000_000_000))
        }
    }
    func testExportPerformance1080And4K() async throws {
        _ = try requireRenderDevice()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recording"),withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"segments\":[]}".utf8).write(to: root.appendingPathComponent("recording/session.json"))
        let source=renderPerformanceSource()
        for height in [1080,2160] {
            let exporter=try Exporter(project: source,settings: .init(outputHeight: height,includeAudio: false,rangeEndNs: 2_000_000_000),destination: root.appendingPathComponent("\(height).mp4"))
            _ = try await exporter.run { _ in }
            let result=try XCTUnwrap(exporter.metrics)
            print("RENDER_BENCHMARK source=synthetic_decoded_video audio=false height=\(height) frames=\(result.frames) elapsed_s=\(result.elapsedSeconds) export_x_realtime=\(result.realtimeMultiplier)")
        }
    }
}
