READY CORE-4/7/8/9 runtime/Swift checks green; CORE-10 implementation and deterministic autosave tests pass (Rust80/Core Swift56). Final signed build, fuzz and scale verification in progress.

# Core status

Updated 2026-10-15 14:29 UTC. Branch team/core; latest observed Lead checkpoint b6f1137, main 5328b45. Git metadata remains managed by Lead; no commit/rebase workaround or main push.

## Next

FEATURES.md now assigns the remaining reference gaps to Core: CORE-4 minimums
and clip controls first, then CORE-7 history grouping/cap, CORE-8 style inheritance,
CORE-9 capabilities and CORE-10 save timing/dirty tracking. CORE-1/2/3/5/6 are READY.
Lead checkpoint2c8cd9d includes the prior changes and already descends from main5328b45.
Clean rebase reports up-to-date, with sandbox lock-write errors; no workaround used.

CORE-4 assumption: the editor will use additive timeline_edit checked envelopes
for interactive minimums. Existing precision commands retain support for old
sub-minimum timelines and exact clock tests; unchanged short items are grandfathered.
Insert helpers apply3s defaults and minimum checks. This avoids silently rewriting
old recordings. Contract documented in FORMATS.md before implementation.

## Default contract change — Render handoff

The defaults below apply only to `Project.create`. Opening older projects does
not apply the new factory preset. Existing explicit values win; absent fields use
the previous defaults. `defaults_revision` is provenance, not a migration trigger.

| Setting | Previous factory / legacy missing-field value | New project revision 1 |
|---|---|---|
| defaults_revision | absent (decodes as 0) | 1 |
| canvas.aspect | `16:9` | `source` (recording aspect, including crop) |
| canvas.output_size | [1920,1080] | [1920,1080] seed retained; evaluated width follows aspect at height1080 |
| canvas.padding / padding_ratio | 48 output pixels / null | stored padding48 remains inactive; ratio0.10 of the shorter canvas edge |
| canvas.radius | 18 output pixels | 16 output pixels |
| canvas.shadow.style | `classic` | `directional` |
| evaluated screen shadow (x,y,radius,opacity) | (0,8,24,0.3) | (25*cos45°,25*sin45°,160,0.3), approximately (17.67766953,17.67766953,160,0.3) |
| canvas.background.kind / color | `solid` / [0.12,0.14,0.18,1] | unchanged; our own calm dark background |
| canvas.background.blur | 24 | 0 (inactive for solid backgrounds) |
| canvas.motion_blur | 0 | 1 |
| cursor.set_id | null, recorded cursor artwork | `classic`, our authored palette |
| cursor.style / shape / logical_size | `recorded` / null / `regular` | unchanged; a nonnull palette selects authored artwork |
| cursor.size / size_points | multiplier1 / null | stored multiplier1 remains inactive; 48 logical points on our 32pt authored canvas |
| cursor.smoothing / speed_preset | 0.15 / `custom` | 0 / `none` |
| cursor.click_effect | `ring` | `none` |
| cursor.physics_version / motion_blur | 0 / 0 | 1 / 1 |
| zoom_settings.physics_version | 0 | 1 |
| zoom_settings.spring (stiffness,damping,mass,overshoot) | (250,28,1,false) | (125,12,1.5,false) |
| default zoom level / follow_cursor | 2 / true | unchanged (default_scale2) |
| newly inserted music gain when omitted | -18dB (amplitude0.1258925412) | -26.0205999133dB (amplitude0.05); existing music gains retain their values |
| audio.click_sound.gain_db | -12dB (amplitude0.2511886432) | -12.0411998266dB (amplitude0.25); click sound remains disabled |

Exact fixture expectations for Render (uncropped 320x200 recording, output seed
[1920,1080]):

| Evaluated value | Old / legacy | New factory |
|---|---|---|
| Canvas width x height | 1920x1080 | 1728x1080 |
| Pixel padding | 48 | 108 (ratio .10 * min(1728,1080)) |
| Screen dest (x,y,w,h) | (172.8,48,1574.4,984) | (172.8,108,1382.4,864) |
| Canvas-space [.25,.25,.5,.5] layer | (480,270,960,540) | (432,270,864,540) |
| Full-canvas fade | (0,0,1920,1080) | (0,0,1728,1080) |
| CoreRenderOptions.cursorSetId / adapter cursorSetID | null / nil | classic |
| Cursor style / logical size | recorded / regular | recorded / regular (palette selects authored artwork) |

ProjectAdapterTests.swift handoff (read only; no Render test modified):
- Line129: a newly created project's palette is classic. Legacy open and explicit
  null palette still yield nil.
- Line161: clearing palette to null requests recorded artwork; to compare against
  new factory defaults restore classic, or establish a legacy/null baseline first.
- Line207: the pixel baseline currently named recorded is captured immediately
  after create, so it now uses classic. Explicitly select null before capturing a
  recorded-artwork baseline; keep the restoration-to-recorded assertion meaningful.
- Lines242/243: derive rectangles from frame.canvas_w/h, or use the new layer/fade
  values in the table. A legacy fixture or explicit canvas.aspect16:9 retains the
  original canvas dimensions. Width change comes from source aspect, separately
  from the changed padding calculation.

FORMATS.md now has a dedicated factory defaults/migration section with the same
values and null-palette semantics. Migration tests cover frozen v0/v1 defaults
and explicit legacy aspect/padding/shadow/cursor/spring values through save/reopen.
Verification: Rust76 and Core Swift50 PASS, strict codesign PASS; log
/private/tmp/yapcam-core-default-contract-check.log and final strengthened assertions
/private/tmp/yapcam-core-default-contract-swift.log. This follow-up changes docs
and owned Core regression tests only; no runtime default or Render test changed.

## READY work packages

- CORE-10 implementation: Project revision/isDirty/save(ifRevision:) guard; ProjectAutosaver opt-in MainActor trailing30s coordinator, worker full saves, cancellation/off/closed-error handling, immutable recovery journals unchanged. Generation changes only on successful edits/history; save under mutation gate clears only its own revision. Deterministic virtual-sleep tests pass, including restart/cancelled timer and stale save. Editor must replace its current2s timer with coordinator or align its own guard. Log /private/tmp/yapcam-core-autosave-check.log; final signed verification next.

- CORE-9: capabilities query/Swift CoreCapabilities with pointer/camera/external/device-frame flags; canvas.device_frame metadata gates crop/corners/inset without rewriting saved values. Mouse capability cached at load; baked cursor overlay off, external mouse/auto off, camera requires track+file. Missing external audio mixer is explicitly unavailable. Legacy Source kinds preserved. Frame gates allocate zero. Log /private/tmp/yapcam-core-capabilities-check.log. Device artwork itself stays Render-owned/unclaimed.

- CORE-8: insertion_styles metadata/query and Swift CoreInsertionStyles/insertionStyles(); explicit zoom add/update and mask insert/array edits remember style. New inserts inherit style with explicit fields winning; geometry/time/identity/disabled flags excluded. Undo/snapshot/save/reopen and automatic-generation independence tested. Log /private/tmp/yapcam-core-insertion-check.log.

- CORE-7: coalesced_edit keyed gestures group successful commits <100ms; differing key/discrete edit/history actions end groups; all histories cap1000. Explicit grouping preserves prior precision command one-step semantics; Editor must wrap continuous gestures. Cold history query + Swift CoreHistoryState/historyState() and coalescedEdit API ready. Deterministic time-boundary, full cap/undo/redo and C ABI tests pass. Log /private/tmp/yapcam-core-history-check.log.

- CORE-4: checked timeline_edit (100ms clip/zoom, 500ms layout/mask; old unchanged short items preserved), insert helpers default3s, per-clip mic/system/external gain + hide_cursor/disable_smoothing; actual mic/system frame and audio_ranges evaluation, inherited on splits and saved. Swift timelineEdit/setClipSettings/insertTimelineItem and ClipInfo.settings ready. Editor must use checked envelopes for interactive minimums; precision API remains compatible. Log /private/tmp/yapcam-core-minimums-check.log.

- CORE-1: mouse-down windows start 300ms before and finish 2500ms after the click; start >=1ms, end <=duration-800ms. Ignore clicks at/after duration-1s. Merge range-edge gaps <=2500ms, independent of pointer distance. Default level2, cursor follow enabled. Keys alone do not create zooms. No-pointer captures coerce auto zooms to manual; stored zooms otherwise remain until regeneration. Manual ranges keep priority. Immutable click indexes now avoid scanning move events; coordinate carry, repeats, same-time capture order and positionless-click center fallback are covered.
- CORE-2: new projects use source aspect, padding ratio .10 of the short canvas edge, radius16, directional shadow intensity .3/distance25/angle45/blur20 (radius160), our own calm dark background and classic cursor artwork, cursor size48 logical points, motion blur1, zoom2, music amplitude .05 and click amplitude .25. Older files retain pixel padding, radius18, classic shadow24/8, prior cursor sizing and motion settings. Scalar frames evaluate geometry; cold render_options append screen_shadow, padding_ratio and cursor_size_points.
- CORE-3: screen focused250/40/2.25 and smooth170/50/3; cursor smooth470/70/3, medium340/60/3, rapid530/40/1, none raw. Numbers mean stiffness/damping/mass. Active aligned custom ranges5...600/5...200/.1...15. Version0 retains old preset values and curves. Version1 finite screen ramps use an analytic settling envelope at precision .002, stiffness multiplied by r² and damping by r; ramps shorter than two capture frames snap. start_early leads350ms and completes at nominal range start. Explicit cursor preset/custom edits enable full smoothing; none disables it. Selecting a named preset preserves inactive legacy custom values.
- CORE-5: captured-key suggestions use strict<500ms gaps, span>=1500ms and density>=2 keys/s. typing_suggestions returns stable source IDs plus every retained exact timeline intersection, including repeated clips. Apply one/all, dismiss and restore are atomic history steps; dismissed IDs persist; speed1.5...8 is remembered (initial3). BulkSpeedTimeMap maps every effect once for a multi-clip speed change and preserves long/fractional clocks. Swift TypingSuggestion, typingSuggestions() and EditCommand cases are ready.
- CORE-6: audio.mic_preset voice/noise_reduction/podcast and stereo_mic (false by default) persist and appear in speech_enhancement / Swift SpeechEnhancementPlan. Explicit preset selection applies our own existing DSP recipes; missing metadata on old files never reinterprets their stored enable flag or DSP parameters. Typed MicrophonePreset/setMicrophonePreset(_:) are ready. No Apple isolation or unmeasured audio-quality claim.

## Contracts and assumptions

- All additive set paths, query/command records, numeric bounds and migration behavior were documented in FORMATS.md before implementation. Core README also describes the Swift additions. C ABI remains3; no existing C struct/header changes.
- Missing new fields choose legacy geometry/physics; defaults_revision1 is written only by new project creation. Frozen v0/v1 files retain original leaves, media, timeline clocks and rendered legacy appearance through save/reopen. No zoom regeneration on open.
- New smoothing starts off because the behavioral evidence leaves the app-level default preset ambiguous. Old smoothing remains unchanged until explicitly edited. Legacy slow/mellow/quick preset names remain accepted.
- Our authored cursor canvas is32pt: cursor_scale incorporates size_points/32 and source-point-to-output mapping, independent of Retina pixel density. Consumers must not multiply by cursor_size_points again. Legacy cursor.size edits clear size_points; canvas.padding edits clear padding_ratio; old shadow.radius/offset_y edits select classic shadow.
- Applied typing bursts remain queryable until dismissed; applying an already selected speed is a no-op. Bursts do not cross capture segments and have no artificial lead/tail padding. Dismissal IDs depend on captured source bounds, not edited timeline coordinates.
- Mic recipes are our choices: voice disables offline DSP; noise_reduction uses HP80Hz, noise threshold-42dB, reduction18dB, compressor ratio1, no normalization; podcast uses HP90Hz, threshold-45dB, reduction12dB, compressor threshold-20dB/ratio4, target-16LUFS. Both use peak ceiling-1dBFS. stereo_mic is a consumer preference; Core's prepared files preserve original channels.
- Behavioral implementation only. No reference code, UI strings, assets, cursor bitmaps or Apple wallpapers copied. Reactions/text/intro/outro/spotlight remain available as our extras.

## Verification

- Final debug/release Rust76 PASS plus the separately invoked ignored scale case. Includes frozen schema migration, 10,000 randomized FFI commands across four seeds, new typing/preset paths and queries, rollback/persistence checks, every-FFI top-level catch_unwind coverage, cropped first zoom-frame clamps, frame reads during durable edits, new/old defaults, preset extremes, early timing, fractional/repeated typing ranges and cursor Retina independence.
- Core Swift50 PASS; canonical scripts/build-app.sh with Yapcam Dev Signing and strict codesign PASS. Clippy all-targets -D warnings, cargo fmt --check and git diff --check PASS.
- Logs: /private/tmp/yapcam-core-reference-ready.log and /private/tmp/yapcam-core-reference-ready-release.log. Earlier separate package checkpoints are in /private/tmp/yapcam-core-reference-{1,2,3,5,6}-check.log (CORE-2's corrected Swift expectations are in reference-2-swift.log).
- Broader non-live Core+Editor run: 182 tests executed, 43 issues (42 report Metal preview unavailable; one preset-name test writes under ~/Library/Application Support/Yapcam/Presets outside the sandbox). No broader green claim. Source build succeeds; Lead/native Editor acceptance remains required. Log /private/tmp/yapcam-core-reference-final-check.log. No other team's files changed to bypass these limits.

## M3 scale — READY

60-minute synthetic source; 3,600,000 events at1kHz; 5000 clips; 1000 zooms; 36,000 keys/18,000 shortcuts; full aligned cursor smoothing enabled. Release C ABI calls, Instant clock, fixed seed0x19bc48, 2048 frame samples/1024 layer samples; 64 apply/undo samples per durability mode and eight samples per timeline automation operation. Final source run:

| Operation | p50 ms | p99 ms |
|---|---:|---:|
| yc_frame_at | .087417 | .113709 |
| layers_at with key overlay | .102500 | .126833 |
| apply, no journal | 1.631916 | 2.237666 |
| undo, no journal | .131125 | .278958 |
| apply, durable | 16.916458 | 26.459291 |
| undo, durable | 16.147667 | 22.245209 |
| set_speed, durable | 16.155875 | 17.150666 |
| split, durable | 17.074333 | 21.542000 |
| delete30min, durable | 16.083333 | 18.210417 |
| auto_zooms, durable | 15.918584 | 33.043250 |
| auto_speed_typing, durable | 26.380042 | 28.034417 |
| typing undo, durable | 16.636167 | 22.999875 |

Typing query3.096333ms; save24.062709ms; project.json1,002,540bytes. Frame p99<1ms and every sampled edit<50ms PASS; successful frames allocate zero and perform no file IO. An initial loaded-host run exceeded50ms, chiefly auto_zooms63.9ms; replacing the full move-event scan with immutable click lookup fixed the unnecessary work. Timings include host scheduling/disk variance; both later indexed runs passed.

## Requests / integration handoff

- Lead: checkpoint remaining final source tests/command notifications/cleanup listing plus this status, rebase on current main and integrate. Major packages are already captured in Lead checkpoints through b6f1137. Publish typed Swift additions in SWIFT_API.md from the contract in FORMATS.md/Core README. Independent review/native integration remains with Lead.
- Render: consume cold screen_shadow.offset_x (and directional style) alongside already evaluated scalar y/radius/opacity. Swift CoreRenderOptions.ScreenShadow is available; no C header extension is needed. Wire stereo_mic preference where channel layout is chosen. DSP presets already flow via existing speech settings. Native pixel/audio acceptance is not claimed by Core.
- QA/Lead: some FEATURES evidence predates delivered Core work: PRJ-08 frozen v0/v1 migration is verified, EDT-07 output dimensions are covered, REC-16 owned-copy import/save/reopen passes (native export remains separate), and ZOM-01 must describe the new click-window/merge rules when Core integrates. FEATURES.md remains QA-owned.
- Editor: wire typingSuggestions() and new apply/dismiss/restore commands, mic preset/stereo paths, ratio padding and directional-shadow paths, new screen/cursor presets and start_early. Keep our extras after reference sections; hotkey layout/UI ordering stay with UI/Editor owners. Existing logical cursor artwork categories remain an additional selection; do not double-apply the numeric size.
- Existing Project.close() barrier, immutable key indexes, audio range mapping and F9 optional source-name support are integrated. Lead's previous native F6 audio-tail export acceptance remains valid; no new audio-clock change made here.

## Runtime and cleanup rules

No Yapcam app launched or process signaled for this assignment. Before any future launch check ~/Movies/Yapcam/QA/.app-lock, honor all other running instances, and launch through open -n -W <build>/Yapcam.app --args ... for TCC attribution. Only terminate exact PIDs Core started; never broad kill/quit, sudo or TCC reset.

All verification used core/scripts/with-temp.sh, reused normal build caches and cleaned its owned root on exit. The wrapper now lists its exact root before removal. Final check found no yapcam-core-run.* roots remaining. No recordings, credentials or dependencies added. Native Metal/device/export validation remains with the corresponding owners.
