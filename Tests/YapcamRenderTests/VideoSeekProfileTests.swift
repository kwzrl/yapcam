import XCTest
import Metal
@preconcurrency import AVFoundation
@testable import YapcamRender

final class VideoSeekProfileTests: XCTestCase {
    func testSynthetic4KPrerollComparisonWhenOptedIn() throws {
        guard ProcessInfo.processInfo.environment["YAPCAM_RENDER_F16_PROFILE"]=="1" else {
            throw XCTSkip("Opt in to an 8s synthetic4K decoder-only comparison; not Metal presentation latency")
        }
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Yapcam/QA/render/f16-\(UUID().uuidString)")
        defer { print("Cleanup render-owned F16 media: \(root.lastPathComponent)"); try? FileManager.default.removeItem(at: root) }
        try Round3Synthetic.create(at: root,seconds: 8)
        let asset=AVURLAsset(url: root.appendingPathComponent("recording/screen.mov"),options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let track=try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        var keys: [Double]=[]
        if let cursor=track.makeSampleCursorAtFirstSampleInDecodeOrder() {
            repeat {
                let pts=cursor.presentationTimeStamp
                if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue,
                   let segment=track.segments.first(where: { !$0.isEmpty && CMTimeRangeContainsTime($0.timeMapping.source,time: pts) }) {
                    keys.append(CMTimeMapTimeFromRangeToRange(pts,fromRange: segment.timeMapping.source,toRange: segment.timeMapping.target).seconds)
                }
            }
            while cursor.stepInDecodeOrder(byCount: 1)==1
        }
        print("RENDER_F16_GOP synthetic4K60 keyframe_pts_seconds=\(keys)")
        // This sandbox can inspect compressed timing but cannot decode BGRA;
        // match the native media prerequisites used by the other render tests.
        _ = try requireRenderDevice()
        var rows: [[String:Any]]=[], before: [Double]=[], after: [Double]=[]
        for ns: Int64 in [1_123_000_000,2_777_000_000,4_177_000_000,6_123_000_000,3_311_000_000,7_711_000_000] {
            let time=CMTime(value: ns,timescale: 1_000_000_000)
            let old=try read(asset,track: track,start: max(.zero,time-CMTime(value: 1,timescale: 1)),target: time)
            let new=try read(asset,track: track,start: VideoSeekStart.time(asset: asset,track: track,requested: time),target: time)
            XCTAssertEqual(CMTimeCompare(old.time,new.time),0,"Retain exact nearest sample")
            XCTAssertLessThanOrEqual(new.frames,2)
            before.append(old.ms); after.append(new.ms)
            rows.append(["target_ns":ns,"before_ms":old.ms,"after_ms":new.ms,"before_frames":old.frames,"after_frames":new.frames])
        }
        let report: [String:Any]=["revision":ProcessInfo.processInfo.environment["YAPCAM_RENDER_F16_REVISION"] ?? "working tree",
            "configuration":"release; 3840x2160 HEVC60; BGRA AVAssetReader; physical8s",
            "scope":"Decoder-only comparison of old 1s preroll and production VideoSeekStart; not native Metal seek-to-present acceptance",
            "os":ProcessInfo.processInfo.operatingSystemVersionString,"keyframe_pts_seconds":keys,
            "before":Round3Data.summary(before),"after":Round3Data.summary(after),"samples":rows]
        let output=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Yapcam/render-f16")
        try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
        let name=UUID().uuidString+".json"
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent(name))
        print("RENDER_F16_DECODER \(name) before=\(Round3Data.summary(before)) after=\(Round3Data.summary(after))")
    }

    private func read(_ asset: AVAsset,track: AVAssetTrack,start: CMTime,target: CMTime) throws -> (time: CMTime,frames: Int,ms: Double) {
        let begin=DispatchTime.now().uptimeNanoseconds
        let reader=try AVAssetReader(asset: asset)
        let output=AVAssetReaderTrackOutput(track: track,outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
                                                                       kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
        output.alwaysCopiesSampleData=false; reader.add(output)
        reader.timeRange=CMTimeRange(start: start,duration: .positiveInfinity)
        guard reader.startReading() else { throw RenderError.decode(reader.error?.localizedDescription ?? "F16 reader failed") }
        defer { reader.cancelReading() }
        var previous: CMTime?,best: CMTime?,count=0
        while let sample=output.copyNextSampleBuffer() {
            guard CMSampleBufferGetImageBuffer(sample) != nil else { continue }
            let pts=CMSampleBufferGetPresentationTimeStamp(sample); count+=1
            if pts>=target {
                best=previous.map { abs(($0-target).seconds)<=abs((pts-target).seconds) ? $0 : pts } ?? pts
                break
            }
            previous=pts
        }
        if reader.status == .failed { throw RenderError.decode(reader.error?.localizedDescription ?? "F16 decoder failed") }
        return (try XCTUnwrap(best ?? previous),count,Double(DispatchTime.now().uptimeNanoseconds-begin)/1e6)
    }
}
