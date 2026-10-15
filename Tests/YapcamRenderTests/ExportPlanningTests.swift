import XCTest
@testable import YapcamRender

final class ExportPlanningTests: XCTestCase {
    func testEstimatesMatchActualRangeDimensionsAudioAndBothOutputs() throws {
        let settings = ExportSettings(rangeStartNs: 5_000_000_000,rangeEndNs: 15_000_000_000)
        let estimate = try settings.estimate(canvasWidth: 16,canvasHeight: 9,durationNs: 60_000_000_000,hasAudio: true)
        XCTAssertEqual(estimate.width,1280); XCTAssertEqual(estimate.height,720)
        XCTAssertEqual(estimate.fps,60); XCTAssertEqual(estimate.frames,600)
        XCTAssertEqual(estimate.mediaSeconds,10)
        XCTAssertEqual(estimate.fileBytes,[3_696_000])
        XCTAssertEqual(estimate.totalBytes,3_696_000)
        XCTAssertEqual(estimate.renderSeconds,2.21184,accuracy: 0.000001)
        let silent = try settings.estimate(canvasWidth: 16,canvasHeight: 9,durationNs: 60_000_000_000,hasAudio: false)
        XCTAssertEqual(estimate.totalBytes-silent.totalBytes,240_000)
        var pair = settings; pair.codec = .both; pair.quality = 0.5
        let both = try pair.estimate(canvasWidth: 16,canvasHeight: 9,durationNs: 60_000_000_000,hasAudio: false)
        XCTAssertEqual(both.fileBytes.count,2)
        XCTAssertEqual(Double(both.fileBytes[1]),Double(both.fileBytes[0])*0.65,accuracy: 1)
        XCTAssertEqual(both.renderSeconds,estimate.renderSeconds*2,accuracy: 0.000001)
        let clipboard = try pair.estimate(canvasWidth: 16,canvasHeight: 9,durationNs: 60_000_000_000,hasAudio: false,target: .clipboard)
        XCTAssertEqual(clipboard.fileBytes,[both.fileBytes[0]])
        XCTAssertEqual(clipboard.renderSeconds,estimate.renderSeconds,accuracy: 0.000001)
    }
    func testGIFEstimateUsesEffectiveFrameGridAndCapAndRejectsInvalidInput() throws {
        let gif = try ExportSettings(format: .gif).estimate(canvasWidth: 16,canvasHeight: 9,durationNs: 1_000_000_000,hasAudio: true)
        XCTAssertEqual(gif.width,852); XCTAssertEqual(gif.height,480)
        XCTAssertEqual(gif.frames,15); XCTAssertEqual(gif.fileBytes,[406_404])
        let old = try ExportSettings(format: .gif,outputHeight: 720,fps: 24).estimate(canvasWidth: 16,canvasHeight: 9,durationNs: 700_000_000,hasAudio: true)
        XCTAssertEqual(old.fps,20); XCTAssertEqual(old.frames,14)
        let tiny = try ExportSettings().estimate(canvasWidth: 1,canvasHeight: 1,durationNs: 1,hasAudio: false)
        XCTAssertEqual(tiny.frames,1)
        let cap = try ExportSettings(outputHeight: 2160).estimate(canvasWidth: 21,canvasHeight: 9,durationNs: 1_000_000_000,hasAudio: false)
        XCTAssertEqual(cap.width,3840); XCTAssertEqual(cap.height,1644)
        for rate in [0,Double.nan,Double.infinity,-1] {
            XCTAssertThrowsError(try ExportSettings().estimate(canvasWidth: 16,canvasHeight: 9,durationNs: 1,hasAudio: false,pixelsPerSecond: rate))
        }
        for settings in [ExportSettings(quality: .nan),ExportSettings(fps: 0),ExportSettings(rangeEndNs: 2)] {
            XCTAssertThrowsError(try settings.estimate(canvasWidth: 16,canvasHeight: 9,durationNs: 1,hasAudio: false))
        }
    }
    func testFIFOQueueRunsOnlyOneOperationAtATimeAndNotifiesWaiters() async throws {
        let scheduler=ExportScheduler(), entered=Signal(), release=Signal(), secondQueued=Signal(), thirdQueued=Signal(), trace=Trace()
        let first=Task {
            try await scheduler.run(waiting: { XCTFail("First job should be admitted") }) {
                await trace.enter(1); await entered.open(); await release.wait(); await trace.leave(); return 1
            }
        }
        await entered.wait()
        let second=Task { try await scheduler.run(waiting: { Task { await secondQueued.open() } }) { await trace.enter(2); await trace.leave(); return 2 } }
        await secondQueued.wait()
        let third=Task { try await scheduler.run(waiting: { Task { await thirdQueued.open() } }) { await trace.enter(3); await trace.leave(); return 3 } }
        await thirdQueued.wait()
        let waiting=await scheduler.waitingCount
        XCTAssertEqual(waiting,2)
        await release.open()
        let values=try await [first.value,second.value,third.value]
        XCTAssertEqual(values,[1,2,3])
        let order=await trace.order, maximum=await trace.maximum
        XCTAssertEqual(order,[1,2,3]); XCTAssertEqual(maximum,1)
    }
    func testWaitingCancellationAndGrantRaceNeverLeakOrOverRelease() async throws {
        let scheduler=ExportScheduler()
        for _ in 0..<40 {
            let entered=Signal(), release=Signal(), queued=Signal()
            let first=Task { try await scheduler.run(waiting: {}) { await entered.open(); await release.wait(); return 1 } }
            await entered.wait()
            let second=Task { try await scheduler.run(waiting: { Task { await queued.open() } }) { try Task.checkCancellation(); return 2 } }
            await queued.wait()
            second.cancel(); await release.open()
            _ = try await first.value
            do { _ = try await second.value; XCTFail("Waiting cancellation must prevent execution") }
            catch is CancellationError { }
            let next=try await scheduler.run(waiting: { XCTFail("Leaked active permit") }) { 3 }
            XCTAssertEqual(next,3)
            let remaining=await scheduler.waitingCount
            XCTAssertEqual(remaining,0)
        }
    }
    func testThrowingOperationAndExporterFailureReturnTheGlobalPermit() async throws {
        let scheduler=ExportScheduler()
        enum Failure: Error { case injected }
        do { let _: Int=try await scheduler.run(waiting: {}) { throw Failure.injected }; XCTFail() }
        catch Failure.injected { }
        let next=try await scheduler.run(waiting: { XCTFail("Throwing job stranded queue") }) { 4 }
        XCTAssertEqual(next,4)
        let phases=Phases()
        // Empty canvas fails before touching Metal, files or a decoder.
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-no-file-\(UUID().uuidString)")
        let source=TestSource(package: root,evaluate: { _ in YcFrame() })
        for _ in 0..<2 {
            let exporter=try Exporter(project: source,settings: .init(),destination: root.appendingPathComponent("unused.mp4"))
            do { _ = try await exporter.run(progress: { _ in XCTFail("Failure preceded rendering") },status: { phases.add($0) }); XCTFail() }
            catch RenderError.invalidSettings { }
        }
        XCTAssertEqual(phases.values.filter { $0 == .preparing }.count,2)
        XCTAssertEqual(phases.values.filter { if case .failed = $0 { true } else { false } }.count,2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    private actor Signal {
        private var opened=false
        private var continuations: [CheckedContinuation<Void,Never>]=[]
        func wait() async { if opened { return }; await withCheckedContinuation { continuations.append($0) } }
        func open() { opened=true; let pending=continuations; continuations=[]; for c in pending { c.resume() } }
    }
    private actor Trace {
        var order: [Int]=[], maximum=0
        private var active=0
        func enter(_ id: Int) { order.append(id); active += 1; maximum=max(maximum,active) }
        func leave() { active -= 1 }
    }
    private final class Phases: @unchecked Sendable {
        private let lock=NSLock()
        private var phases: [ExportPhase]=[]
        func add(_ value: ExportPhase) { lock.lock(); defer { lock.unlock() }; phases.append(value) }
        var values: [ExportPhase] { lock.lock(); defer { lock.unlock() }; return phases }
    }
}
