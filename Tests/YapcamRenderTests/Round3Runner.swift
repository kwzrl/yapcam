#if YAPCAM_RENDER_ROUND3_APP
import AppKit
import MetalKit
import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import YapcamCore
@testable import YapcamRender

/// Standalone, signed host runner. LaunchServices supplies the native app
/// context; the regular XCTest executable intentionally has no entry point here.
@main @MainActor enum Round3Runner {
    static func main() {
        let app = NSApplication.shared
        let delegate = Round3Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor private final class Round3Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--config"), args.indices.contains(index + 1) else {
            NSApplication.shared.terminate(nil); return
        }
        Task { @MainActor in
            do {
                let config=try JSONDecoder().decode(Round3Configuration.self,from: Data(contentsOf: URL(fileURLWithPath: args[index+1])))
                let run=try Round3Run(config)
                do { try await run.execute(); try run.write("result",["status":"complete"]) }
                catch { try? run.write("result",["status":"failed","reason":error.localizedDescription]) }
            } catch { NSLog("Round3 runner failed: %@",error.localizedDescription) }
            NSApplication.shared.terminate(nil)
        }
    }
}

@MainActor private final class Round3View: MTKView {
    let presentations=Round3Presentations()
    weak var player: PreviewPlayer?
    var generation=0
    override var currentDrawable: (any CAMetalDrawable)? {
        guard let drawable=super.currentDrawable else { return nil }
        let ns=player?.currentNs ?? -1, generation=generation, log=presentations
        drawable.addPresentedHandler { drawable in
            log.record(.init(ns: ns,generation: generation,time: drawable.presentedTime,drawable: drawable.drawableID))
        }
        return drawable
    }
}

@MainActor private final class Round3Run {
    let config: Round3Configuration
    let work: URL
    let results: URL
    var sourceInfo: [String:Any]=[:]
    init(_ config: Round3Configuration) throws {
        self.config=config; work=URL(fileURLWithPath: config.workDirectory,isDirectory: true)
        results=URL(fileURLWithPath: config.resultsDirectory,isDirectory: true)
        try FileManager.default.createDirectory(at: results,withIntermediateDirectories: true)
        try write("owner",["pid":ProcessInfo.processInfo.processIdentifier,"token":config.token,
                           "bundle":Bundle.main.bundleURL.path])
    }
    func write(_ name: String,_ values: [String:Any]) throws {
        var record=sourceInfo.merging(values) { _,new in new }
        record["revision"]=config.revision; record["harness_sha256"]=config.harnessHash
        record["build_configuration"]="release_O_enable_testing"
        record["source_choice"]=config.source; record["mode"]=config.mode
        record["timestamp_utc"]=ISO8601DateFormatter().string(from: Date())
        record["os"]=ProcessInfo.processInfo.operatingSystemVersionString
        try JSONSerialization.data(withJSONObject: record,options: [.prettyPrinted,.sortedKeys]).write(to: results.appendingPathComponent(name+".json"),options: .atomic)
    }
    func execute() async throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw RenderError.metal("Metal unavailable in signed LaunchServices runner") }
        sourceInfo["device"]=device.name
        sourceInfo["video_pipeline_depth"]=config.videoPipelineDepth ?? 2
        sourceInfo["reuse_video_seek_reader"]=config.reuseVideoSeekReader ?? true
        sourceInfo["video_readiness"]=config.callbackVideo == false ? "poll_2ms" : "callback"
        if config.mode=="probe" { return }
        guard config.previewSeconds>0,config.previewSeconds<=60,config.soakSeconds>=0,config.soakSeconds<=1800,
              config.scrubSamples>0,config.scrubSamples<=200 else { throw RenderError.invalidSettings("Invalid Round3 run limits") }
        try FileManager.default.createDirectory(at: work,withIntermediateDirectories: true)
        defer { print("Cleanup render-owned media scratch: \(work.lastPathComponent)"); try? FileManager.default.removeItem(at: work) }
        let package=work.appendingPathComponent("source.yapcam",isDirectory: true)
        let original=(config.sourcePackage ?? config.originalPackage).map { URL(fileURLWithPath: $0,isDirectory: true) }
        var originals: [String:String]=[:]
        if let original,FileManager.default.fileExists(atPath: original.path) {
            originals=try Round3Data.fingerprints(original)
            try FileManager.default.copyItem(at: original,to: package)
        } else if config.source=="recorded" {
            guard let original else { throw RenderError.missingMedia("No real recording selected") }
            originals=try Round3Data.fingerprints(original)
            try FileManager.default.copyItem(at: original,to: package)
        } else if config.source=="synthetic4k" {
            try await Task.detached { try Round3Synthetic.create(at: package,seconds: self.config.syntheticSeconds) }.value
            if let original {
                // Explicit reusable synthetic input; never regenerate for the
                // comparison run or write into an existing input package.
                try FileManager.default.copyItem(at: package,to: original)
                originals=try Round3Data.fingerprints(original)
            }
        } else { throw RenderError.invalidSettings("Unknown Round3 source") }
        if !originals.isEmpty { sourceInfo["input_fingerprints"]=originals }
        defer {
            if let original, !originals.isEmpty {
                do { try write("original-integrity",["original_intact":try Round3Data.fingerprints(original)==originals]) }
                catch { try? write("original-integrity",["original_intact":false,"reason":error.localizedDescription]) }
            }
        }
        // Only the copy is opened/edited. Keep the real package read-only.
        let project=try Project.create(package: package)
        try project.apply(.set(path: "canvas.aspect",value: .string("16:9")))
        let physical=try project.snapshot()
        let source=try Round3RepeatedSource(base: physical,minimumSeconds: max(660,config.soakSeconds+60))
        let session=try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("recording/session.json"))) as? [String:Any]
        let track=(session?["tracks"] as? [String:Any])?["screen"] as? [String:Any]
        sourceInfo["decoded_pixel_size"]=track?["pixel_size"] ?? []
        sourceInfo["source_codec"]=track?["codec"] ?? "unknown"
        sourceInfo["source_declared_max_fps"]=track?["max_fps"] ?? NSNull()
        sourceInfo["physical_source_seconds"]=Double(physical.durationNs)/1e9
        sourceInfo["timeline_seconds"]=Double(source.durationNs)/1e9
        sourceInfo["timeline_scope"]="repeated unchanged source; not a long capture"
        sourceInfo["output_scope"]="1920x1080 or 3840x2160 drawable; visible 640x360 window on one non-Retina display"
        sourceInfo["av_sync"]="unmeasured: requires identified flash/beep markers and a marked-source analyzer run; this harness does not infer markers from content"
        try write("inputs",["status":"prepared","audio":true,"export_codec":"HEVC","export_fps":60,"compression":"social","canvas_aspect":"16:9"])
        if config.mode=="all" || config.mode=="smoke" || config.mode=="preview" {
            for height in [1080,2160] { try await preview(source,height: height,seconds: config.previewSeconds,name: "preview") }
        }
        if config.mode=="all" || config.mode=="smoke" || config.mode=="scrub" {
            for height in [1080,2160] { try await scrub(source,height: height) }
        }
        if config.mode=="all" || config.mode=="smoke" || config.mode=="export" {
            try await exports(physical)
        }
        if config.soakSeconds>0 && (config.mode=="all" || config.mode=="soak") {
            try await preview(source,height: 1080,seconds: config.soakSeconds,name: "soak")
        }
        if let original,try Round3Data.fingerprints(original) != originals { throw RenderError.verification("Original recording changed during Round3 run") }
    }

    private func withView(_ source: any RenderProjectSource,height: Int,
                          operation: (PreviewPlayer,Round3View) async throws -> Void) async throws {
        let player=try PreviewPlayer(project: source,reuseVideoSeekReader: config.reuseVideoSeekReader ?? true)
        let view=Round3View(frame: NSRect(x: 0,y: 0,width: 640,height: 360),device: player.compositor.device)
        let delegate=PreviewView.Coordinator(player: player)
        view.player=player; view.colorPixelFormat = .bgra8Unorm_srgb; view.framebufferOnly=true
        view.autoResizeDrawable=false; view.drawableSize=CGSize(width: height*16/9,height: height)
        view.preferredFramesPerSecond=60; view.delegate=delegate; player.view=view
        let window=NSWindow(contentRect: view.frame,styleMask: [.titled],backing: .buffered,defer: false)
        window.isReleasedWhenClosed=false; window.contentView=view; window.orderFront(nil)
        defer { player.pause(); view.delegate=nil; window.close(); withExtendedLifetime(delegate) {} }
        try await operation(player,view)
    }
    private func ready(_ player: PreviewPlayer,label: String) async throws {
        let start=CACurrentMediaTime(),deadline=start+60
        var samples: [[String:Any]]=[],nextSample=start
        func record(_ state: PreviewAudioStartupDiagnostics,finished: Bool) throws {
            guard var row=try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String:Any] else {
                throw RenderError.verification("Invalid audio startup diagnostics")
            }
            row["elapsed_s"]=CACurrentMediaTime()-start; samples.append(row)
            try write("audio-startup-\(label)",["samples":samples,"ready":finished])
        }
        while !player.audioClockReady || player.audioClockRate==0 {
            let state=player.audioStartupDiagnostics,now=CACurrentMediaTime()
            if now>=nextSample || state.failure != nil || now>=deadline {
                try record(state,finished: false); nextSample=now+1
            }
            if let error=state.failure { throw RenderError.verification("Round3 audio startup failed (\(state.phase)): \(error)") }
            guard now<deadline else { throw RenderError.verification("Round3 audio clock did not start within 60s (phase=\(state.phase)); see audio-startup-\(label).json") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try record(player.audioStartupDiagnostics,finished: true)
    }
    private func preview(_ source: any RenderProjectSource,height: Int,seconds: Double,name: String) async throws {
        try await withView(source,height: height) { player,view in
            player.play(); try await ready(player,label: "\(name)-\(height)"); try await Task.sleep(for: .seconds(2))
            let baseline=player.metricSnapshot(), drops=player.submissionSnapshot(), presented=view.presentations.total
            guard let audioStart=player.audioClockSeconds,audioStart.isFinite else { throw RenderError.verification("Round3 audio clock is invalid") }
            let timelineStart=player.currentNs
            let start=CACurrentMediaTime(); var previous=start, previousFrames=presented
            var rows: [[String:Any]]=[]
            while CACurrentMediaTime()-start<seconds {
                try await Task.sleep(for: .seconds(min(1,seconds)))
                if let error=player.error { throw RenderError.verification(error) }
                let now=CACurrentMediaTime(), frames=view.presentations.total
                rows.append(["elapsed_s":now-start,"rss_bytes":try Round3Data.rss(),"thermal":Round3Data.thermal(),
                             "presented_fps":Double(frames-previousFrames)/max(0.000001,now-previous),
                             "dropped_submissions":player.metricSnapshot().droppedFrames-baseline.droppedFrames])
                previous=now; previousFrames=frames
            }
            let elapsed=CACurrentMediaTime()-start, final=player.metricSnapshot(), submission=player.submissionSnapshot()
            guard let audioEnd=player.audioClockSeconds,audioEnd.isFinite else { throw RenderError.verification("Round3 audio clock became invalid") }
            let audioAdvance=audioEnd-audioStart, timelineAdvance=Double(player.currentNs-timelineStart)/1e9
            let clockValid=player.audioClockReady && player.audioClockRate>0 && audioAdvance>=elapsed*0.9 && abs(timelineAdvance-audioAdvance)<0.1
            player.pause()
            let fps=Double(view.presentations.total-presented)/elapsed
            let first=rows.prefix(max(1,rows.count/4)), last=rows.suffix(max(1,rows.count/4))
            let earlyRSS=first.compactMap { $0["rss_bytes"] as? UInt64 }
            let lateRSS=last.compactMap { $0["rss_bytes"] as? UInt64 }
            let peak=rows.compactMap { $0["rss_bytes"] as? UInt64 }.max() ?? 0
            let growth=Round3Data.rssMedianGrowth(early: earlyRSS,late: lateRSS)
            try write("\(name)-\(height)",["height":height,"width":height*16/9,"elapsed_s":elapsed,
                "presented_fps":fps,"completed_fps":Double(final.renderedFrames-baseline.renderedFrames)/elapsed,
                "dropped_submissions":final.droppedFrames-baseline.droppedFrames,
                "busy_drops":submission.busy-drops.busy,"drawable_drops":submission.unavailableDrawable-drops.unavailableDrawable,
                "failed_submissions":submission.failed-drops.failed,"sampled_peak_rss_bytes":peak,
                "process_lifetime_peak_rss_bytes":try Round3Data.processPeak(),"rss_median_growth_bytes":growth,
                "audio_clock_advance_s":audioAdvance,"timeline_advance_s":timelineAdvance,"audio_playback_valid":clockValid,
                "fps_first_quarter":first.compactMap { $0["presented_fps"] as? Double }.reduce(0,+)/Double(first.count),
                "fps_last_quarter":last.compactMap { $0["presented_fps"] as? Double }.reduce(0,+)/Double(last.count),
                "samples":rows,"target_55fps_met":height != 1080 || fps>=55,
                "drop_scope":"submission reasons; nominal display callbacks missed are separate from submissions"])
            guard clockValid else { throw RenderError.verification("Presented FPS cannot count as playback acceptance: audio/timeline clock stalled or diverged") }
        }
    }
    private func scrub(_ source: any RenderProjectSource,height: Int) async throws {
        try await withView(source,height: height) { player,view in
            player.play(); try await ready(player,label: "scrub-\(height)"); player.pause()
            var seed: UInt64=0x59415043414d
            var random: [Int64]=[]
            for _ in 0..<config.scrubSamples {
                seed=seed &* 6364136223846793005 &+ 1
                random.append(Int64(seed % UInt64(source.durationNs-1)))
            }
            let sequential=(0..<config.scrubSamples).map { min(source.durationNs-1,source.durationNs/2+Int64($0)*33_333_333) }
            for (label,targets) in [("random",random),("sequential",sequential)] {
                var values: [Double]=[]
                for target in targets {
                    view.generation += 1; let generation=view.generation
                    let start=CACurrentMediaTime()
                    player.seek(toNs: target,precise: true)
                    while view.presentations.first(ns: target,generation: generation,after: start)==nil {
                        if let error=player.error { throw RenderError.verification(error) }
                        guard CACurrentMediaTime()-start<10 else { throw RenderError.verification("No presented frame after Round3 seek within 10s") }
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    let event=view.presentations.first(ns: target,generation: generation,after: start)!
                    values.append((event.time-start)*1000)
                }
                var result: [String:Any]=Round3Data.summary(values)
                result["height"]=height; result["samples_ms"]=values
                result["clock"]="CAMetalDrawable.presentedTime minus CACurrentMediaTime at precise seek request"
                result["target_p95_150ms_met"]=(Round3Data.percentile(values,0.95) ?? .infinity)<=150
                try write("scrub-\(label)-\(height)",result)
            }
        }
    }
    private func exports(_ source: any RenderProjectSource) async throws {
        let end=config.exportSeconds.map { min(source.durationNs,Int64($0*1e9)) } ?? source.durationNs
        var published: URL?
        var publishedHash: String?
        for height in [1080,2160] {
            let output=work.appendingPathComponent("export-\(height).mp4")
            try await oneExport(source,height: height,end: end,output: output,label: "export-\(height)")
            if height==1080 { published=output; publishedHash=try Round3Data.hash(output) }
        }
        let cancelled=work.appendingPathComponent("cancelled.mp4")
        let exporter=try Exporter(project: source,settings: settings(2160,end: end),destination: cancelled,videoPipelineDepth: config.videoPipelineDepth ?? 2,callbackVideo: config.callbackVideo ?? true)
        let cancel=Round3Cancellation()
        let task=Task { try await exporter.run { cancel.progress($0) } }
        cancel.attach(task)
        do { _ = try await task.value; throw RenderError.verification("Mid-export cancellation was not exercised") }
        catch is CancellationError { }
        guard cancel.triggered, !FileManager.default.fileExists(atPath: cancelled.path),
              !(try FileManager.default.contentsOfDirectory(atPath: work.path)).contains(where: { $0.hasPrefix(".yapcam-export-") }) else {
            throw RenderError.verification("Cancellation left an output/partial file or did not reach 25 percent")
        }
        try await oneExport(source,height: 2160,end: end,output: work.appendingPathComponent("reexport.mp4"),label: "reexport")
        guard let published,try Round3Data.hash(published)==publishedHash else { throw RenderError.verification("Cancellation/re-export changed a completed original export") }
        try write("cancel-reexport",["cancelled_at_fraction":cancel.fraction,"partial_cleanup":true,"completed_export_intact":true,"reexport_valid":true])
    }
    private func settings(_ height: Int,end: Int64) -> ExportSettings {
        .init(format: .mp4,codec: .hevc,outputHeight: height,fps: 60,includeAudio: true,rangeStartNs: 0,rangeEndNs: end,compression: .social)
    }
    private func oneExport(_ source: any RenderProjectSource,height: Int,end: Int64,output: URL,label: String) async throws {
        let exporter=try Exporter(project: source,settings: settings(height,end: end),destination: output,videoPipelineDepth: config.videoPipelineDepth ?? 2,callbackVideo: config.callbackVideo ?? true)
        let task=Task { try await exporter.run { _ in } }
        var samples: [[String:Any]]=[]
        let start=CACurrentMediaTime()
        let monitor=Task { @MainActor in
            while !Task.isCancelled {
                samples.append(["elapsed_s":CACurrentMediaTime()-start,"rss_bytes":try Round3Data.rss(),"thermal":Round3Data.thermal()])
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { monitor.cancel() }
        _ = try await task.value
        monitor.cancel(); _ = try? await monitor.value
        let asset=AVURLAsset(url: output)
        let duration=try await asset.load(.duration).seconds
        let audio=try await asset.loadTracks(withMediaType: .audio)
        guard !audio.isEmpty,abs(duration-Double(end)/1e9)<=1.0/60+0.005,let metrics=exporter.metrics else {
            throw RenderError.verification("Export verification failed duration/audio check")
        }
        let stageEncoder=JSONEncoder(); stageEncoder.keyEncodingStrategy = .convertToSnakeCase
        if let retained=config.retainedExports {
            let directory=URL(fileURLWithPath: retained,isDirectory: true)
            try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: output,to: directory.appendingPathComponent(label+".mp4"))
            try JSONSerialization.data(withJSONObject: ["input_fingerprints":sourceInfo["input_fingerprints"] ?? [:],"revision":config.revision],options: [.sortedKeys]).write(to: directory.appendingPathComponent("manifest.json"),options: .atomic)
        }
        try write(label,["height":height,"width":height*16/9,"media_seconds":metrics.mediaSeconds,
            "video_stages":try JSONSerialization.jsonObject(with: stageEncoder.encode(exporter.videoDiagnostics)),
            "elapsed_s":metrics.elapsedSeconds,"x_realtime":metrics.mediaSeconds/metrics.elapsedSeconds,
            "sampled_peak_rss_bytes":samples.compactMap { $0["rss_bytes"] as? UInt64 }.max() ?? 0,
            "process_lifetime_peak_rss_bytes":try Round3Data.processPeak(),"thermal_samples":samples,
            "audio_tracks":audio.count,"verified_duration_s":duration,"target_4k_realtime_met":height != 2160 || metrics.mediaSeconds>=metrics.elapsedSeconds])
    }
}

private final class Round3Cancellation: @unchecked Sendable {
    private let lock=NSLock()
    private var task: Task<URL,Error>?
    private var storedFraction=0.0
    var fraction: Double { lock.withLock { storedFraction } }
    var triggered: Bool { lock.withLock { storedFraction>=0.25 && storedFraction<1 } }
    func attach(_ task: Task<URL,Error>) { lock.withLock { self.task=task } }
    func progress(_ value: Double) { lock.withLock {
        guard value>=0.25,storedFraction==0 else { return }; storedFraction=value; task?.cancel()
    } }
}
#endif
