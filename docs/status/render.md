READY 599b43e M1/M2 renderer checkpoint builds; hardware acceptance and audio-stall fix confirmation remain open
ACTION Lead: audio fix is in 599b43e (independent audio/video pumps, native cancellation, 30s readiness bound). Re-run audio-enabled full fixture and boundary-range export on host. Pushed c1c1423 (exact Project API) and 0b60018 (Gaussian backgrounds) to origin/team/render. Please fetch/reconcile this original worktree; shared Git metadata remains denied.

# render status

## Done (verified)
- Read all briefs/contracts. Only renderer source, renderer tests and this status edited.
- IOSurface decoder + bounded nearest-VFR cache; shared sRGB Metal compositor; preview play/pause/seek, audio clock, off-main-thread decode, single in-flight draw; MP4/MOV H.264/HEVC exporter with mixed audio, verification, progress/cancel and atomic publication compile.
- M2 GIF, presets, quality/bitrate and export ranges implemented; integer video timestamps have no accumulated drift across 10,000 frames; GIF centisecond rounding preserves total duration. Export/preview metrics exposed; actual hardware performance unmeasured.
- Real-Core adapter tests pass: clip mapping after cut/speed, manual zoom, snapshot isolation and audio composition duration. Optional M2 primitives compile: overlays/highlights/text/reactions/keys via evaluated layers, original cursor styles/blur/spotlight, noise/chrome, Vision camera mask/face framing/shadow, original procedural click/music loops with gain/fades, exact still image rendering.
- On rebased worktree (35ba7c5 + 599b43e), full swift test --disable-sandbox -j 4 passed; renderer 30 tests: 16 pass, 14 explicitly skip absent Metal/media services. Current Gaussian upgrade: renderer 31 tests, 16 pass, 15 hardware skips.
- Signed app build passed using the temporary Swift wrapper (--disable-sandbox -j 4), CARGO_BUILD_JOBS=4. Authority verified as Yapcam Dev Signing (Lead's current identity); bundle mov.yapcam.Yapcam; no ad-hoc flag. One old-helper ad-hoc fallback was immediately re-signed and never launched. No TCC reset or permission dialog.
- Checkpoint 64641bb pushed to origin/team/render. Lead checkpointed/rebased latest owned code as 599b43e. Published c1c1423 (unconditional Core adapters) and 0b60018 (Gaussian backgrounds) from permitted /tmp checkout based on latest-main f0862b0; original shared Git index writes remain denied. No main push or force push.

## Remaining
- M1/M2 implementation packages published; further work blocked on host verification and core/editor extension contracts. Gaussian uses linear RGBA16Float/MPS, keeps blur=0 at native resolution and is GPU-only. All three shaders compile offline. Signed Gaussian app build passed; renderer 31 tests: 16 pass, 15 explicit hardware skips.
- Audio-stall fix compiles; new regression covers 5s fixture and range spanning segment boundary, with 20s watchdog. Host result required.

## Blockers / requests
- Metal unavailable in this execution sandbox; audio mix reader also fails startup (-11800/-1). Pixel comparisons, codecs/GIF output, A/V flash+beep sync, Vision, actual preview/export FPS are explicitly unverified.
- Latest-main f0862b0 full-suite run in temporary publish checkout fails 12 editor real-stack tests and E2E M1 export solely because they instantiate Metal without environment gating. Rust suite there passes 23 tests. Lead/editor/QA: add explicit hardware gating or run full suite on host; renderer cannot edit those files. No new READY claim for this latest-main check.
- Host gate: YAPCAM_REQUIRE_RENDER_HARDWARE=1 swift test --disable-sandbox -j 4 --filter YapcamRenderTests. Strict mode fails instead of skipping missing Metal. ExportSyncTests prints RENDER_BENCHMARK for 1080p/4K baseline; PreviewPlayer.metrics must be measured in a real view.
- Other-model-family review needed for independent audio pump/cancellation, CV texture lifetimes, shaders and Vision/MPS code before merge.
- M2 settings persistence/evaluation contract needed: renderConfiguration/renderLayers/renderAudioOverlays are optional nonbreaking source instructions; current Project returns off/empty. Coordinate core/editor or extend ABI for masks/text/reactions/keys, intro/outro, cursor variants/blur/spotlight, camera Vision/shadow, music/click sounds, noise/chrome. These primitives are not yet reachable from editor. AUD-06 speech enhancement remains unavailable pending an offline pipeline/contract. Actual camera/mic tests remain open (no hardware).

## Assumptions
- Apple frameworks only; source input is sRGB, shading/blur is linear light, final sink sRGB with sub-LSB dither. Small bounded decode/image caches; fixed-shutter blur independent of seek history; C sample.segment is the session array index.
- Refuse existing export destinations; remove only owned partials. GIF has no audio; some viewers clamp its short delays. Preset values remain provisional because QA inventory marks exact values TBD.
- Runtime test audio/images are original synthetic sources in unique temporary directories and deleted; no recordings, credentials or personal paths committed.
