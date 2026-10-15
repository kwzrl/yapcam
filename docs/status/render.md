READY pending Lead checkpoint AUD-07/08 Core audio adapter/envelope mixing: signed main-f640b35 archive build, 40 renderer software passes/26 hardware skips, Rust 56 passes
READY 5e51139 P0 renderer audio scheduling fix and retained regressions; native hang acceptance remains open
READY 5e51139 P1 Project camera effects, P2 original backgrounds, P3 original vector cursors: renderer implementation verified below
READY 5e51139 P4 offline speech DSP and P5 Core text adapter: software verified; editor controls/Core merge and hardware acceptance listed below

# Render status — ordered backlog

IN PROGRESS next: AUD-07/08 real Core overlays + duck/fade envelope mixing, then CUR-12/13 + ANI-03 ABI v3 motion. Main is now f640b35; canonical still 5e51139. git add status failed creating shared index.lock (Operation not permitted); Lead checkpoint/rebase requested. Validate on current-main archive without touching canonical non-owned files.

Lead rebased/checkpointed the owned source as 5e51139 on main 60902da. Only render-owned sources/tests and this status changed. Git metadata remains read-only here; Lead owns further checkpoints/rebases. Status update after 5e51139 is uncommitted. No main push, sudo, TCC reset, third-party images, recordings or credentials.

Published origin/team/render at 5e5113931efb83423fe48fbd63c762891ad9a0b8 after build/tests. Plain push rejected rebased history; exact force-with-lease against observed old remote 09e9800 succeeded. Remote SHA verified afterward; main untouched.

## P0: export-with-audio hang
- Production audio pulls run on a dedicated serial GCD queue via AVAssetWriterInput.requestMediaDataWhenReady, independently of video PTS and Swift cooperative workers. Watchdog bounds stalls; cancellation cancels the native reader and joins its work before partial cleanup. Completion is once-only.
- Retained deterministic regression: old frame-limited scheduling stalls at frame 93; the production input pump drains independently. Never-ready timeout and cancellation without a readiness callback also pass.
- Retained native real-Project regression: 1080p/audio-on full 5s synthetic export, seg-000-only range and 2.5–3.5s boundary range; 20s watchdog, verified audio track/duration, RENDER_AUDIO_REGRESSION output. Compiles and explicitly skips without Metal. The editor's native hang has NOT been reproduced/confirmed fixed in this sandbox; do not close it before the host regression passes.
- Lead first host command: `YAPCAM_REQUIRE_RENDER_HARDWARE=1 swift test --disable-sandbox -j 4 --filter ExportSyncTests/testEditorRealProjectAudioExportCompletesForFullFirstAndBoundaryRanges`.
- Apple pull-source API basis: https://developer.apple.com/documentation/avfoundation/avassetwriterinput/requestmediadatawhenready(on:using:) (macOS 15 compatible).

## P1: CAM-04/05 Project camera data
- Real Project frame/extras bridge drives camera sample time, geometry, shadow, background removal and face framing on the shared frozen preview/export snapshot. Real-Core synthetic camera metadata/settings/snapshot regression passes.
- Native Vision toggle regression requires removal off + face framing on to restore original unmasked bytes. Cached matte clears when disabled and retained input-buffer identity prevents address-reuse cache hits. Hardware test explicitly skips here; no actual person/camera validation claimed.
- RESOLVED: main 60902da Editor/Adapters.swift now forwards renderEffects and renderAudioRanges, including through its snapshot wrapper. Previous status's forwarding request is obsolete.

## P2: LOK-02 original backgrounds
- BackgroundLibrary supplies 12 original gradients/landscapes/geometry presets: six editable native gradients and six analytic aurora/strata/orbit wallpapers. Deterministic linear-light generation with sub-LSB dither; no third-party assets.
- `image(for:width:height:)` produces thumbnails/full resolution; async `apply(_:to:width:height:)` generates off-main, imports owned PNG via Core, cleans scratch files and changes the project in one undo step. Gradients also use one undo step.
- Software tests pass for all-art distinctness/determinism/category coverage and actual import/save/reopen/undo. Editor can wire the picker directly to these APIs.

## P3: CUR-06 original vector cursors
- VectorCursorLibrary draws our arrow, pointing hand and touch via authored CGPaths with stable logical hotspots. Compositor caches textures, uses own pointer/touch, supports explicit arrow and falls back to own arrow when a recorded sprite is absent. Recorded styles remain available.
- Generated cursor/text RGBA is unpremultiplied once before sRGB GPU upload; decoded video remains IOSurface zero-copy. Sprite shader retains correct motion-blur alpha accumulation. Raster dimensions, alpha, hotspot visibility and distinctness pass; shader compiles offline. GPU comparison remains a host check.
- Core/Editor request: cursor.style=arrow and extras cursor_style=3 so the fixed arrow can be chosen independently of recording. Existing Core recorded/pointer/touch are mapped; Render source configuration already supports arrow. Enum contract change belongs to Core/Lead.

## P4: AUD-06 offline speech enhancement
- Real `SpeechEnhancer.processFile(_:to:settings:progress:)` streams mono/stereo into 48kHz Float32 CAF/WAV with bounded blocks, original duration/file-local gaps, overwrite protection, cancellation cleanup and output frame/format verification. PCM uses AVAudioFile/AVAudioConverter; compressed audio uses native AVAssetReader with explicit errors when unavailable.
- Own DSP: Butterworth high-pass (90Hz), linked quiet-region expansion/noise reduction (up to 30dB), soft-knee compression (3:1 at -24dB), gated K-weighted integrated loudness normalization to -16 LUFS, linked -1dBFS sample-peak limiter. Report includes measured output/gain/limiting/reachedTarget; peak-constrained programmes can miss the target. No speech-isolation model or true-peak claim. Silence/below gate/<400ms has no fabricated LUFS value; normalization gain caps at 60dB.
- Eight software regressions pass: rumble/passband, quiet floor, compression, finite PCM, -16 LUFS/peak ceiling, stereo energy/gated silence, independent ffmpeg ebur128 agreement within 0.1 LU, 48k mono/44.1k stereo file duration, overwrite preservation and cancellation cleanup.
- Measurement follows ITU-R BS.1770-5 Annex 1 / EBU Tech 3341: https://www.itu.int/rec/R-REC-BS.1770-5-202311-I/en and https://tech.ebu.ch/publications/tech3341/. Apple IO plus original DSP; no dependency/assets/model added.
- Core/Editor request: persist enhancement toggle/settings and use the offline helper to prepare a lossless mic cache. No automatic enhancement in preview/export is claimed until that integration exists. Native AAC and actual noisy speech quality require host/device checks.

## P5: annotations, captions, reactions from Core
- Adapter consumes the complete evaluated layers_at list, maps optional UTF-8 text/font_size/color to RenderLayer.text and draws supplied backgrounds/highlights and final fade exactly once. It does not append a second hot highlight/fade prefix. Unicode/emoji work through CoreText; export-size rasterization keeps 4K text sharp, and generated alpha avoids double darkening.
- Compatible with current main's highlight-only Core. Core's text model is committed on team/core at 323c017 but not in main 60902da. Independently validated an archive of main 60902da with Core 323c017 paths and exact render checkpoint sources; canonical non-owned files untouched.
- Real-Core regression PASSED on that compatibility base: annotation/reaction/caption ordering, three backgrounds + three texts + exactly one fade, and expiration. On canonical main the same retained test explicitly skips until the model lands. Translucent-glyph GPU regression awaits host.
- Lead: merge Core's final backlog corrections before accepting whole text flow. Editor text/annotation/caption/reaction controls remain other-team scope. Key-overlay text uses the same bridge when enabled by Core.

## Verification
- Canonical 5e51139/main 60902da: build-app.sh succeeds; strict codesign verification succeeds, Identifier mov.yapcam.Yapcam, Authority Yapcam Dev Signing. Renderer: 64 tests, 37 pass, 27 explicit skips (26 hardware + missing Core text model). Rust: 39 pass. SwiftPM uses --disable-sandbox -j 4; Cargo four jobs; outer sandbox stays active.
- Core compatibility archive described above: renderer 64 tests, 38 pass, 26 hardware skips; Rust 48 pass. This is a pinned integration experiment, not a claim that Core is merged on main.
- Full canonical Swift run attempted: XCTest 75 tests, 27 skips, 6 Metal-unavailable E2E failures; Swift Testing 187 tests, 24 issues (22 Metal-preview Editor failures, 2 UI smoke snapshot failures for missing rendered windows). Renderer software has no failures; full suite is NOT green here. Lead must run native checks outside sandbox.
- Lead full hardware gate: `YAPCAM_REQUIRE_RENDER_HARDWARE=1 swift test --disable-sandbox -j 4 --filter YapcamRenderTests`. Includes export watchdog/A-V sync/cancellation, Vision, cursor/text/highlight pixels, GIF/codecs and preview/export parity.
- Host metrics: ExportSyncTests emits RENDER_BENCHMARK/RENDER_PARITY; PreviewPerformanceTests emits RENDER_PREVIEW_BENCHMARK at 1080p/4K. Values remain unmeasured here; no invented performance claims.
- Lead review request: other-model-family review of input pump cancellation/native lifetimes, new DSP/file processing and layer alpha before acceptance. Current APIs use Apple frameworks/own code only.

## Remaining integration and assumptions
- AUD-07/08 COMMIT-READY: Project.renderAudioOverlays now maps Core file/calm/bright/soft/crisp rows to actual media/original loops/clicks. AudioOverlay appends optional dB ramp endpoints, original fade anchors and source loop duration. Mixer approximates evaluated gain with 20ms amplitude ramps; Core fades multiply, legacy custom-source minimum fades stay compatible. Duck boundaries/export ranges do not restart music/fades.
- Real-Core regression compares full evaluated gain to effects_at, then verifies actual AVComposition source/loop clocks and AVAudioMix values over full and trimmed ranges, overlapping duck activity/fades, and snapshot isolation. New source mapping/unknown-source regression passes. main f640b35 archive + exact owned files: signed app build, renderer 66 tests (40 pass/26 hardware skips), Rust 56 pass. No native mixed-audio decode acceptance claimed.
- Editor request: ProjectRenderSource must also forward renderAudioOverlays() to project.renderAudioOverlays(); current wrapper still inherits empty default. Otherwise Project-direct exports work but editor music/click overlays stay absent. Render cannot edit that wrapper. Suggested checkpoint: render: mix evaluated Core music and click envelopes.
- Freeze edits per preview invalidation and once for export; snapshot pair preserves frame/effects. File paths are validated project-owned paths; generated imports/destinations never overwrite originals. Runtime synthetic fixture copies/scratch data are temporary and removed; no real recordings committed.
- sRGB input/sink, linear shading/blur, fixed-shutter motion blur independent of seek history, bounded caches. Sample segment is session-array ordinal. Camera EOF hides lost-device tail; audio metadata/digital silence preserves clock. Native camera/mic accuracy remains open on this no-device machine.
- H.264 parity acceptance uses mean RGB byte error <3 and 99th percentile <25 for our synthetic workload; this is our codec tolerance. Host verification owns acceptance and performance measurements.
