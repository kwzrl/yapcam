import XCTest
import Metal
@preconcurrency import AVFoundation
@testable import YapcamRender

struct LongRunSyncObservation {
    let flashSeconds: Double
    let beepSeconds: Double
    var offsetSeconds: Double { beepSeconds-flashSeconds }
    init(pulseSeconds: Double,video: Data,audio: [Float],audioWindowStart: Double,fps: Int) throws {
        let lo=max(0,Int((pulseSeconds-0.15)*Double(fps)))
        let hi=min(video.count,Int(ceil((pulseSeconds+0.15)*Double(fps))))
        guard lo<hi,let flash=(lo..<hi).first(where: { video[$0]>200 }),
              video[lo..<hi].contains(where: { $0<30 }),
              let beep=audio.firstIndex(where: { abs($0)>0.08 }),
              audio.contains(where: { abs($0)>0.2 }) else {
            throw RenderError.verification("Missing flash/beep or inadequate signal contrast near \(pulseSeconds)s")
        }
        flashSeconds=Double(flash)/Double(fps)
        beepSeconds=audioWindowStart+Double(beep)/48_000
    }
}

/// Independent decoder shared by the real export benchmark and a short
/// software-muxed calibration. No native render/encode service is required for
/// calibration, so timestamp handling is checked before an expensive host run.
enum LongRunDecoder {
    static let executable="/opt/homebrew/bin/ffmpeg"
    static func requireAvailable() throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw RenderError.unavailable("ffmpeg is required for independent A/V measurement")
        }
    }
    static func grayFrames(_ url: URL) throws -> Data {
        try capture(["-v","error","-i",url.path,"-an","-vf","scale=1:1","-fps_mode","passthrough","-pix_fmt","gray","-f","rawvideo","pipe:1"])
    }
    static func audioSamples(_ url: URL,start: Double) throws -> [Float] {
        let bytes=try capture(["-v","error","-ss",String(start),"-i",url.path,"-t","0.3","-vn","-ac","1","-ar","48000","-f","f32le","pipe:1"])
        guard bytes.count.isMultiple(of: MemoryLayout<Float>.size) else { throw RenderError.verification("Independent decoder returned a truncated audio sample") }
        return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    static func capture(_ arguments: [String]) throws -> Data {
        try requireAvailable()
        let process=Process(), pipe=Pipe()
        process.executableURL=URL(fileURLWithPath: executable)
        process.arguments=["-nostdin"]+arguments; process.standardOutput=pipe
        try process.run()
        let data=pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus==0 else { throw RenderError.verification("Independent decoder failed (\(process.terminationStatus))") }
        return data
    }
}

final class LongExportTests: XCTestCase {
    func testTenMinuteFlashBeepExportStartMiddleEndSyncAndRSS() async throws {
        try RenderM3Artifacts.requireLongRun()
        let device=try requireRenderDevice()
        try LongRunDecoder.requireAvailable()
        let root=try temporaryRoot("sync-10m")
        defer { try? FileManager.default.removeItem(at: root) }
        let source=try LongRunSource(package: root,durationSeconds: 600,pulses: [1,300,599].map { $0*1_000_000_000 },decodedVideo: false)
        let output=root.appendingPathComponent("sync.mp4")
        let (exporter,memory)=try await export(source,to: output)
        let metrics=try XCTUnwrap(exporter.metrics)
        var values=exportValues(metrics,memory: memory,device: device)
        values["source"]="procedural_flash_streamed_pcm_beep"; values["media_seconds"]=600
        // Independent decoder reads the muxed file after export; verification
        // memory and the ffmpeg child are excluded from export-interval RSS.
        try RenderM3Artifacts.write("export-sync-10m-encoded",values: values,memory: memory)
        let video=try LongRunDecoder.grayFrames(output)
        XCTAssertEqual(video.count,600*30)
        for (name,pulse) in [("start",1.0),("middle",300.0),("end",599.0)] {
            let start=pulse-0.15
            let audio=try LongRunDecoder.audioSamples(output,start: start)
            let observation=try LongRunSyncObservation(pulseSeconds: pulse,video: video,audio: audio,audioWindowStart: start,fps: 30)
            values["\(name)_flash_s"]=observation.flashSeconds
            values["\(name)_beep_s"]=observation.beepSeconds
            values["\(name)_av_offset_ms"]=observation.offsetSeconds*1000
            XCTAssertLessThan(abs(observation.offsetSeconds),1.0/30,"\(name) A/V offset must be strictly under one frame")
        }
        try RenderM3Artifacts.write("export-sync-10m",values: values,memory: memory)
    }

    func testThirtyMinuteDecodedVideoAudioExportSoakAndRSSGrowth() async throws {
        try RenderM3Artifacts.requireLongRun()
        let device=try requireRenderDevice()
        let root=try temporaryRoot("soak-30m")
        defer { try? FileManager.default.removeItem(at: root) }
        let source=try LongRunSource(package: root,durationSeconds: 1800,pulses: [],decodedVideo: true)
        let (exporter,memory)=try await export(source,to: root.appendingPathComponent("soak.mp4"))
        let metrics=try XCTUnwrap(exporter.metrics)
        XCTAssertEqual(metrics.frames,54_000)
        var values=exportValues(metrics,memory: memory,device: device)
        values["source"]="looping_320x200_decoded_video_zoom_shadow_with_streamed_pcm_audio"
        values["media_seconds"]=1800
        values["soak_definition"]="one continuous 30-minute media export; actual wall time recorded"
        let growth=try XCTUnwrap(memory.steadyGrowth,"Need RSS samples in the 20–40% and 80–95% media intervals")
        let slope=try XCTUnwrap(memory.slopeBytesPerMediaMinute(duration: 1800))
        // A finite noise allowance accommodates native encoder/allocator cache
        // oscillation. Raw delta and slope are always reported, never called zero.
        let allowance=32.0*1024*1024
        values["steady_rss_growth_bytes"]=growth
        values["steady_rss_slope_bytes_per_media_minute"]=slope
        values["rss_growth_allowance_bytes"]=allowance
        values["bounded_rss_pass"] = growth<=allowance && slope<=1024*1024
        try RenderM3Artifacts.write("export-soak-30m",values: values,memory: memory)
        XCTAssertLessThanOrEqual(growth,allowance,"RSS medians grow >32MiB after warm-up; inspect CSV for retained objects")
        XCTAssertLessThanOrEqual(slope,1024*1024,"RSS trends upward >1MiB per media minute after warm-up")
    }

    private func temporaryRoot(_ name: String) throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-m3-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        return root
    }
    private func export(_ source: LongRunSource,to output: URL) async throws -> (Exporter,RenderMemoryMonitor.Report) {
        let exporter=try Exporter(project: source,settings: .init(outputHeight: 1080,fps: 30,includeAudio: true),destination: output)
        let monitor=try RenderMemoryMonitor()
        let task=Task { try await exporter.run { monitor.markProgress(min(1,$0/0.95)) } }
        let watchdog=Task {
            do { try await Task.sleep(for: .seconds(3600)) } catch { return }
            task.cancel()
        }
        defer { watchdog.cancel() }
        do { _ = try await task.value }
        catch {
            if let memory=try? monitor.finish() {
                try? RenderM3Artifacts.write("export-failed",values: ["error":error.localizedDescription,"media_seconds":Double(source.durationNs)/1e9,"sampled_peak_rss_bytes":memory.peak,"process_highwater_rss_bytes":memory.processPeak],memory: memory)
            }
            throw error
        }
        return (exporter,try monitor.finish())
    }
    private func exportValues(_ result: ExportMetrics,memory: RenderMemoryMonitor.Report,device: MTLDevice) -> [String: Any] {
        ["device":device.name,"height":1080,"fps":30,"audio":true,"frames":result.frames,
         "wall_seconds":result.elapsedSeconds,"export_x_realtime":result.realtimeMultiplier,
         "sampled_peak_rss_bytes":memory.peak,"process_highwater_rss_bytes":memory.processPeak,
         "rss_sample_count":memory.samples.count,"rss_sample_interval_s":0.5,
         "rss_scope":"export process only; from before preparation through writer finalization, excludes fixture generation/ffmpeg validation"]
    }

}

final class LongRunFixtureTests: XCTestCase {
    func testStreamedSignalAndFrameEvaluatorShareStartMiddleEndClock() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-m3-signal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source=try LongRunSource(package: root,durationSeconds: 6,pulses: [1,3,5].map { $0*1_000_000_000 },decodedVideo: false)
        let file=try AVAudioFile(forReading: root.appendingPathComponent("recording/signal.caf"))
        XCTAssertEqual(file.length,6*48_000)
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,frameCapacity: 4800))
        for second: Int64 in [1,3,5] {
            XCTAssertEqual(try source.frame(atNs: second*1_000_000_000).background_color.0,1)
            XCTAssertEqual(try source.frame(atNs: second*1_000_000_000+33_333_333).background_color.0,0)
            file.framePosition=second*48_000-2400
            try file.read(into: buffer,frameCount: 4800)
            let samples=try XCTUnwrap(buffer.floatChannelData?[0])
            XCTAssertTrue((0..<2400).allSatisfy { samples[$0]==0 })
            XCTAssertGreaterThan((2400..<4800).map { abs(samples[$0]) }.max() ?? 0,0.4)
        }
        let timeline=try AudioTimeline(project: source,range: 0..<source.durationNs)
        XCTAssertTrue(timeline.hasAudio)
        XCTAssertEqual(timeline.composition.duration.seconds,6,accuracy: 0.000_001)
    }
    func testIndependentDecoderDetectsRealMuxedAudioDelayAtEachPulse() throws {
        guard FileManager.default.isExecutableFile(atPath: LongRunDecoder.executable) else { throw XCTSkip("ffmpeg is required for muxed A/V calibration") }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-m3-calibration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source=try LongRunSource(package: root,durationSeconds: 6,pulses: [1,3,5].map { $0*1_000_000_000 },decodedVideo: false)
        var raw=Data()
        for index in 0..<180 {
            let frame=try source.frame(atNs: ExportTiming.offsetNs(index: index,fps: 30))
            raw.append(Data(repeating: frame.background_color.0>0.5 ? 255 : 0,count: 32*18))
        }
        let video=root.appendingPathComponent("frames.gray")
        try raw.write(to: video)
        for delay in [0.0,0.07] {
            let output=root.appendingPathComponent("delay-\(delay).mp4")
            _ = try LongRunDecoder.capture([
                "-v","error","-f","rawvideo","-pixel_format","gray","-video_size","32x18","-framerate","30","-i",video.path,
                "-itsoffset",String(delay),"-i",root.appendingPathComponent("recording/signal.caf").path,
                "-c:v","libx264","-preset","ultrafast","-crf","18","-pix_fmt","yuv420p","-c:a","aac","-b:a","128k","-t","6",output.path
            ])
            let gray=try LongRunDecoder.grayFrames(output)
            XCTAssertEqual(gray.count,180)
            for pulse in [1.0,3.0,5.0] {
                let start=pulse-0.15
                let audio=try LongRunDecoder.audioSamples(output,start: start)
                let observed=try LongRunSyncObservation(pulseSeconds: pulse,video: gray,audio: audio,audioWindowStart: start,fps: 30)
                XCTAssertEqual(observed.offsetSeconds,delay,accuracy: 0.002,"Decoder must preserve the muxed audio delay at \(pulse)s")
                if delay==0 { XCTAssertLessThan(abs(observed.offsetSeconds),1.0/30) }
                else { XCTAssertGreaterThan(observed.offsetSeconds,1.0/30) }
                print("RENDER_M3_CALIBRATION encoder=ffmpeg_software pulse_s=\(pulse) injected_delay_ms=\(delay*1000) observed_offset_ms=\(observed.offsetSeconds*1000)")
            }
        }
    }
    func testIndependentMeasurementExposesInjectedAudioDrift() throws {
        var video=Data(repeating: 0,count: 180)
        video[30]=255; video[90]=255; video[150]=255
        func observation(drift: Int) throws -> LongRunSyncObservation {
            var audio=[Float](repeating: 0,count: 14_400)
            audio[7200+drift]=0.5
            return try LongRunSyncObservation(pulseSeconds: 3,video: video,audio: audio,audioWindowStart: 2.85,fps: 30)
        }
        XCTAssertEqual(try observation(drift: 0).offsetSeconds,0,accuracy: 0.000_001)
        XCTAssertLessThan(abs(try observation(drift: 1500).offsetSeconds),1.0/30)
        XCTAssertGreaterThan(abs(try observation(drift: 1700).offsetSeconds),1.0/30)
        XCTAssertThrowsError(try LongRunSyncObservation(pulseSeconds: 3,video: Data(repeating: 0,count: 180),audio: [0],audioWindowStart: 2.85,fps: 30))
    }
}
