import XCTest
import AVFoundation
@testable import YapcamRender

final class VariableFrameRateTests: XCTestCase {
    func testExactIdentityIgnoresPaddingButRetainsChangedAndFinalFrames() throws {
        func buffer(_ value: UInt8,_ padding: UInt8) throws -> CVPixelBuffer {
            var result: CVPixelBuffer?
            guard CVPixelBufferCreate(nil,3,2,kCVPixelFormatType_32BGRA,nil,&result)==kCVReturnSuccess, let result else { throw RenderError.write("Cannot allocate comparison fixture") }
            CVPixelBufferLockBaseAddress(result,[])
            let stride=CVPixelBufferGetBytesPerRow(result), bytes=CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
            bytes.initialize(repeating: padding,count: stride*2)
            for y in 0..<2 { for x in 0..<12 { bytes[y*stride+x]=value } }
            CVPixelBufferUnlockBaseAddress(result,[])
            return result
        }
        var dedup=ExactFrameDeduplicator()
        XCTAssertTrue(try dedup.shouldAppend(buffer(100,0),isLast: false))
        XCTAssertFalse(try dedup.shouldAppend(buffer(100,255),isLast: false),"Row padding must not create a false change")
        XCTAssertTrue(try dedup.shouldAppend(buffer(101,0),isLast: false),"Even one visible color-step is a real change")
        XCTAssertFalse(try dedup.shouldAppend(buffer(101,7),isLast: false))
        XCTAssertTrue(try dedup.shouldAppend(buffer(100,7),isLast: false),"Returning to an earlier image is a change")
        XCTAssertTrue(try dedup.shouldAppend(buffer(100,9),isLast: true),"Keep the terminal timestamp on a static tail")
    }
    func testVFRIsOptInCodableAndDisabledForGIF() throws {
        XCTAssertFalse(ExportSettings().variableFrameRate)
        let old=try JSONDecoder().decode(ExportSettings.self,from: Data(#"{"format":"mp4","codec":"h264","fps":30,"outputHeight":1080,"quality":0.4}"#.utf8))
        XCTAssertFalse(old.variableFrameRate); XCTAssertEqual(old.fps,30); XCTAssertNil(old.compression)
        let vfr=ExportSettings(codec: .both,variableFrameRate: true)
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self,from: JSONEncoder().encode(vfr)),vfr)
        XCTAssertTrue(vfr.closestValidPreset().variableFrameRate)
        var gif=vfr; gif.format = .gif
        XCTAssertFalse(gif.closestValidPreset().variableFrameRate)
    }
    func testExperimentalVFRRetainsChangedFramePTSFinalDurationAndAudioOnHost() async throws {
        _ = try requireRenderDevice()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-vfr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recording"),withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"segments\":[]}".utf8).write(to: root.appendingPathComponent("recording/session.json"))
        var samples=[Int16](repeating: 0,count: 96_000)
        for i in 48_000..<50_400 { samples[i]=Int16(sin(Double(i)*2*Double.pi*1000/48_000)*8000) }
        try ProceduralAudio.wav(samples).write(to: root.appendingPathComponent("beep.wav"))
        let source=TestSource(package: root,duration: 2_000_000_000,overlays: [.init(source: .media(relativePath: "beep.wav"),startNs: 0,endNs: 2_000_000_000)]) { ns in
            var f=YcFrame(); f.canvas_w=320; f.canvas_h=200; f.tl_ns=ns; f.click_progress = -1
            let color: Float=ns<1_000_000_000 ? 0 : 1
            f.background_color=(color,color,color,1); return f
        }
        for format in [ExportSettings.Format.mp4,.mov] {
            for codec in [ExportSettings.Codec.h264,.hevc] {
                let url=root.appendingPathComponent("\(format)-\(codec).\(format.rawValue)")
                let exporter=try Exporter(project: source,settings: .init(format: format,codec: codec,fps: 30,variableFrameRate: true),destination: url)
                _ = try await exporter.run { _ in }
                XCTAssertEqual(exporter.metrics?.frames,60)
                XCTAssertEqual(exporter.encodedVideoFrames,3)
                let asset=AVURLAsset(url: url)
                let duration=try await asset.load(.duration)
                XCTAssertEqual(duration.seconds,2,accuracy: 1/30)
                let audios=try await asset.loadTracks(withMediaType: .audio), videos=try await asset.loadTracks(withMediaType: .video)
                XCTAssertEqual(audios.count,1)
                let track=try XCTUnwrap(videos.first)
                let reader=try AVAssetReader(asset: asset), output=AVAssetReaderTrackOutput(track: track,outputSettings: nil)
                reader.add(output); XCTAssertTrue(reader.startReading())
                var times: [Double]=[]
                while let sample=output.copyNextSampleBuffer() { times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
                XCTAssertEqual(reader.status,.completed)
                XCTAssertEqual(times.count,3)
                for (actual,expected) in zip(times,[0,1,59.0/30]) { XCTAssertEqual(actual,expected,accuracy: 0.000001) }
            }
        }
    }
}
