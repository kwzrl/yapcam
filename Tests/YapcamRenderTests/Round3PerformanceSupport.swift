import Foundation
import CryptoKit
import Darwin
@preconcurrency import AVFoundation
import YapcamCore
@testable import YapcamRender

struct Round3Configuration: Codable, Sendable {
    var mode: String
    var source: String
    var revision: String
    var harnessHash: String
    var originalPackage: String?
    var workDirectory: String
    var resultsDirectory: String
    var token: String
    var previewSeconds: Double
    var soakSeconds: Double
    var scrubSamples: Int
    var syntheticSeconds: Double
    var exportSeconds: Double?
    var videoPipelineDepth: Int?
}

enum Round3Data {
    static func rssMedianGrowth(early: [UInt64],late: [UInt64]) -> Double {
        // Double.init as a function value can select init(bitPattern:) for
        // UInt64. RSS is a byte count, so require numeric conversion explicitly.
        (percentile(late.map { Double($0) },0.5) ?? 0)-(percentile(early.map { Double($0) },0.5) ?? 0)
    }
    static func percentile(_ samples: [Double], _ fraction: Double) -> Double? {
        let sorted = samples.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let index = max(0,min(sorted.count-1,Int(ceil(Double(sorted.count)*fraction))-1))
        return sorted[index]
    }
    static func summary(_ samples: [Double]) -> [String: Double] {
        ["p50_ms":percentile(samples,0.5) ?? 0,"p95_ms":percentile(samples,0.95) ?? 0,"max_ms":samples.max() ?? 0]
    }
    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
    static func rss() throws -> UInt64 {
        var info=mach_task_basic_info(), count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
        let result=withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self,capacity: Int(count)) {
                task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)
            }
        }
        guard result == KERN_SUCCESS else { throw RenderError.unavailable("Round3 RSS task_info failed: \(result)") }
        return UInt64(info.resident_size)
    }
    static func processPeak() throws -> UInt64 {
        var usage=rusage()
        guard getrusage(RUSAGE_SELF,&usage)==0 else { throw RenderError.unavailable("Round3 getrusage failed") }
        return UInt64(usage.ru_maxrss)
    }
    static func hash(_ url: URL) throws -> String {
        let file=try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash=SHA256()
        while let data=try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x",$0) }.joined()
    }
    static func fingerprints(_ root: URL) throws -> [String:String] {
        guard let paths=FileManager.default.enumerator(at: root,includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey]) else {
            throw RenderError.missingMedia("Round3 source package cannot be enumerated")
        }
        var values: [String:String]=[:]
        for case let file as URL in paths {
            let properties=try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else { throw RenderError.invalidSettings("Round3 source may not contain symlinks") }
            if properties.isRegularFile == true { values[String(file.path.dropFirst(root.path.count+1))]=try hash(file) }
        }
        return values
    }
}

/// Only stores presentation metadata, not images. A redraw can ask MTKView for
/// the same drawable more than once; its native presentation is counted once.
final class Round3Presentations: @unchecked Sendable {
    struct Event: Sendable {
        var ns: Int64
        var generation: Int
        var time: Double
        var drawable: Int
    }
    private struct Identity: Hashable { var drawable: Int; var time: Double }
    private let lock=NSLock()
    private var seen=Set<Identity>()
    private var events: [Event]=[]
    private var count=0
    func record(_ event: Event) {
        guard event.time.isFinite, event.time>0 else { return }
        lock.withLock {
            let key=Identity(drawable: event.drawable,time: event.time)
            guard seen.insert(key).inserted else { return }
            count += 1; events.append(event)
            if events.count>4096 { events.removeFirst(2048); seen=Set(events.map { Identity(drawable: $0.drawable,time: $0.time) }) }
        }
    }
    var total: Int { lock.withLock { count } }
    func first(ns: Int64,generation: Int,after requested: Double) -> Event? {
        lock.withLock { events.first { $0.ns==ns && $0.generation==generation && $0.time>=requested } }
    }
}

/// Immutable repeated timeline over the actual decoded source. This changes no
/// recording and is explicitly reported as repetition, never as a long capture.
final class Round3RepeatedSource: RenderProjectSource, @unchecked Sendable {
    let base: any RenderProjectSource
    let durationNs: Int64
    var packageURL: URL { base.packageURL }
    init(base: any RenderProjectSource,minimumSeconds: Double) throws {
        self.base=try base.renderSnapshot()
        guard base.durationNs>0,minimumSeconds.isFinite,minimumSeconds>0,minimumSeconds<86_400 else {
            throw RenderError.invalidSettings("Invalid Round3 repeated source duration")
        }
        let requested=Int64(ceil(minimumSeconds*1e9))
        let copies=max(1,(requested+base.durationNs-1)/base.durationNs)
        let span=base.durationNs.multipliedReportingOverflow(by: copies)
        guard !span.overflow else { throw RenderError.invalidSettings("Round3 timeline overflow") }
        durationNs=span.partialValue
    }
    private func local(_ ns: Int64) -> Int64 { max(0,min(ns,durationNs-1)) % base.durationNs }
    func frame(atNs ns: Int64) throws -> YcFrame { var f=try base.frame(atNs: local(ns)); f.tl_ns=ns; return f }
    func renderSnapshot() throws -> any RenderProjectSource { self }
    var renderConfiguration: RenderConfiguration { base.renderConfiguration }
    func renderLayers(atNs ns: Int64) throws -> [RenderLayer] { try base.renderLayers(atNs: local(ns)) }
    func renderEffects(atNs ns: Int64,canvasSize: CGSize) throws -> RenderFrameEffects { try base.renderEffects(atNs: local(ns),canvasSize: canvasSize) }
    func renderBackgroundAsset(index: UInt32) throws -> URL { try base.renderBackgroundAsset(index: index) }
    func renderStereoMicrophone() throws -> Bool { try base.renderStereoMicrophone() }
    func renderClips() throws -> [RenderClip] {
        let clips=try base.renderClips()
        return (0..<Int(durationNs/base.durationNs)).flatMap { _ in clips }
    }
    func renderAudioRanges() throws -> [RenderAudioRange]? {
        guard let ranges=try base.renderAudioRanges() else { throw RenderError.unavailable("Round3 requires explicit Core audio ranges") }
        return (0..<Int(durationNs/base.durationNs)).flatMap { copy in
            let offset=Int64(copy)*base.durationNs
            return ranges.map { original in
                var range=original; range.tlStartNs += offset; range.tlEndNs += offset; return range
            }
        }
    }
}

/// FFmpeg/ffprobe children are owned by this instance only. All diagnostics and
/// generated media live in the caller's render-owned scratch directory.
final class Round3Child: @unchecked Sendable {
    private let process=Process()
    private let lock=NSLock()
    private var done=false
    private var expired=false
    func run(_ executable: String,_ arguments: [String],in directory: URL,timeout: Double=900) throws -> Data {
        let id=UUID().uuidString
        let output=directory.appendingPathComponent("child-\(id).out"), errors=directory.appendingPathComponent("child-\(id).err")
        FileManager.default.createFile(atPath: output.path,contents: nil)
        FileManager.default.createFile(atPath: errors.path,contents: nil)
        let out=try FileHandle(forWritingTo: output), err=try FileHandle(forWritingTo: errors)
        defer {
            try? out.close(); try? err.close()
            for url in [output,errors] { print("Cleanup render-owned child log: \(url.lastPathComponent)"); try? FileManager.default.removeItem(at: url) }
        }
        process.executableURL=URL(fileURLWithPath: executable); process.arguments=arguments
        process.standardInput=FileHandle.nullDevice; process.standardOutput=out; process.standardError=err
        try process.run()
        let timer=DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now()+timeout)
        timer.setEventHandler { [self] in lock.withLock {
            guard !done,process.isRunning else { return }; expired=true
            _ = Darwin.kill(process.processIdentifier,SIGKILL)
        } }
        timer.resume(); defer { timer.cancel() }
        process.waitUntilExit()
        let timedOut=lock.withLock { done=true; return expired }
        guard !timedOut,process.terminationStatus==0 else {
            let detail=String(decoding: (try Data(contentsOf: errors)).suffix(4096),as: UTF8.self)
            throw RenderError.verification("Round3 child failed or timed out: \(detail)")
        }
        return try Data(contentsOf: output)
    }
}

enum Round3Synthetic {
    static func create(at package: URL,seconds: Double=120) throws {
        let recording=package.appendingPathComponent("recording")
        try FileManager.default.createDirectory(at: recording,withIntermediateDirectories: true)
        let label=recording.appendingPathComponent("own-label.ppm")
        // Original five-by-seven glyphs, drawn by us; no third-party text asset.
        let glyphs: [[String]] = [["10010","10010","10010","11111","00010","00010","00010"],
            ["10001","10010","10100","11000","10100","10010","10001"],
            ["01110","10000","10000","11110","10001","10001","01110"],
            ["01110","10001","10011","10101","11001","10001","01110"]]
        let width=208,height=72, scale=8
        var pixels=[UInt8](repeating: 16,count: width*height*3)
        for (g,rows) in glyphs.enumerated() { for (y,row) in rows.enumerated() { for (x,c) in row.enumerated() where c=="1" {
            for dy in 0..<scale { for dx in 0..<scale {
                let start=((y*scale+8+dy)*width+(g*48+x*scale+8+dx))*3
                for channel in 0..<3 { pixels[start+channel]=255 }
            } }
        } } }
        var ppm=Data("P6\n\(width) \(height)\n255\n".utf8); ppm.append(contentsOf: pixels); try ppm.write(to: label)
        let movie=recording.appendingPathComponent("screen.mov")
        _ = try Round3Child().run("/opt/homebrew/bin/ffmpeg",["-nostdin","-v","error","-filter_complex_threads","1",
            "-f","lavfi","-i","testsrc2=size=3840x2160:rate=60:duration=\(seconds)",
            "-loop","1","-framerate","60","-i",label.path,
            "-f","lavfi","-i","sine=frequency=1000:sample_rate=48000:duration=\(seconds)",
            "-filter_complex","[0:v][1:v]overlay=32:32:shortest=1[v]","-map","[v]","-map","2:a",
            "-c:v","libx265","-preset","ultrafast","-crf","28","-x265-params","pools=4:frame-threads=2:log-level=error",
            "-c:a","aac","-b:a","192k","-r","60","-t",String(seconds),"-tag:v","hvc1","-movflags","+faststart",movie.path],in: recording,timeout: 3600)
        let session: [String:Any]=["schema_version":1,"app_version":"round3","created_at":"2026-10-16T00:00:00Z","status":"complete",
            "source":["kind":"display","display_id":1,"display_name":"Synthetic 4K","content_rect_points":[0,0,3840,2160],"scale":1.0],
            "tracks":["screen":["pixel_size":[3840,2160],"max_fps":60,"codec":"hevc","cursor_in_video":false],
                      "camera":NSNull(),"mic":NSNull(),"system_audio":["sample_rate":48000,"channels":1]],
            "segments":[["index":0,"dir":"","src_start_ns":0,"duration_ns":Int64((seconds*1e9).rounded()),"host_start_ns":0,
                         "files":["screen":"screen.mov","system_audio":"screen.mov"],"track_start_ns":["screen":0,"system_audio":0]]]]
        try JSONSerialization.data(withJSONObject: session).write(to: recording.appendingPathComponent("session.json"))
    }
}
