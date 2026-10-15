import Foundation
import Darwin
import XCTest
@testable import YapcamRender

/// Export-interval RSS samples, separate from the process-lifetime high-water mark.
/// Run each long benchmark in a separate test process to keep other tests out of RSS.
final class RenderMemoryMonitor: @unchecked Sendable {
    struct Sample: Sendable {
        let elapsed: Double
        let progress: Double
        let bytes: UInt64
    }
    struct Report {
        let samples: [Sample]
        let processPeak: UInt64 // Darwin ru_maxrss is bytes, not KiB.
        var peak: UInt64 { samples.map(\.bytes).max() ?? 0 }
        func median(in range: ClosedRange<Double>) -> Double? {
            let values=samples.filter { range.contains($0.progress) }.map { Double($0.bytes) }.sorted()
            guard !values.isEmpty else { return nil }
            let middle=values.count/2
            return values.count.isMultiple(of: 2) ? (values[middle-1]+values[middle])/2 : values[middle]
        }
        var steadyGrowth: Double? {
            guard let early=median(in: 0.2...0.4), let late=median(in: 0.8...0.95) else { return nil }
            return late-early
        }
        func slopeBytesPerMediaMinute(duration: Double) -> Double? {
            let rows=samples.filter { (0.2...0.95).contains($0.progress) }
            guard rows.count>=3 else { return nil }
            let xs=rows.map { $0.progress*duration/60 }, ys=rows.map { Double($0.bytes) }
            let mx=xs.reduce(0,+)/Double(xs.count), my=ys.reduce(0,+)/Double(ys.count)
            let variance=xs.reduce(0) { $0+($1-mx)*($1-mx) }
            guard variance>0 else { return nil }
            return zip(xs,ys).reduce(0) { $0+($1.0-mx)*($1.1-my) }/variance
        }
    }
    private let lock=NSLock()
    private let queue=DispatchQueue(label: "mov.yapcam.render.rss")
    private let timer: DispatchSourceTimer
    private let start=ProcessInfo.processInfo.systemUptime
    private var progress=0.0
    private var rows: [Sample]=[]
    private var failure: String?
    init(interval: Double = 0.5) throws {
        let bytes=try Self.residentBytes()
        rows=[Sample(elapsed: 0,progress: 0,bytes: bytes)]
        timer=DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now()+interval,repeating: interval)
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }
    deinit { timer.cancel() }
    func markProgress(_ value: Double) { lock.withLock { progress=value } }
    private func sample() {
        do {
            let bytes=try Self.residentBytes(), elapsed=ProcessInfo.processInfo.systemUptime-start
            lock.withLock {
                // At 2Hz this holds over four hours without unbounded monitor growth.
                if rows.count>=32768 { rows=rows.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element) }
                rows.append(Sample(elapsed: elapsed,progress: progress,bytes: bytes))
            }
        } catch { lock.withLock { failure=error.localizedDescription } }
    }
    func finish() throws -> Report {
        timer.cancel(); queue.sync {}; sample()
        var usage=rusage()
        guard getrusage(RUSAGE_SELF,&usage)==0 else { throw RenderError.unavailable("Cannot read process peak RSS") }
        return try lock.withLock {
            if let failure { throw RenderError.unavailable(failure) }
            return Report(samples: rows,processPeak: UInt64(usage.ru_maxrss))
        }
    }
    static func residentBytes() throws -> UInt64 {
        var info=mach_task_basic_info(), count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
        let result=withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self,capacity: Int(count)) {
                task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)
            }
        }
        guard result==KERN_SUCCESS else { throw RenderError.unavailable("task_info RSS failed (\(result))") }
        return UInt64(info.resident_size)
    }
}

/// Logs contain metrics only. All synthetic media remain in temporary directories.
enum RenderM3Artifacts {
    static func write(_ name: String,values: [String: Any],memory: RenderMemoryMonitor.Report? = nil) throws {
        let environment=ProcessInfo.processInfo.environment
        let directory: URL
        if let path=environment["YAPCAM_RENDER_M3_RESULTS_DIR"] { directory=URL(fileURLWithPath: path,isDirectory: true) }
        else {
            directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Yapcam/render-m3",isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let stem="\(name)-\(UUID().uuidString)"
        var record=values
        record["os"]=ProcessInfo.processInfo.operatingSystemVersionString
        record["logical_cpus"]=ProcessInfo.processInfo.activeProcessorCount
        record["revision"]=environment["YAPCAM_RENDER_M3_REVISION"] ?? "unspecified"
        record["timestamp_utc"]=ISO8601DateFormatter().string(from: Date())
        #if DEBUG
        record["build_configuration"]="debug"
        #else
        record["build_configuration"]="release"
        #endif
        try JSONSerialization.data(withJSONObject: record,options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent(stem+".json"),options: .atomic)
        if let memory {
            let csv="elapsed_s,media_progress,resident_bytes\n"+memory.samples.map { "\($0.elapsed),\($0.progress),\($0.bytes)" }.joined(separator: "\n")+"\n"
            try csv.write(to: directory.appendingPathComponent(stem+".csv"),atomically: true,encoding: .utf8)
        }
        let line=try JSONSerialization.data(withJSONObject: record,options: [.sortedKeys])
        print("RENDER_M3 \(name) \(String(decoding: line,as: UTF8.self)) artifacts=\(directory.appendingPathComponent(stem).path)")
    }
    static func requireLongRun() throws {
        guard ProcessInfo.processInfo.environment["YAPCAM_RENDER_M3"]=="1" else {
            throw XCTSkip("Set YAPCAM_RENDER_M3=1 for the 10/30-minute media exports and audio preview benchmarks")
        }
    }
}

final class RenderMemoryMonitorTests: XCTestCase {
    func testResidentMeasurementAndSteadyGrowthDistinguishBoundedMemoryFromALeak() async throws {
        let monitor=try RenderMemoryMonitor(interval: 0.01)
        monitor.markProgress(0.3)
        try await Task.sleep(for: .milliseconds(40))
        let actual=try monitor.finish()
        XCTAssertGreaterThan(actual.peak,0); XCTAssertGreaterThan(actual.processPeak,0)
        XCTAssertGreaterThan(actual.samples.count,1)
        let flat=(0...100).map { RenderMemoryMonitor.Sample(elapsed: Double($0),progress: Double($0)/100,bytes: 128*1024*1024) }
        let bounded=RenderMemoryMonitor.Report(samples: flat,processPeak: 128*1024*1024)
        XCTAssertEqual(bounded.steadyGrowth,0)
        XCTAssertEqual(try XCTUnwrap(bounded.slopeBytesPerMediaMinute(duration: 1800)),0,accuracy: 0.001)
        let rising=flat.enumerated().map { RenderMemoryMonitor.Sample(elapsed: $0.element.elapsed,progress: $0.element.progress,bytes: $0.element.bytes+UInt64($0.offset)*1024*1024) }
        let leak=RenderMemoryMonitor.Report(samples: rising,processPeak: rising.last!.bytes)
        XCTAssertGreaterThan(try XCTUnwrap(leak.steadyGrowth),50*1024*1024)
        XCTAssertEqual(try XCTUnwrap(leak.slopeBytesPerMediaMinute(duration: 1800)),100*1024*1024/30,accuracy: 0.001)
    }
}
