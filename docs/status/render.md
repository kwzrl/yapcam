READY 64641bb Renderer checkpoint builds; latest owned M1 adapter/M2 hardening awaits Lead checkpoint/rebase
ACTION Lead: audio export hang reported by editor is addressed in latest uncommitted Exporter.swift via independent audio/video pumps + cancellation handler + 30s readiness bound. Host recheck required. Checkpoint owned changes and rebase team/render onto main; shared Git writes still denied.

# render status

## Done (verified)
- Shared Metal compositor, IOSurface decoder/cache, preview clock/audio/view, offline MP4/MOV/GIF exporter and M2 range/quality/bitrate/presets compile with swift build --disable-sandbox -j 4.
- Stable signed app build passed: PATH temporary Swift wrapper adds --disable-sandbox -j 4 to scripts/build-app.sh; CARGO_BUILD_JOBS=4. First build signed Yapcam Local Dev. Lead subsequently moved identity to Yapcam Dev Signing on main; old-worktree helper fell back to ad-hoc once. That bundle was not launched; rebuilt with explicit Yapcam Dev Signing override and codesign confirms Authority=Yapcam Dev Signing (no ad-hoc flag). No TCC reset calls or permission dialogs triggered.
- Root swift test --disable-sandbox -j 4 passed (ABI test; root still awaits test-target integration via rebase); CARGO_BUILD_JOBS=4 cargo test --manifest-path core/Cargo.toml passed.
- Render tests run through a temporary /tmp validation manifest that adds Lead-owned missing target without changing repo Package.swift: 29 tests in real-core harness, 16 passed, 13 explicitly skipped because Metal device is unavailable. Settings validation and cancellation/existing-file preservation passed. GPU tests are NOT verified.

- Both Metal shaders compile offline with xcrun metal -fmodules-cache-path=/tmp/yapcam-render-metal-cache. No GPU runtime claim.
- Audio composition checks now include cuts/speeds/ranges/pauses, original procedural click/music samples, loop/fade mapping and silence tail after device loss.

## In progress
- M1: exact Project initializers + change notification observation compile in real-core harness; manual zoom, cut/speed/audio mapping and independent snapshot tests pass. Temporary compile guard remains until worktree rebase. Preview decoding now runs off MainActor with one in-flight frame and redraw revision handling.
- M2: GIF/range/preset controls implemented, inventory now read from QA worktree (preset values still TBD). Metrics and host benchmark + flash/beep export tests supplied; host results open.
- M2 renderer primitives compile: text/image/highlight layers, cursor styles/blur/spotlight, noise/window chrome, Vision segmentation/face framing, camera shadow, original click/music loops with gain/fades. Core settings/evaluated-layer integration is required; these features are not reachable from current Project ABI.

## Assumptions
- Apple frameworks only; decode BGRA IOSurfaces via CVMetalTextureCache (no CPU pixel copy), linear-light Metal shading, sRGB targets/output, bounded nearest-sample cache.
- Preview/export use one RenderProjectSource evaluator and compositor. Exact Project initializer overloads are implemented in guarded ProjectAdapter.swift and compile against real core in the integration harness. Guard removal awaits worktree rebase. Local test double lives only in render tests.
- Output refuses existing destinations; a same-directory hidden temporary file is atomically moved only after duration/dimensions/track verification. Cancellation removes its temporary file.
- Presets are provisional compact720/standard1080/high1440/ultra4K/gif until QA's FEATURES inventory arrives. GIF contains no audio.

## Blockers
- Git add/commit/rebase remain denied on shared worktree metadata. Lead committed checkpoint 64641bb; new owned files need another Lead checkpoint/rebase. Checkpoint 64641bb successfully pushed to origin/team/render. Latest owned fixes/tests await another Lead commit; no main push attempted.
- Metal unavailable in this sandbox (MTLCreateSystemDefaultDevice returns nil). Pixel comparisons, actual video/GIF export and GPU performance tests explicitly skip; real host runs required.
- Core/other teams integrated on main at 35ba7c5; this worktree is still on Lead checkpoint 64641bb. Rebase --autostash main attempted after integration and denied on shared .git metadata. Exact Project adapter work can proceed once rebased.
- SwiftPM nested sandbox unsupported; --disable-sandbox works within the outer execution sandbox.

## Requests (to Lead)
- Test target request resolved on main by 35ba7c5; worktree awaits rebase. Remove temporary YAPCAM_CORE_PROJECT_AVAILABLE guard from ProjectAdapter.swift/ProjectAdapterTests.swift after core types land locally (render will do this).
- Resolve shared Git metadata write denial or commit reviewed owned files for render. No change to main attempted.
- Please checkpoint new owned changes (RenderLayers image cache, ExportSyncTests, status), then rebase team/render onto main; Codex rebase is denied. Core now integrated there; ProjectAdapter.swift and ProjectAdapterTests.swift are implemented under temporary YAPCAM_CORE_PROJECT_AVAILABLE guard. Render will remove the guard immediately after rebase. Harness against sibling real core compiles and tests.
- Arrange other-model-family review of critical Metal/export/audio code before merge (TEAMS rule 10).
- Run render GPU tests/performance on host with Metal access; they are explicitly unverified here.

- Contract request: source.renderConfiguration/renderLayers/renderAudioOverlays provide nonbreaking optional instructions for unsupported YcFrame features. Default is off/empty. Coordinate with core/editor or extend ABI for settings persistence, masks/text/reactions/keys, cursor effects, camera Vision/shadow, music/click sound timing. No new dependencies. Speech enhancement AUD-06 remains unavailable until a workable offline processing contract/pipeline is agreed.

- M2 hardening in latest exporter edits: prefer VideoToolbox hardware encoding; GIF uses centisecond error diffusion to preserve total duration at 24/30/60 fps. GIF players may clamp very short delays; encoded timing is verified.

- Latest verified pure tests: 10,000-frame timestamp grid has no accumulated drift; GIF centisecond durations preserve a 123.456789 s range at all supported FPS; quarter-turn track transforms preserve source/camera coordinate mapping; malformed frames return explicit errors before GPU submission.

- Editor reports an audio-enabled export hang in checkpoint 64641bb near ~3.1 s. Latest exporter now feeds audio in an independent task, joins it before finish/removal, bounds encoder waits to 30 s, and cancels native writer/reader when Task is cancelled. This fix compiles but needs host confirmation (sandbox cannot start audio mix reader). New test exercises full fixture and a range crossing the segment boundary with a 20s cancellation watchdog.
- Host gate: YAPCAM_REQUIRE_RENDER_HARDWARE=1 swift test --disable-sandbox -j 4 --filter YapcamRenderTests (after rebase/test-target integration). This fails instead of skipping missing Metal.
- Renderer provides FrameCompositor.image/currentImage for exact still export; clipboard remains editor-owned.
