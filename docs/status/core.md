READY UNCOMMITTED Core M2 ABI v2 extras + retimed clicks + all set paths documented; Rust 28 tests/Clippy and full Swift suite (50 Swift Testing + 15 XCTest, 7 explicit XCTest skips; real HEVC skipped) pass; clean app signed Yapcam Dev Signing. Lead may checkpoint/rebase.

# Core status

## Done (verified)
- Last committed/pushed checkpoint: 4f05744. New source remains uncommitted by the agreed Lead checkpoint workflow; no staging/commit retries now that read-only Git metadata is acknowledged.
- ABI v2 added with explicit Lead authorization to edit core/include/yapcam_core.h, docs/FORMATS.md and docs/SWIFT_API.md. Original YcFrame (328 bytes) and all v1 fields/signatures unchanged. New YcFrameHighlight (80 bytes), YcFrameExtras (2600 bytes, alignment 8), yc_frame_extras_at and Project.frameExtras(atNs:). C/Swift and Rust sizes/offsets verified. Extras calls tested allocation-free through the actual FFI; errors leave output untouched.
- Extras evaluate cursor style/blur/spotlight, background noise/chrome, camera shadow/Vision flags, highlights/masks and intro/outro fade opacity. Core geometry follows the same frame crop/zoom/layout math. Up to 32 overlapping highlights; a 33rd is rejected transactionally, no truncation. Arbitrarily many sequential regions accepted. Reserved/unused slots zero; array order defines stacking.
- {"q":"clicks"} already implemented, now documented/tested for multi-segment, speed, cut, undo and split-boundary behavior. Project.clicks() returns typed CursorClick values. Times are exact Int64 timeline ns, sorted; removed events omitted.
- Full set path/types/defaults, timeline record shapes, queries, extras ABI, approved FNV-1a64 hash and recovery behavior now in FORMATS.md. Swift extras/click/cold bridge signatures in SWIFT_API.md. No capture/session contract changes.
- Rust 28 tests + Clippy all-targets -D warnings pass. Includes >=10,000 successful randomized edits, independent rational oracle, fixed frame goldens, persistence/backup/journal, autosave rollback, ABI/capacity/no-allocation, highlights/snapshot/fade, click retiming and long-clock clip/audio endpoint regressions.
- Full Swift suite passes: 50 Swift Testing tests in 4 suites (real HEVC test explicitly skipped); 15 XCTest tests, 7 explicitly skipped for sandbox Metal/native decoder limits. Core lifecycle/frames/extras/snapshot/concurrency/autosave/import/relink/presets/PCM silence/exact Int64/click tests pass. Native AAC verifies an explicit unavailable outcome, not successful decoding.
- Clean build-app.sh succeeds with four build jobs and SwiftPM sandbox workaround. codesign verifies Authority=Yapcam Dev Signing. No app launched, no permission reset, no sudo; no recordings or credentials in changes.

## Rebase / checkpoint
- Latest `git rebase main` was attempted as requested; rejected because verified M2 changes are unstaged. Git metadata remains read-only, so commit/stash/rebase cannot be performed here. Lead must checkpoint then rebase this worktree outside the Codex sandbox. Current HEAD 4f05744 includes main through 35ba7c5; current shared main is f0862b0.
- Suggested checkpoint message: `core: add ABI v2 effects and document editing contracts`. Includes Core-owned changes plus the three explicit Lead-authorized contract files. READY above refers to the verified working tree, not an invented commit SHA. Lead handles commits on the agreed ~25-minute cadence.

## Requests / integration
- Other-model review of persistence/rational timing/FFI/autosave before merge (team rule 10).
- Render/Editor: use Project.frameExtras(atNs:) for the hot extras path or the existing typed renderOptions/renderLayers cold hooks; geometry/animation math stays in Core. Draw extras.highlights[0..<highlight_count] in order, then a full-canvas black overlay at fade_opacity. Do not draw both extras and cold-query layers. Export must use the same immutable snapshot for frame/extras. Preview must serialize edits when obtaining a pair (each call independently locks).
- Render/Editor: map cursor_style 0/1/2 to recorded/pointer/touch and remaining extras options into existing RenderConfiguration. Rendering/pixel verification is still host/integration work, not claimed verified by Core tests.
- Editor: refresh cached snapping times with project.clicks().map(\.tlNs) after timeline edits; clicks are timeline-mapped, source events stay immutable.
- Renderer: background_asset resolves via Project.mediaURL(atIndex:). Audio query gain_start/gain_end are linear amplitudes from dB ramps; honor ramps instead of holding legacy gain constant.
- UI helpers available: importBackgroundImage, importVideo async, preset export/import, relink(package:replacements:), autoZooms, autoSpeedTyping, processSilence. Orientation normalization implemented; real native encode check pending.
- Build tooling should force Swift relinking after Rust static-lib updates; final verification used SwiftPM clean to guarantee current code.
- No track-end contract exists for lost devices; renderer must handle truncated file EOF explicitly until a future track_end_ns contract is agreed.

## Remaining limits
- Scene transforms/other intro-outro presets beyond none/fade explicitly rejected. Hardware camera/mic, Retina/multi-display, host Metal effects/Vision/export parity and native compressed AAC remain unverified.
- SwiftPM nested sandbox fails sandbox_apply; verification uses --disable-sandbox under the outer Codex sandbox, four jobs, and a temporary PATH wrapper for build-app.sh. No global settings changed.
- AAC decoding returns AVFoundation -11800 under restricted execution and an explicit CoreError.status(6, decoder unavailable); PCM WAV silence analysis is verified.

## Decisions / assumptions
- FNV-1a64 first-MiB head hash plus full size is approved by Lead for change detection, not authenticity. No new dependencies.
- Effects/camera/crops normalized; output lengths in canvas pixels. Highlights source-space by default (canvas also supported); hidden source regions omitted. Timeline ranges half-open. Fades use black full-composition quintic easing, clamp to duration, overlap takes darker result, no added time/audio changes.
- Defaults and auto/spring behavior remain reversible choices documented in FORMATS.md and core/README.md; exact reference preset values not claimed. Imported movies use source kind display with display_id 0 and preserve muxed audio; no new session source kind.
- Autosave journals complete validated state before memory edits; snapshots never journal. Timing rounds only at public boundaries using rational fractional ns and Q32 fallback for extreme denominators. Clip/audio/event/frame queries share this model.
- JSONValue.integer preserves values beyond 2^53; small exactly representable decoded integers remain .number for editor compatibility. Use .integer when encoding generic range times.
- Portable presets omit project-specific timeline ranges and embed custom background image base64 only in the Swift local preset file; pixels never cross C. Relink preserves edits/autosave, stages repairs and rolls back failures.
