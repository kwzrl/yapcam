import XCTest
@testable import YapcamRender

final class RenderConfigurationTests: XCTestCase {
    func testConcurrentDefaultsAndCopiesOwnTheirReferenceStorage() {
        let failures=ConfigurationFailures()
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            let url=URL(fileURLWithPath: "/configuration-fixture/\(worker)/"+String(repeating: "owned-lut-",count: 16)+".cube")
            for iteration in 0..<10_000 {
                let baseline=RenderConfiguration()
                // Exercise the exact cross-module default-argument call path in F15.
                let source=TestSource(package: url)
                var edited=baseline
                edited.cursorSetID=String(repeating: "owned-cursor-",count: 16)+"\(worker)-\(iteration)"
                edited.cursorVariants["arrow"] = .alternate
                edited.cursorPressed=true
                edited.cameraColor.lutURL=url
                var copy=edited
                copy.cursorVariants["pointer"] = .alternate
                copy.cameraColor.lutURL=nil
                let effects=RenderFrameEffects(configuration: edited)
                if baseline != RenderConfiguration() || source.renderConfiguration != baseline ||
                    !baseline.cursorVariants.isEmpty || baseline.cursorSetID != nil || baseline.cameraColor.lutURL != nil ||
                    edited.cursorVariants.count != 1 || copy.cursorVariants.count != 2 ||
                    edited.cameraColor.lutURL != url || copy.cameraColor.lutURL != nil || effects.configuration != edited {
                    failures.record(); break
                }
            }
        }
        XCTAssertEqual(failures.count,0,"Independent default values and copies must not share mutable storage")
    }
}

private final class ConfigurationFailures: @unchecked Sendable {
    private let lock=NSLock()
    private var value=0
    func record() { lock.withLock { value+=1 } }
    var count: Int { lock.withLock { value } }
}
