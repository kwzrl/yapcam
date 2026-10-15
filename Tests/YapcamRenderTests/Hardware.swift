import XCTest
import Metal
import Foundation
@testable import YapcamRender

func requireRenderDevice() throws -> MTLDevice {
    if let device=MTLCreateSystemDefaultDevice() { return device }
    let reason="Metal/media services unavailable in this execution environment; host verification required"
    if ProcessInfo.processInfo.environment["YAPCAM_REQUIRE_RENDER_HARDWARE"] == "1" { throw RenderError.unavailable(reason) }
    throw XCTSkip(reason)
}

/// Do not open benchmark windows while QA owns the shared Yapcam app/session.
/// This only reads the lock; QA alone releases it. Call before NSApplication.
func requireLivePreviewAccess(
    lockURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Yapcam/QA/.app-lock"),
    strict: Bool = ProcessInfo.processInfo.environment["YAPCAM_REQUIRE_RENDER_HARDWARE"] == "1"
) throws {
    guard FileManager.default.fileExists(atPath: lockURL.path) else { return }
    let reason="QA owns Yapcam while ~/Movies/Yapcam/QA/.app-lock exists; postpone live preview windows until QA releases it"
    if strict { throw RenderError.unavailable(reason) }
    throw XCTSkip(reason)
}

/* Host verification: CARGO_BUILD_JOBS=4 scripts/build-core.sh, then
   YAPCAM_REQUIRE_RENDER_HARDWARE=1 swift test --disable-sandbox -j 4 --filter YapcamRenderTests.
   Strict mode fails instead of skipping absent Metal. Normal agent runs report skips explicitly.
   ExportSyncTests emits RENDER_BENCHMARK elapsed_s and export_x_realtime for decoded video.
   PreviewPerformanceTests emits RENDER_PREVIEW_BENCHMARK fps from a visible MTKView at 1080p/4K.
   The strict host gate includes that window test; opt in separately with YAPCAM_RENDER_LIVE_PREVIEW=1.
   Workload is the small synthetic fixture with zoom/shadow, no audio; native 4K decode is unmeasured.
   Test media is synthetic and deleted from unique temporary folders after each test.
*/
