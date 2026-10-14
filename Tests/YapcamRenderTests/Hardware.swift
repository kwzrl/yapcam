import XCTest
import Metal
@testable import YapcamRender

func requireRenderDevice() throws -> MTLDevice {
    if let device=MTLCreateSystemDefaultDevice() { return device }
    let reason="Metal/media services unavailable in this execution environment; host verification required"
    if ProcessInfo.processInfo.environment["YAPCAM_REQUIRE_RENDER_HARDWARE"] == "1" { throw RenderError.unavailable(reason) }
    throw XCTSkip(reason)
}

/* Host verification: CARGO_BUILD_JOBS=4 scripts/build-core.sh, then
   YAPCAM_REQUIRE_RENDER_HARDWARE=1 swift test --disable-sandbox -j 4 --filter YapcamRenderTests.
   Strict mode fails instead of skipping absent Metal. Normal agent runs report skips explicitly.
   ExportSyncTests emits RENDER_BENCHMARK elapsed_s and export_x_realtime for a uniform 2s canvas.
   PreviewPlayer.metrics measures a real MTKView; this must be measured separately at 1080p/4K.
   Test media is synthetic and deleted from unique temporary folders after each test.
*/
