READY 091d7a2 M1 core foundation: exact archived commit passes 20 Rust tests, 6 Swift ABI tests and build-app.sh; stable signing visibility blocked (see below). Pushed to origin/team/core. Latest timing/M2 hardening requires a new Lead checkpoint.

# core status

## Done (verified)
- M1 core path implemented: schema types, package create/open/save/clone/JSON/free, corrupt-primary `.prev` recovery, version refusal/migration, path/media checks, shared segment/time mapping, transactional commands + undo/redo, allocation-free frame evaluation, queries, exact public Swift Project surface.
- Rust: 20 tests pass, including fixed frame goldens, ≥10,000 successful random split/delete/speed edits, exact integer-rational duration/source oracle and tl→src→tl invariants, camera layouts, spring presets, auto zoom clustering, typing speed, silence edits, presets, cursor ranges/loop, gain envelopes, autosave crash/reopen and rollback. These include current uncommitted rational-time/index improvements beyond Lead checkpoint 091d7a2.
- Swift: 12 tests now pass: real C ABI lifecycle/frames/undo/snapshots/concurrency/errors, exact Int64 JSON, autosave/presets/auto zooms, local video import, PCM silence detection + edits, relink preserving edits and path safety, image asset import and portable image presets. AAC test verifies explicit unavailable path, not successful decode.
- Archived Lead checkpoint 091d7a2 verified independently: build-app.sh, 20 Rust tests and 6 Swift tests pass. It was not launched. Latest normal build compiles but keychain query now reports zero signing identities, so build script falls back to ad-hoc; stable signing remains a Lead-side blocker.

## In progress
- Current local Rust/Swift builds and tests are green; cross-model review and final Lead commit pending.
- M2 independent core work implemented and tested; preparing final checkpoint for Lead. Remaining features depend on ABI/render/UI integration or native codec access.
- Final build/test/lint and cold-path API documentation.

## Next
- Please commit current owned-file diff and push team/core; all current code tests are green. Full integration contract/usage is in core/README.md.
- Verify expanded Swift tests and final signed app build; signal READY against a Lead-created final checkpoint (this sandbox cannot commit).
- Reconcile ABI-dependent M2 extensions after Lead updates header/contracts.

## Blockers
- Git staging still denied: cannot create shared `.git/worktrees/core/index.lock` despite declared writable root. Lead created checkpoint 091d7a2; latest owned-file changes remain uncommitted. Checkpoint 091d7a2 is pushed to origin/team/core (confirmed via ls-remote). Please commit final owned changes; I can push the new commit once available. No push to main.
- SwiftPM nested sandbox fails (`sandbox_apply: Operation not permitted`). Working verification uses `swift test --disable-sandbox -j 4` and temporary PATH wrapper injecting these flags into build-app.sh; stable signing succeeds. No permission reset or sudo used.
- Real camera/mic and Retina/multi-display tests remain hardware-limited.
- Stable signing identity currently invisible to this process (`security find-identity` reports 0); build-app.sh falls back to ad-hoc. No app launched and no TCC reset; please re-sign with stable identity outside this sandbox before launch.
- Native compressed AAC decoding fails with AVFoundation -11800 in restricted execution despite valid AAC-LC fixture metadata. PCM WAV silence analysis is verified; AAC returns explicit CoreError.status(6, decoder unavailable). Lead should retest outside sandbox; no decoded-silence success claimed.

## Requests (to Lead)
- Cross-model review of persistence/rational timing/FFI/autosave before integration (team rule 10).
- Integrate QA inventory from sibling QA worktree and announce integration for rebase; current main has advanced but git rebase writes are sandbox-blocked.
- Extend fixed-size C frame ABI for masks/highlights, intro/outro transforms, per-camera shadow and cursor motion blur; these cannot be carried by current YcFrame. Those M2 features remain unavailable pending contract changes.
- Relink no longer needs a new ABI: `Project.relink(package:replacements:)` now stages repairs and restores saved/auto-saved edit state through a verified recovery command. UI can use it after missingMedia.
- Render/editor: `Project.mediaURL(atIndex:)` resolves frame.background_asset. ProjectRenderSource adapter should implement `renderBackgroundAsset(index:)` through this helper. No pixels cross the Rust boundary.
- Render: audio_ranges now contains split automation intervals plus gain_start/gain_end (linear amplitudes; underlying automation interpolates dB). Honor ramps for export rather than only the legacy gain value.
- UI: `Project.importVideo(_:package:) async`, preset export/import, `Project.relink`, `.autoZooms`, `.autoSpeedTyping(speed:)`, `.processSilence(ranges:speed:)` now available. Imported movies with nonidentity preferredTransform are normalized to upright pixels before packaging (orientation normalization implemented but full encode test awaits native codec availability).
- Media fingerprint is algorithm-prefixed FNV-1a64 of first MiB for change detection, not authenticity. No new dependency. Change to SHA-256 before format freeze if required.

## Assumptions
- Effect targets/camera positions/crops use normalized coordinates; canvas lengths use output pixels. Generic set rejects unknown paths/keys.
- Source/display/window/area capture format unchanged. Imported video uses display-like source geometry with display_id 0 and retains its source movie; screen/audio reference the same movie when audio exists. No new source kind added without a Lead contract.
- Output width derives from aspect and output_size height; custom aspect uses both dimensions. Defaults: 1920×1080, 48 px padding, centered fit, zoom 1…16, speed 0.05…32.
- Auto zooms group nearby clicks/typing within 1.2 s, preserve manual zooms, replace prior auto zooms idempotently; generated zooms pan with cursor inside a dead zone. These are reversible choices, not claims of exact reference defaults.
- Spring presets Slow/Mellow/Quick/Rapid use analytic damped response. Cursor smoothing=0 preserves raw interpolated event positions; range override latest start wins. Camera-only layout falls back to screen when no camera track exists.
- Gain automation interpolates dB and adds to global track gain; mute is separate. Event-derived typing speed and supplied silence cut/speed ranges share the single clip list.
- Autosave journals complete validated project states before committing an edit in memory; open restores journal, save removes it. Export snapshots never autosave over the editor.
- Timing keeps rational fractional ns and rounds at public boundaries; extremely large combined denominators fall back to Q32 fractional ns (~0.00000000023 ns precision), never whole-ns per-clip accumulation.
- Existing serde/serde_json dependencies only (MIT/Apache-2.0); Apple AVFoundation for import/analysis. No recordings, credentials, or personal paths added to tracked content.
- JSONValue retains `.number` for exactly representable small integers to keep existing editor setting readers compatible; `.integer` preserves values beyond 2^53. Number/integer getters are also exposed. Please use `.integer` when encoding range times.
- Custom background preset files embed `_background_image` base64 in the Swift local file only; Swift copies the asset then sends only a path through Rust. Preset apply + asset selection is one undo step.
