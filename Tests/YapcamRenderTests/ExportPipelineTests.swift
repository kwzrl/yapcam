import XCTest
@preconcurrency import AVFoundation
@testable import YapcamRender

final class ExportPipelineTests: XCTestCase {
    func testSerialAndOverlappedExportsKeepEveryFrameInOrderOnHost() async throws {
        _ = try requireRenderDevice()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-pipeline-\(UUID().uuidString)")
        defer { print("Cleanup render-owned pipeline fixture: \(root.lastPathComponent)"); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recording"),withIntermediateDirectories: true)
        try Data(#"{"segments":[]}"#.utf8).write(to: root.appendingPathComponent("recording/session.json"))
        let source=TestSource(package: root,duration: 1_000_000_000) { ns in
            var f=YcFrame(); f.tl_ns=ns; f.canvas_w=64; f.canvas_h=64; f.click_progress = -1
            let index=Int((Double(ns)*30/1e9).rounded()), channel=(index/3)%3
            f.background_color=(channel==0 ? 0.9 : 0.1,channel==1 ? 0.9 : 0.1,channel==2 ? 0.9 : 0.1,1)
            return f
        }
        for codec in [ExportSettings.Codec.h264,.hevc] {
            for callbacks in [false,true] {
            for depth in [1,2] {
                let url=root.appendingPathComponent("\(codec.rawValue)-\(depth)-\(callbacks).mp4")
                let exporter=try Exporter(project: source,settings: .init(codec: codec,outputHeight: 720,fps: 30,includeAudio: false),
                                          destination: url,videoPipelineDepth: depth,callbackVideo: callbacks)
                _ = try await exporter.run { _ in }
                let profile=try XCTUnwrap(exporter.videoDiagnostics.first)
                XCTAssertEqual(profile.pipelineDepth,depth); XCTAssertEqual(profile.peakPendingFrames,depth)
                XCTAssertEqual(profile.writerReadinessMode,callbacks ? "callback" : "poll_2ms")
                XCTAssertEqual(profile.renderedFrames,30); XCTAssertEqual(profile.encodedFrames,30)
                XCTAssertGreaterThan(profile.wallSeconds,0)
                let asset=AVURLAsset(url: url), reader=try AVAssetReader(asset: asset)
                let track=try XCTUnwrap(asset.tracks(withMediaType: .video).first)
                let output=AVAssetReaderTrackOutput(track: track,outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
                reader.add(output); XCTAssertTrue(reader.startReading())
                var index=0
                while let sample=output.copyNextSampleBuffer() {
                    guard let pixel=CMSampleBufferGetImageBuffer(sample) else { continue }
                    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds,Double(index)/30,accuracy: 0.000001)
                    CVPixelBufferLockBaseAddress(pixel,.readOnly)
                    let raw=try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
                    let center=360*CVPixelBufferGetBytesPerRow(pixel)+360*4
                    let rgb=[Int(raw[center+2]),Int(raw[center+1]),Int(raw[center])]
                    CVPixelBufferUnlockBaseAddress(pixel,.readOnly)
                    let expected=(index/3)%3
                    for other in 0..<3 where other != expected {
                        XCTAssertGreaterThan(rgb[expected],rgb[other]+64,"\(codec)/depth\(depth)/frame\(index): preserve frame color/order")
                    }
                    index+=1
                }
                XCTAssertEqual(reader.status,.completed); XCTAssertEqual(index,30)
            }
            }
        }
    }
}
