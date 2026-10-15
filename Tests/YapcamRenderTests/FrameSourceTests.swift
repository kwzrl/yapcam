import XCTest
@preconcurrency import AVFoundation
import Metal
import CoreVideo
@testable import YapcamRender

final class FrameSourceTests: XCTestCase {
    func testSparseStaticTailReusesReaderAndBackwardScrubStillDecodes() async throws {
        let device=try requireRenderDevice()
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-static-tail-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeSparseVideo(to: url)
        var cache: CVMetalTextureCache?
        XCTAssertEqual(CVMetalTextureCacheCreate(nil,nil,device,nil,&cache),kCVReturnSuccess)
        let source=try FrameSource(url: url,cache: XCTUnwrap(cache))
        let first=try source.frame(atNs: 0)
        XCTAssertEqual(first.time.seconds,0,accuracy: 0.001)
        // Normal playback reaches EOF shortly after the last changed frame.
        let tail=try source.frame(atNs: 300_000_000)
        XCTAssertEqual(tail.time.seconds,0.2,accuracy: 0.001)
        let starts=source.readerStartCount
        for ns in stride(from: Int64(400_000_000),through: 4_900_000_000,by: 100_000_000) {
            XCTAssertTrue(try source.frame(atNs: ns) === tail)
            XCTAssertEqual(source.readerStartCount,starts,"A held frame must not reopen AVAssetReader")
        }
        XCTAssertFalse(source.hasEnded(atNs: 4_900_000_000))
        XCTAssertTrue(source.hasEnded(atNs: 5_000_000_000))
        // A cold seek into the tail must also reuse the decoded final frame.
        let seeking=try FrameSource(url: url,cache: XCTUnwrap(cache))
        let sought=try seeking.frame(atNs: 3_000_000_000)
        // AVFoundation may clip the covering sample's PTS to the reader range
        // start (2s); the retained frame must still cover the requested tail.
        XCTAssertGreaterThanOrEqual(sought.time.seconds,0.2-0.001)
        XCTAssertLessThanOrEqual(sought.time.seconds,2.0+0.001)
        let soughtStarts=seeking.readerStartCount
        for ns: Int64 in [3_500_000_000,4_900_000_000,2_000_000_000] {
            XCTAssertTrue(try seeking.frame(atNs: ns) === sought)
            XCTAssertEqual(seeking.readerStartCount,soughtStarts)
        }
        // The cold seek's window excludes the first sample: seek backwards.
        let scrubbed=try seeking.frame(atNs: 0)
        XCTAssertEqual(scrubbed.time.seconds,0,accuracy: 0.001)
        XCTAssertEqual(seeking.readerStartCount,soughtStarts+1)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(scrubbed.pixelBuffer))
        XCTAssertEqual(scrubbed.texture.width,64)
    }

    private func writeSparseVideo(to url: URL) async throws {
        let writer=try AVAssetWriter(outputURL: url,fileType: .mov)
        let input=AVAssetWriterInput(mediaType: .video,outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,AVVideoWidthKey: 64,AVVideoHeightKey: 48
        ])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,kCVPixelBufferHeightKey as String: 48,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        guard writer.startWriting() else { throw RenderError.decode(writer.error?.localizedDescription ?? "Sparse fixture writer failed") }
        writer.startSession(atSourceTime: .zero)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        for (index,ns) in [Int64(0),200_000_000].enumerated() {
            let deadline=ContinuousClock.now.advanced(by: .seconds(5))
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ContinuousClock.now<deadline else { throw RenderError.decode("Sparse fixture writer stalled") }
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil,try XCTUnwrap(adaptor.pixelBufferPool),&buffer),kCVReturnSuccess)
            let pixelBuffer=try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer,[])
            let bytes=try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
            for y in 0..<48 { for x in 0..<64 {
                let offset=y*CVPixelBufferGetBytesPerRow(pixelBuffer)+x*4
                bytes[offset]=0; bytes[offset+1]=index==0 ? 0 : 255
                bytes[offset+2]=index==0 ? 255 : 0; bytes[offset+3]=255
            } }
            CVPixelBufferUnlockBaseAddress(pixelBuffer,[])
            XCTAssertTrue(adaptor.append(pixelBuffer,withPresentationTime: CMTime(value: ns,timescale: 1_000_000_000)))
        }
        // Match capture's static-tail contract: no duplicate frames, explicit end.
        writer.endSession(atSourceTime: CMTime(seconds: 5,preferredTimescale: 1_000_000_000))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status,.completed,writer.error?.localizedDescription ?? "")
    }
}
