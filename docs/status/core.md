READY uncommitted shared Core backlog: CAP-3 markers, ED-7 source restoration, ED-8 style/LUT, ED-9 layouts, RND-5 lens; Rust90/Core Swift65 + signed build PASS. Final FFI/scale checks running; Lead checkpointcf99f48 includes earlier work.

# Core status

Updated 2026-10-15 15:40 UTC. Branch team/core; Lead checkpoint 4c2db8d. Main last observed5328b45. Git metadata remains managed by Lead; no reset/stash/workaround or main push.

## Next

Preset fix is checkpointed by Lead in 4c2db8d and pushed to origin/team/core.
CORE-1 through CORE-10 and the exact defaults/migration handoff below remain
delivered. Shared FEATURES rows also need Core contributions: CAP-3 marker query
is READY; ED-8 camera-style model/LUT is READY; ED-9 layout evaluation is implemented and under final verification. RND-5 lens contract follows.
RND-5 lens and ED-7 targeted restoration are READY; final fuzz/scale checks and handoff are in progress. This status-only follow-up
awaits Lead checkpoint. Main last observed5328b45; no newer local integration to
rebase onto. No main push or Git metadata workaround.

Integration action: clean Swift build artifacts once after Core enum additions
before judging UI errors. `swift package clean` was necessary here: stale UI
objects encoded `.set(path:"canvas.padding",...)` as
`{"op":"remove_zoom","id":"canvas.padding"}`. This reproduces the reported
foreign clip/zoom ID symptom before preset import even begins. Temporary tracing
was removed. Full clean rebuild eliminates those ID errors.

Lead must replay UI on the native Metal/display host. This sandbox ran
`swift test --disable-sandbox -j 4 --filter YapcamUITests --skip appLaunchedWithSnapshotFlagRendersEverything`:
68/71 passed; saveListApplyRoundTrip passes. applyingPresetUpdatesEditorAndSaves
now reaches EditorDocument initialization and fails with `.metal("Metal preview
unavailable")`; scriptedEditsSurviveSaveAndReopen has the same environment error.
everyWindowRendersInLightAndDark lacks area-overlay-light/dark snapshots here.
The direct-binary app-launch test was excluded because it violates Lead's
LaunchServices-only launch rule. No Yapcam app launched or process signaled.
No UI/Editor/Render tests or implementation edited.


Backlog re-audit 2026-10-15 15:40 UTC: docs/briefs/core.md, the Core row in
FEATURES' Backlog table and GAP-CORE-1...10 were checked against current source
and the completed test logs. All assigned Core implementations are delivered.
FEATURES still labels these rows todo/partial; QA owns that file and must reconcile
the evidence below after integration. This audit changes only this status file;
no new source change warrants repeating the already completed test runs. Local
main remains5328b45 and is an ancestor of HEAD4c2db8d, so no new rebase is needed.
No owned temporary verification roots remain.

| FEATURES row | Delivered Core regression evidence |
|---|---|
| GAP-CORE-1 | auto.rs: click_windows_merge_at_gap_boundary_and_leave_a_tail; windowed_candidates_keep_prior_coordinates_and_repeat_on_each_clip |
| GAP-CORE-2 | project.rs: aligned_new_defaults_and_legacy_decode_preserve_distinct_appearance; Swift alignedNewProjectDefaultsPreserveFrozenOlderAppearance |
| GAP-CORE-3 | spring.rs: versioned_presets_compress_and_snap_without_changing_legacy_curves |
| GAP-CORE-4 | editing.rs: checked_minimums_insert_defaults_and_clip_controls_roundtrip; Swift checkedTimelineMinimumsAndClipSettingsUseAdditiveCommands |
| GAP-CORE-5 | auto.rs: typing_suggestions_are_source_stable_dismissible_and_atomic; Swift typingSuggestionCommandsUseSourceIDsAndRememberSpeed |
| GAP-CORE-6 | query.rs: microphone_presets_are_explicit_owned_recipes_and_keep_legacy_dsp; Swift microphonePresetsExposeOfflinePlanAndStereoPreference |
| GAP-CORE-7 | editing.rs: coalesced_history_groups_and_caps_without_changing_discrete_commands |
| GAP-CORE-8 | editing.rs: insertion_styles_follow_edits_history_and_persistence_without_geometry; Swift lastEditedInsertionStylesPersistWithoutCopyingGeometry |
| GAP-CORE-9 | capabilities.rs: gates_preserve_settings_and_frame_queries_remain_allocation_free; Swift capabilityGatesPreserveStoredAppearanceThroughABI |
| GAP-CORE-10 | AutosaveTests.swift: stale revision, restart/cancel, disabled/closed state, manual-save timer suppression |

All listed tests are included in the latest Rust82/Core Swift59 passing runs.
Acceptance involving Editor wiring, Render pixels, microphones/cameras or the
native Metal/display host remains with those owners. The integration requests
below remain open. The original CORE-1...10 list is complete; the shared-row
follow-up above supersedes the earlier assertion that all Core work was empty.

Integration assumptions: Editor must use timeline_edit for interactive minimums
and coalesced_edit gesture keys for100ms history grouping. Precision commands keep
old short-timeline support and discrete one-command/one-step semantics. Editor
must replace its existing2s autosave timer with ProjectAutosaver or align its own
30s/revision guard; Core does not install competing timers. Device artwork and
external audio mixing are explicitly unavailable in Core (capability/query says
so), while their metadata/preferences remain compatible with future consumers.

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
| canvas.global_motion_blur | absent/null, independent strengths | 1 master multiplier; initial pixels unchanged |
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
Verification: Rust76 and Core Swift58 PASS, strict codesign PASS; log
/private/tmp/yapcam-core-default-contract-check.log and final strengthened assertions
/private/tmp/yapcam-core-default-contract-swift.log. This follow-up changes docs
and owned Core regression tests only; no runtime default or Render test changed.

## READY work packages

- ED-7 Core READY: additive insert_source / EditCommand.insertSource at a clip boundary restores source bounds and original clip settings without undoing unrelated edits. Exact rational prefix mapping distinguishes start/end edges at insertion and covers every timed collection, including camera silence ranges. Screen/audio/input share clip time; no recording writes. Empty timeline restoration, invalid/beyond-source/minimum rollback, fractional long clocks, history/snapshot/reopen and audio-clock regressions pass. Rust90/Core Swift65 + Clippy + signed build/strict codesign PASS, /private/tmp/yapcam-core-shared-backlog-ready.log. Editor: retain original transcript source-word ranges, batch insertSource + add-caption for targeted restore; existing cut/hide/correct primitives remain available.

- RND-5 Core READY: per-zoom style/lens parameters, inherited insertion style, shared classic/lens spring weight and active-zoom selection, local zoom_lens_at instruction and typed Swift CoreZoomLens/ZoomLens. Lens leaves base crop unchanged; camera sizing still follows zoom weight. Manual/auto pointer targets, crop clamping, null inactive endpoints and old classic defaults supported. Rust88 + Core Swift64 PASS; /private/tmp/yapcam-core-lens-ready.log (Rust/build) and /private/tmp/yapcam-core-lens-swift.log (final Swift). Earlier Swift syntax/build-input corrections resolved; native lens shading remains Render-owned.

- ED-9 Core implemented: additive layout_settings, cutout/split modes and per-range settings; exact frame fitting/orientation/flip/padding/corners, cutout matting flag, silence gating with remapping. Missing camera falls back to screen. Legacy geometry defaults retained and frame/extras allocate zero. Rust geometry/boundary/history tests pass; Swift full verification follows /private/tmp/yapcam-core-camera-layout-swift.log (first run had a corrected test syntax error). Softness/inset rendering and controls are Render/Editor handoffs.

- ED-8 Core READY (awaiting Lead checkpoint): additive camera.style parameters,12 original scalar recipes, camera_style/library queries and typed Swift access; render_options includes camera_style. Strict CUBE parser/importMedia/preset embedding with fresh target LUT path and transactional staged-asset cleanup. Missing old fields choose original/no grading. Source reference defaults/strings/assets not copied. Rust85/Core Swift62 + Clippy + signed build/strict codesign PASS, /private/tmp/yapcam-core-camera-style-ready.log. Native shader/pixel/UI support remains Render/Editor-owned; metadata availability is not a pixel claim.

- CAP-3 Core READY (awaiting Lead checkpoint): markers query/TimelineMarker/Project.markers() expose capture marker IDs and unique per-clip occurrences with exact source/segment/timeline ns. Filter recording events once, index clip prefixes once and map only relevant markers; no hot-frame change. Cut/split boundaries, speed, repeated source, legacy IDs, large clocks, snapshots, history, save/reopen and immutable event bytes covered. Rust84, Core Swift60, Clippy and signed app/strict codesign PASS; /private/tmp/yapcam-core-markers-ready.log. Editor: display these records and use tlNs for snapping; Capture marker_id wire format consumed directly.

- Preset portability READY 4c2db8d: one Core schema filter serves preset query/export and apply. Saved files omit clips/zooms/timed collections, source crop, IDs/recording metadata and asset indices; applying legacy/full-project payloads ignores them. Style leaves merge recursively, so omitted settings and every target timeline/effect remain intact. Embedded background images register fresh destination media in the atomic import batch; raw source indices/image-kind settings cannot select unrelated target media. No ABI change. FORMATS.md documents the boundary.
- Regression evidence: Rust `preset_saved_in_project_a_applies_to_project_b` covers distinct clip IDs, split target, zoom/layout/mask/caption/music/audio/cursor ranges, foreign malformed legacy records, undo/redo; partial/invalid style tests prove merging and atomic rollback. Swift `presetSavedInProjectAAppliesToProjectB` exports A/imports B, preserves edits, saves/reopens and imports legacy full-project payload. Existing image test now deliberately uses different source/destination media indices. FFI random JSON exercise expanded to25 command families including malformed presets.
- Verification: Rust82 debug and82 release PASS (scale ignored as designed), Clippy all-targets -Dwarnings/fmt/diff PASS, clean canonical signed app build + strict codesign PASS, clean Core Swift59 PASS. Logs: /private/tmp/yapcam-core-preset-check.log, /private/tmp/yapcam-core-preset-release.log, /private/tmp/yapcam-core-preset-clean-build.log. Requested UI run and its three environment failures: /private/tmp/yapcam-core-preset-ui-clean.log. Earlier command trace proving stale enum tags: /private/tmp/yapcam-core-preset-ui-command.log. Logs are local only; no temporary tracing is in source. All verification roots listed and removed by cleanup traps.

- CORE-10 READY: Project revision/isDirty/save(ifRevision:) guard; ProjectAutosaver opt-in MainActor trailing30s coordinator, worker full saves, cancellation/off/closed-error handling, immutable recovery journals unchanged. Generation changes only on successful edits/history; save under mutation gate clears only its own revision. A pending timer skips disk writes after manual save; policy-query/save errors remain visible. Deterministic virtual-sleep tests pass, including restart/cancelled timer and stale save. Editor must replace its current2s timer with coordinator or align its own guard. Logs /private/tmp/yapcam-core-autosave-check.log and final /private/tmp/yapcam-core-backlog-ready.log. Off/closed/error cases also pass; Core Swift58/signed build verified. Final log /private/tmp/yapcam-core-autosave-manual-save.log; stricter inode proof /private/tmp/yapcam-core-autosave-inode-check.log verifies no duplicate disk write after manual save.

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

- Latest complete code checks at4c2db8d: Rust82 debug/release, Core Swift59, Clippy all-targets -D warnings, clean canonical signed build/strict codesign, fmt/diff PASS. Preset fix and UI environment results are recorded above. Earlier backlog baseline: Rust80/Core Swift58. Expanded four-seed10k FFI fuzz now includes checked/grouped edits, insert helpers, clip settings, device metadata and all new cold queries. Deterministic virtual-sleep autosave tests cover reset/cancel/off/closed/error and stale revisions; frame reads remain independent of save IO. Logs /private/tmp/yapcam-core-backlog-{final,ready}.log.
- Unity clip settings omit JSON to keep large projects compact; Swift ClipInfo.effectiveSettings supplies defaults. Key overlays reuse the immutable time index on gain/cursor-only clip edits. Frame audio uses the already resolved clip index, avoiding repeated source scans. Gain/mute/smoothing inheritance and allocation-free capability frames are tested.

- Final debug/release Rust80 PASS plus the separately invoked ignored scale case. Includes frozen schema migration, 10,000 randomized FFI commands across four seeds, new typing/preset paths and queries, rollback/persistence checks, every-FFI top-level catch_unwind coverage, cropped first zoom-frame clamps, frame reads during durable edits, new/old defaults, preset extremes, early timing, fractional/repeated typing ranges and cursor Retina independence.
- Core Swift58 PASS; canonical scripts/build-app.sh with Yapcam Dev Signing and strict codesign PASS. Clippy all-targets -D warnings, cargo fmt --check and git diff --check PASS.
- Logs: /private/tmp/yapcam-core-reference-ready.log and /private/tmp/yapcam-core-reference-ready-release.log. Earlier separate package checkpoints are in /private/tmp/yapcam-core-reference-{1,2,3,5,6}-check.log (CORE-2's corrected Swift expectations are in reference-2-swift.log).
- Broader non-live Core+Editor run: 182 tests executed, 43 issues (42 report Metal preview unavailable; one preset-name test writes under ~/Library/Application Support/Yapcam/Presets outside the sandbox). No broader green claim. Source build succeeds; Lead/native Editor acceptance remains required. Log /private/tmp/yapcam-core-reference-final-check.log. No other team's files changed to bypass these limits.

## M3 scale — READY

60-minute synthetic source; 3,600,000 events at1kHz; 5000 clips; 1000 zooms; 36,000 keys/18,000 shortcuts; full aligned cursor smoothing enabled. Release C ABI calls, Instant clock, fixed seed0x19bc48, 2048 frame samples/1024 layer samples; 64 apply/undo samples per durability mode and eight samples per timeline automation operation. Final source run:

| Operation | p50 ms | p99 ms |
|---|---:|---:|
| yc_frame_at | .086542 | .110834 |
| layers_at with key overlay | .103208 | .143875 |
| apply, no journal | 1.680375 | 1.968541 |
| undo, no journal | .130084 | .146000 |
| apply, durable | 13.520084 | 22.913708 |
| undo, durable | 13.859541 | 20.982958 |
| set_speed, durable | 14.728208 | 17.563459 |
| split, durable | 15.478334 | 17.054375 |
| delete30min, durable | 13.797375 | 15.235417 |
| auto_zooms, durable | 14.786666 | 15.947875 |
| auto_speed_typing, durable | 15.311666 | 21.692333 |
| typing undo, durable | 14.980416 | 16.794667 |

Typing query1.778167ms; save22.611625ms; project.json1,002,630bytes. Repeat log
/private/tmp/yapcam-core-backlog-scale-repeat.log: frame p99 .110834ms and worst
sampled edit22.913708ms PASS; successful frames allocate zero and do no file IO.
An immediately preceding run of the same source/binary reported frame p99
1.310541ms/max11.456084ms and layer p99 1.174708ms, with median frame .100041ms;
recorded in backlog-final.log rather than hidden. The unchanged-binary repeat
returned to .110834ms/max .119125ms. This suggests transient scheduling/load;
native host confirmation remains useful. Earlier auto-zoom full-event scanning
was removed and both current runs keep all edit samples below50ms.


## Requests / integration handoff

- Render/Editor: ED-8 camera.style contract is in FORMATS.md. Consume CoreRenderOptions.cameraStyle / CameraStyle and cameraStyleLibrary(), implement grading/LUT at intensity, crop/sharpen/grain/blur and controls. CubeLUT parser + Project.cameraLUT()/importCameraLUT(from:) are provided; custom recipes are our own. No C ABI layout changed. CAP-3 Project.markers() is ready for timeline/snapping.

- Editor/Lead: adopt checked timelineEdit envelopes, setClipSettings + ClipInfo.effectiveSettings, insertTimelineItem helpers, coalescedEdit gesture keys, insertionStyles/capabilities and ProjectAutosaver. The existing Editor timer is2s; remove/replace it when adopting the30s coordinator, and cancel the coordinator before final save/Project.close. Preserve saved choices behind capability gates. These integrations belong to Editor; no Editor source/tests changed.
- Lead independent review: new critical paths are core/src/editing.rs (checked recursion/insertion/history policy), capabilities.rs/frame gates, and Sources/YapcamCore/Autosave.swift plus Project revision mutations. C ABI remains3 with no header/layout changes. Additive contracts are in FORMATS.md; publish Swift surface in SWIFT_API.md. Native integration/pixels remain owners' work.

- Lead: source is checkpointed and pushed through4c2db8d; checkpoint this status follow-up and integrate Core+Render after a clean Swift build and native UI replay. Publish typed Swift additions in SWIFT_API.md from the contract in FORMATS.md/Core README. Independent review/native integration remains with Lead.
- Render: consume cold screen_shadow.offset_x (and directional style) alongside already evaluated scalar y/radius/opacity. Swift CoreRenderOptions.ScreenShadow is available; no C header extension is needed. Wire stereo_mic preference where channel layout is chosen. DSP presets already flow via existing speech settings. Native pixel/audio acceptance is not claimed by Core.
- QA/Lead: reconcile GAP-CORE-1...10 using the backlog audit evidence table above; all assigned Core implementations are delivered, with consumer/native acceptance separate. Other FEATURES evidence predates delivered Core work: PRJ-08 frozen v0/v1 migration is verified, EDT-07 output dimensions are covered, REC-16 owned-copy import/save/reopen passes (native export remains separate), and ZOM-01 must describe the new click-window/merge rules when Core integrates. FEATURES.md remains QA-owned.
- Editor: wire typingSuggestions() and new apply/dismiss/restore commands, mic preset/stereo paths, ratio padding and directional-shadow paths, new screen/cursor presets and start_early. Keep our extras after reference sections; hotkey layout/UI ordering stay with UI/Editor owners. Existing logical cursor artwork categories remain an additional selection; do not double-apply the numeric size.
- Existing Project.close() barrier, immutable key indexes, audio range mapping and F9 optional source-name support are integrated. Lead's previous native F6 audio-tail export acceptance remains valid; no new audio-clock change made here.

## Runtime and cleanup rules

No Yapcam app launched or process signaled for this assignment. Before any future launch check ~/Movies/Yapcam/QA/.app-lock, honor all other running instances, and launch through open -n -W <build>/Yapcam.app --args ... for TCC attribution. Only terminate exact PIDs Core started; never broad kill/quit, sudo or TCC reset.

All verification used core/scripts/with-temp.sh, reused normal build caches and cleaned its owned root on exit. The wrapper now lists its exact root before removal. Final check found no yapcam-core-run.* roots remaining. No recordings, credentials or dependencies added. Native Metal/device/export validation remains with the corresponding owners.
