READY 9b0da01: Core backlog empty; ED-10 caption style + word timing/edit mapping + cold instructions/Swift APIs; Rust104/Core Swift74/Render11 portable +4 native skips, Clippy and signed build/codesign PASS. Integrated on main01f05df; checkpoint pushed to origin/team/core; consumer handoff below.

# Core status

Updated 2026-10-15 22:57 UTC. Branch team/core; Lead checkpoint cc548c6; main66d4166.
Main includes the tested caption package and matches every Core implementation/test/
format path. Checkpoint cc548c6 remains published to origin/team/core. Rebase onto
new main attempted with a clean tree (status preserved/restored); Git sandbox again
rejects rebase-merge creation. Lead rebase required; no metadata workaround.

## Next

No remaining assigned Core implementation item. Editor's new explicit ED-10 request
(status c143346, Requests section) is now implemented in checkpoint 9b0da01. The prior
empty-backlog state was correct before that new request. New contract was written
first in FORMATS.md; Core README includes Swift/API and Render integration notes.

Lead: checkpoint 9b0da01 includes all 15 package files, including the three new
caption implementation/test files, and is integrated in main01f05df/published to origin/team/core. Required
other-family review should cover word mapping/patch handling and renderer timing.
Mirror public API additions in Lead-owned SWIFT_API.md. No C header change.
22:57 UTC re-audit: brief, FEATURES Core backlog and updated consumer handoffs
contain no new Core assignment. Editor's latest "no persisted font field" request
is stale: main already includes TextStyle.fontFamily, captionOptions(), persisted
style.font_family and emitted text-layer font_family from 9b0da01; see contracts
below. Lead should route that implementation handoff to Editor/Render. Editor now
reports 30 s trailing autosave, closing the previous policy mismatch. No source
changed after the final green gate; unchanged tests were not repeated. Only this
status refresh remains uncommitted. Main and remote checkpoint are unchanged since
the prior audit; no repeated rebase attempt against the same sandbox failure.
Dispatch: Core queue is empty. Route caption-consumer integration to Editor/Render;
resume Core implementation when a concrete Core defect or contract request arrives.


Editor: canvas.captions records now carry style.font_family(sans/serif/mono),
reveal(line/word), growth(full/expanding/centered), entrance(appear/fade/slide) and
language(auto/tag). Use update_caption's whole style patch or typed TextStyle;
merge old style values before updating a single control. caption_options and typed
captionOptions()/enum cases expose the choices. Optional CaptionWord arrays use
exact timeline Ns; metadata is preserved on structural edits/history/save. Text-only
correction clears old timing; range-only retime scales it exactly. No array-index
set paths. Existing line/full/appear sans pixels/defaults are retained.

Render request: existing text layers now append font_family and caption metadata.
Core already supplies visible text and applies line opacity/slide into layer opacity/
rect (do not multiply again). Consume caption full/visible text + growth for glyph/
background fitting, and per-word opacity/offset after shaping. Main01f05df now includes
Render's shared font-family backend; its status confirms the selector contract is
consumed. Growth/per-word instructions still require renderer support and native
acceptance before claiming those visuals. Defaults remain compatible; Core does not
approximate glyph widths. Lens + cover-mask pre-lens ordering remains a separate
Render/Lead contract discussion; no new Core change is specified by that note.

Capture/Editor request: expose actual native supported locales for the recognition
language picker; Core cannot truthfully provide a static supported-language list.
It validates common language/locale tags and preserves valid transcript.locale on
import when the style is auto. No recognition/translation capability is claimed.
No other team's source/tests, icon, header or frozen fixtures were edited.

Final ED-10 gate: Rust104 PASS/1 intentional scale ignore, Core Swift74 PASS,
ProjectAdapterTests/CoreLensLayoutTests15 =11 portable PASS/4 explicit native skips,
Clippy all-targets -D warnings, fmt/diff, CLEAN canonical signed app + strict
codesign PASS. Log /private/tmp/yapcam-core-caption-ready.log. Four new Rust/three
new Swift regressions cover old-style defaults, all enums/language validation,
word gap/reveal/fade/slide metadata, Unicode, >2^53 clocks, cuts/speeds/insertions,
retiming/text correction, snapshot/history/reopen and invalid-batch rollback.
Allocation-counted frame/frameExtras still allocate zero with advanced captions.
Four-seed10,000-command FFI fuzz now covers33 families including word/style mutations
and caption_options. No app launched/PID signaled; every wrapper listed/removed its
own root. Native font/growth/word-animation pixels remain outside Core acceptance.

Prior baseline gate (before ED-10):
Final gate: Rust100 PASS/1 intentional scale ignore, Core Swift71 PASS, renderer
contract suites19 =13 portable PASS/6 explicit native skips; Clippy all-targets
-D warnings/fmt/diff; CLEAN canonical app + strict codesign PASS. Rust log:
/private/tmp/yapcam-core-consumer-handoffs-ready.log. That first combined run found
the Swift DTO empty-object mismatch in Render's test; fix and final app/Core Swift/
Render run PASS in /private/tmp/yapcam-core-consumer-handoffs-swift-final.log.
Native pixel acceptance and UI control wiring remain with Render/Editor/Lead.
No app launched or PID signaled. Every finished wrapper listed/deleted its root.

UI failure evidence on pre-integration Core test baseline for Lead/UI: the broad UI command (direct-binary app test
excluded per launch rule) aborts with signal6. Diagnostic report
~/Library/Logs/DiagnosticReports/swiftpm-testing-helper-2026-10-15-184921.ips
states HIToolbox TIS/TSM APIs were called concurrently from two threads. Triggered
stack: KeyCombo.keyName -> menuKey -> MainMenu.build ->
ReviewFixTests.mainMenuHasEditorCommands. This is a UI keyboard/menu thread issue;
no Core frame/FFI panic appears in that stack. Do not treat this run as UI green.
Isolated PresetTests.saveListApplyRoundTrip PASS; isolated
applyingPresetUpdatesEditorAndSaves reaches EditorDocument and fails with
.metal("Metal preview unavailable") before preset apply. No unknown clip/zoom ID
error reproduced after the clean Swift build. Logs:
/private/tmp/yapcam-core-mic-selection-{ready,preset-check}.log.

The original gap list CORE-1...10 and shared CAP-3/ED-2/7/8/9/13/RND-5/8 Core
contributions are delivered and integrated. b8575bc checkpointed the final
master-blur regression correction and README before integration. Prior verified
Core log: /private/tmp/yapcam-core-shared-backlog-master-ready.log (Rust91 debug
and release, Core Swift66, Clippy/fmt, signed canonical build/codesign). Native
main acceptance above supersedes this sandbox's UI Metal/display limitations.

Remaining work belongs to consumers: Editor wires markers/targeted restore,
camera style/layout controls and the master blur slider; Render consumes camera
style/LUT/crop/sharpen/grain, cutout edge controls and lens instructions and applies
actual render fps/60 to evaluated blur amounts. C ABI remains3. Contracts are in
FORMATS.md; typed APIs and integration notes are in Core README. Lead must review
the new critical paths and run native Metal/display acceptance.

Integration action: clean Swift build artifacts once after Core enum additions
before judging UI errors. `swift package clean` was necessary here: stale UI
objects encoded `.set(path:"canvas.padding",...)` as
`{"op":"remove_zoom","id":"canvas.padding"}`. This reproduces the reported
foreign clip/zoom ID symptom before preset import even begins. Temporary tracing
was removed. Full clean rebuild eliminates those ID errors.

Prior pre-freeze UI evidence (superseded by the new run above): this sandbox ran
`swift test --disable-sandbox -j 4 --filter YapcamUITests --skip appLaunchedWithSnapshotFlagRendersEverything`:
68/71 passed; saveListApplyRoundTrip passes. applyingPresetUpdatesEditorAndSaves
now reaches EditorDocument initialization and fails with `.metal("Metal preview
unavailable")`; scriptedEditsSurviveSaveAndReopen has the same environment error.
everyWindowRendersInLightAndDark lacks area-overlay-light/dark snapshots here.
The direct-binary app-launch test was excluded because it violates Lead's
LaunchServices-only launch rule. No Yapcam app launched or process signaled.
No UI/Editor/Render tests or implementation edited.


Backlog re-audit 2026-10-15 16:26 UTC: checked the brief, all Core-owned/shared FEATURES
rows and the Next list against current source. CORE-1...10 are delivered, and the
previously missed shared-row contributions listed above are now implemented.
QA owns FEATURES.md and must reconcile its stale Core todo/partial labels, while
keeping shared UI/pixel acceptance separate. The table below maps the original
assignment to tests; the READY packages describe shared follow-ups.

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

All listed tests are included in the latest Rust91/Core Swift66 passing runs.
Consumer/native acceptance remains open as described above. All verification
scripts listed and removed their owned temporary roots; no roots remain.

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

### READY ED-10 caption models and evaluation (2026-10-15 19:00 UTC)

- Optional schema1 TextStyle fields font_family/reveal/growth/entrance/language,
  exact CaptionWord timing on caption records, typed Swift enums/decoders/options
  query and CoreRenderLayer instruction DTOs. Existing styles/records migrate via
  missing-field defaults without factory appearance changes. C ABI remains3.
- Transcript import preserves existing one-record-per-word grouping and source-map
  timing, while retaining valid recognized locale. Manual untimed multiword captions
  use documented uniform reveal slots; these are not inferred speech timings.
- Exact shared edit maps preserve word clocks; cut words disappear, all-cut captions
  disappear, insertion keeps a gap, range patches scale timestamps with integer
  arithmetic, text corrections invalidate stale alignment. Undo/redo/snapshots and
  atomic journal/save/reopen carry all metadata. Captions remain excluded from presets.
- Cold layer evaluation emits full/visible text, font/layout/language choices and
  per-word visibility/progress/opacity/offset; line fade/slide are evaluated once.
  No C fields, hot-path allocations, file IO or native font-shaping claims.
- Rust104/Core Swift74/Render11 portable+4 native skips, Clippy/fmt, clean signed
  build/codesign PASS. Exact log/handoff/consumer limitations are in Next. Lead
  must checkpoint tracked and untracked files together before integration/push.


### READY b2f5593 final consumer handoffs (verified 2026-10-15 17:37 UTC; integrated/pushed 17:52 UTC)

- RND-7: canvas.inset_origin [x,y], each finite in[-1,1], defaults centered[0,0]
  for fresh/legacy projects. Queries append inset_origin for Render's existing
  screenInsetOrigin consumer; Core typed options expose it. Presets, transactional
  validation/history/save/reopen retain it; geometry/timing/ABI unchanged. One Rust
  and one Swift regression cover boundary values, malformed arrays/rollback, legacy
  default, snapshots, persistence and unchanged frame geometry.
- CAP-3 compatibility: optional recording/markers.json {markers_ns:[Int64]} loaded
  once at create/open. Merge into immutable runtime events, bound by source segments,
  stable ui-marker:<array-index> IDs; exact-time dedup prefers captured durable flags.
  Query maps pauses/splits/speeds/cuts/repeats through existing clocks. No source
  file rewritten, no query/frame IO. Malformed data returns invalid JSON explicitly;
  negative/gap/final-end/truncated-tail entries are discarded. Two Rust/one Swift
  regressions cover exact toolbar schema, ordering/dedup, paused boundaries, edits,
  snapshots, reopen, source-byte preservation and malformed input. UI should still
  forward future flags directly to Capture's durable marker API.
- RND-9 final compatibility: CoreScreenQuality decoding accepts {} with the same
  0.5/quality defaults as Render. Null/missing remains disabled. Preset filtering
  discards unknown-only objects without enabling an optional setting. Both regressions
  verified on the final source; no old appearance/default/ABI changed.
- All five new Rust/three Swift regressions are included in final Rust100/Core Swift71
  gates. Existing Render ScreenQualityTests/ProjectAdapterTests/CoreLensLayoutTests
  pass13 portable cases;6 native cases skip explicitly without Metal/media services.
  Final logs are in Next; b2f5593 contains the complete source. Previous per-package green gates
  below remain historical; final combined gate supersedes their counts.


### READY RND-9 persisted screen quality (2026-10-15 17:27 UTC)

- Optional canvas.screen_quality object/null, finite improve_quality0...1 and
  upscaling off/fast/quality; selected empty object defaults0.5/quality. Legacy
  missing/null and factory null retain old samples. Object shape is strict,
  including rejecting empty arrays; no existing model deserializer changed.
- Existing render_options/render_options_at/effects_at append screen_quality;
  Render already consumes it in ProjectRenderOptions -> shared compositor. Swift
  CoreScreenQuality/setScreenQuality/CoreRenderOptions.screenQuality expose it.
  No geometry, timing, ABI or default changes. Editor owns the controls.
- Presets include the portable setting and filter unknown object descendants
  before merge; batch/history/snapshot/save/reopen preserve it. Two Rust/one Swift
  new regressions cover validation rollback, defaults, all modes, optional preset
  merge, frozen-style legacy absence, history/persistence and unchanged frames.
- Rust97 PASS/1 intentional scale ignore; Core Swift69 PASS; four-seed10000-command
  FFI fuzz now also mutates quality; Clippy -D warnings/fmt/diff, CLEAN canonical
  signed app and strict codesign PASS. Log /private/tmp/yapcam-core-screen-quality-ready.log.
  Native pixel acceptance remains with Render/Lead. Trapped temp root listed/removed.


### READY b852c2c AUD-06 persisted enhanced microphone selection (2026-10-15 16:51 UTC; integrated/pushed 17:12 UTC)

- Documented schema/commands/query first in FORMATS.md. Optional
  audio.mic_replacements defaults empty, validates source/asset bindings, and is
  filtered on both preset save/apply. No existing appearance/default/ABI changes.
- Capture the original identity before isolation with microphoneIdentity(path:),
  call Capture VoiceIsolationService, then importEnhancedMicrophone(report.output,
  forOriginal: identity). Import checks 48k Float32 PCM, channel count and duration
  within one sample; copies into assets and selects in one undo step. Stale source,
  invalid output and closed-project failure clean staged assets. Existing source
  recordings and manifest are unchanged. useOriginalMicrophone(path:) clears choice.
- microphoneMedia()/q:microphone_media expose original/effective path/index,
  enhanced/stale. audio_ranges selects effective media without changing clocks,
  offsets, speed, clip gains or automation; map_audio_ranges accepts either path.
  Existing Render adapter consumes this same query for preview/export. Speech
  mastering's plan uses/deduplicates effective files; enabling DSP is independent.
- Source or derivative relink changes registered identity and invalidates the old
  binding; query falls back to original with stale=true. Save/reopen and snapshots
  preserve selection/history. Physical missing/changed media keeps normal open
  validation. Files remain for snapshots/undo, with no automatic cache cleanup.
- Verification: Rust95 PASS (1 intentional scale-test ignore), 10,000 random FFI
  commands across four seeds/31 families including new selection/set/query;
  Core Swift68 PASS, Clippy all-targets -D warnings, fmt/diff and canonical signed
  app build + strict codesign PASS. Four Rust/two Swift new regressions cover
  edited/repeated mapping, history/snapshots/reopen, stale relink, invalid/batch
  rollback, independent/shared-file selection, preset isolation and staged cleanup.
  Main logs /private/tmp/yapcam-core-mic-selection-{check,ready}.log.
- Consumer work: Editor selection/progress/error UI and Capture native isolation
  quality/latency acceptance. No native isolation or live media success is claimed.
  Original gap-list CORE-6 preset behavior is unchanged. All finished verification
  roots were listed and deleted by with-temp.sh traps; no app launched/PID signaled.
- Files included in Lead checkpoint b852c2c: Sources/YapcamCore/{MicrophoneMedia,SpeechEnhancement,
  Types}.swift; Tests/YapcamCoreTests/SpeechEnhancementTests.swift; core/src/
  {microphone,commands,hardening,lib,model,preset,project,query}.rs; core/README.md;
  docs/FORMATS.md; docs/status/core.md. Header/other teams' files untouched.


- RND-8 Core READY: optional canvas.global_motion_blur multiplier, factory1/legacy null, applied once to screen/zoom/pan/cursor Frame/FrameMotion/Extras/cold-option strengths. Null preserves independent stored amounts; master0/.5/1, legacy decode, bounds, presets/history/save/reopen covered. Rust91/Core Swift66 PASS. Frame geometry itself carries no blur amount: the regression samples evaluated Frame during a moving spring interval. Only this final test correction remains outside checkpoint6511eb2. Editor: single slider binds global_motion_blur; Render: apply actual fps/60 once to evaluated amounts, and may disable preview blur.

- ED-7 Core READY: additive insert_source / EditCommand.insertSource at a clip boundary restores source bounds and original clip settings without undoing unrelated edits. Exact rational prefix mapping distinguishes start/end edges at insertion and covers every timed collection, including camera silence ranges. Screen/audio/input share clip time; no recording writes. Empty timeline restoration, invalid/beyond-source/minimum rollback, fractional long clocks, history/snapshot/reopen and audio-clock regressions pass. Rust90/Core Swift65 + Clippy + signed build/strict codesign PASS, /private/tmp/yapcam-core-shared-backlog-ready.log. Editor: retain original transcript source-word ranges, batch insertSource + add-caption for targeted restore; existing cut/hide/correct primitives remain available.

- RND-5 Core READY: per-zoom style/lens parameters, inherited insertion style, shared classic/lens spring weight and active-zoom selection, local zoom_lens_at instruction and typed Swift CoreZoomLens/ZoomLens. Lens leaves base crop unchanged; camera sizing still follows zoom weight. Manual/auto pointer targets, crop clamping, null inactive endpoints and old classic defaults supported. Rust88 + Core Swift64 PASS; /private/tmp/yapcam-core-lens-ready.log (Rust/build) and /private/tmp/yapcam-core-lens-swift.log (final Swift). Native lens shading remains Render-owned.

- ED-9 Core READY: additive layout_settings, cutout/split modes and per-range settings; exact frame fitting/orientation/flip/padding/corners, cutout matting flag, silence gating with remapping. Missing camera falls back to screen. Legacy geometry defaults retained and frame/extras allocate zero. Rust geometry/boundary/history tests and full Core Swift suite pass; /private/tmp/yapcam-core-camera-layout-swift.log and final shared-backlog log. Extreme positive camera crop ratios also stay finite. Softness/inset rendering and controls are Render/Editor handoffs.

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

- Latest complete code checks: Rust91 debug/release, Core Swift66, Clippy all-targets -Dwarnings, cargo fmt/diff, canonical signed build and strict codesign PASS. Four-seed10000-command FFI fuzz now exercises29 command families plus all new plain/time-specific queries; the query rotation was corrected to reach every family. Frozen v0/v1 migration, all-FFI panic guards, concurrent durable edits and zero-allocation frames remain green.
- Final full log: /private/tmp/yapcam-core-shared-backlog-master-ready.log. Clean-build baseline before the final master addition: /private/tmp/yapcam-core-shared-backlog-final-swift-ui.log. UI71 run has68 passes and3 Metal/display issues; no clip/zoom ID errors. Direct-binary app launch excluded by Lead's LaunchServices rule. Native replay remains required.

- Unity clip settings omit JSON to keep large projects compact; Swift ClipInfo.effectiveSettings supplies defaults. Key overlays reuse the immutable time index on gain/cursor-only clip edits. Frame audio uses the already resolved clip index, avoiding repeated source scans. Gain/mute/smoothing inheritance and allocation-free capability frames are tested.

- Final debug/release Rust80 PASS plus the separately invoked ignored scale case. Includes frozen schema migration, 10,000 randomized FFI commands across four seeds, new typing/preset paths and queries, rollback/persistence checks, every-FFI top-level catch_unwind coverage, cropped first zoom-frame clamps, frame reads during durable edits, new/old defaults, preset extremes, early timing, fractional/repeated typing ranges and cursor Retina independence.
- Core Swift58 PASS; canonical scripts/build-app.sh with Yapcam Dev Signing and strict codesign PASS. Clippy all-targets -D warnings, cargo fmt --check and git diff --check PASS.
- Logs: /private/tmp/yapcam-core-reference-ready.log and /private/tmp/yapcam-core-reference-ready-release.log. Earlier separate package checkpoints are in /private/tmp/yapcam-core-reference-{1,2,3,5,6}-check.log (CORE-2's corrected Swift expectations are in reference-2-swift.log).
- Broader non-live Core+Editor run: 182 tests executed, 43 issues (42 report Metal preview unavailable; one preset-name test writes under ~/Library/Application Support/Yapcam/Presets outside the sandbox). No broader green claim. Source build succeeds; Lead/native Editor acceptance remains required. Log /private/tmp/yapcam-core-reference-final-check.log. No other team's files changed to bypass these limits.

## M3 scale — READY

Latest shared-backlog source (including master blur and source restoration), same
60min/3.6M-events/5000-clips/1000-zooms workload, release C ABI. Frame p99
.112250ms and worst sampled edit19.388542ms PASS; targeted restoration p99
10.923167ms. Save12.803792ms; project.json1,136,434bytes. Complete current metrics:

```text
SCALE workload=60min events=3600000 rate_hz=1000 clips=5000 zooms=1000 build_s=0.144 clock=Instant profile=release seed=0x19bc48
SCALE yc_frame_at n=2048 p50_ms=0.086916 p99_ms=0.112250 max_ms=0.132417
SCALE key_overlay enabled=true captured_keys=36000 shortcuts=18000 yc_query_layers_at n=1024 p50_ms=0.101458 p99_ms=0.127000 max_ms=0.133875
SCALE yc_apply durable=false n=64 p50_ms=1.880625 p99_ms=2.259333 max_ms=2.259333
SCALE yc_undo durable=false n=64 p50_ms=0.145125 p99_ms=0.159833 max_ms=0.159833
SCALE yc_apply durable=true n=64 p50_ms=11.796583 p99_ms=19.388542 max_ms=19.388542
SCALE yc_undo durable=true n=64 p50_ms=8.956250 p99_ms=12.918458 max_ms=12.918458
SCALE set_speed durable=true n=8 p50_ms=10.910000 p99_ms=12.071333 max_ms=12.071333
SCALE split durable=true n=8 p50_ms=10.018375 p99_ms=11.018166 max_ms=11.018166
SCALE insert_source durable=true n=8 p50_ms=9.904541 p99_ms=10.923167 max_ms=10.923167
SCALE delete_30min durable=true n=8 p50_ms=9.791583 p99_ms=12.963959 max_ms=12.963959
SCALE auto_zooms durable=true n=8 p50_ms=8.833042 p99_ms=9.037166 max_ms=9.037166
SCALE typing_suggestions query_ms=2.576208
SCALE auto_speed_typing durable=true n=8 p50_ms=12.042875 p99_ms=14.553833 max_ms=14.553833
SCALE typing_undo durable=true n=8 p50_ms=9.076667 p99_ms=10.959791 max_ms=10.959791
SCALE yc_project_save ms=12.803792 project_json_bytes=1136434
```

Earlier baseline below is retained for comparison (before style/lens fields).

60-minute synthetic source; 3,600,000 events at1kHz; 5000 clips; 1000 zooms; 36,000 keys/18,000 shortcuts; full aligned cursor smoothing enabled. Release C ABI calls, Instant clock, fixed seed0x19bc48, 2048 frame samples/1024 layer samples; 64 apply/undo samples per durability mode and eight samples per timeline automation operation. Earlier baseline source run:

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

- Editor: Project.markers() supplies timeline marker/snapping positions; insertSource restores original transcript source bounds at a cut boundary while preserving later edits (batch add-caption for the label). Adopt cameraLayout(atNs:)/layout_settings, typed camera style/importCameraLUT and global_motion_blur. Original CORE-1...10 consumer contracts remain below.
- Render: CoreRenderOptions.cameraLayout / cameraStyle / zoomLens are optional typed cold outputs; base Frame already evaluates split/cutout geometry and visibility. Implement camera grading/LUT/crop/sharpen/grain, cutout softness/inset and lens sampling/bevel/chromatic shading. Do not apply master blur twice; Core has multiplied it. Actual preview/export fps/60 remains yours.

- Render/Editor: ED-8 camera.style contract is in FORMATS.md. Consume CoreRenderOptions.cameraStyle / CameraStyle and cameraStyleLibrary(), implement grading/LUT at intensity, crop/sharpen/grain/blur and controls. CubeLUT parser + Project.cameraLUT()/importCameraLUT(from:) are provided; custom recipes are our own. No C ABI layout changed. CAP-3 Project.markers() is ready for timeline/snapping.

- Editor/Lead: adopt checked timelineEdit envelopes, setClipSettings + ClipInfo.effectiveSettings, insertTimelineItem helpers, coalescedEdit gesture keys, insertionStyles/capabilities and ProjectAutosaver. The existing Editor timer is2s; remove/replace it when adopting the30s coordinator, and cancel the coordinator before final save/Project.close. Preserve saved choices behind capability gates. These integrations belong to Editor; no Editor source/tests changed.
- Lead independent review before merge: new shared paths are source_insert.rs/time::InsertTimeMap, zoom_lens.rs/frame.rs, camera_layout.rs, camera_style.rs, preset.rs, motion master multiplication and Swift CubeLUT/asset staging. Also retain review of core/src/editing.rs (checked recursion/insertion/history policy), capabilities.rs/frame gates, and Sources/YapcamCore/Autosave.swift plus Project revision mutations. C ABI remains3 with no header/layout changes. Additive contracts are in FORMATS.md; publish Swift surface in SWIFT_API.md. Native integration/pixels remain owners' work.

- Lead: checkpoint the final master-blur regression correction/README/status after6511eb2, then push team/core and integrate Core+Render after a clean Swift build and native UI replay. Publish typed Swift additions in SWIFT_API.md from the contract in FORMATS.md/Core README. Independent review/native integration remains with Lead.
- Render: consume cold screen_shadow.offset_x (and directional style) alongside already evaluated scalar y/radius/opacity. Swift CoreRenderOptions.ScreenShadow is available; no C header extension is needed. Wire stereo_mic preference where channel layout is chosen. DSP presets already flow via existing speech settings. Native pixel/audio acceptance is not claimed by Core.
- QA/Lead: reconcile GAP-CORE-1...10 using the backlog audit evidence table above; all assigned Core implementations are delivered, with consumer/native acceptance separate. Other FEATURES evidence predates delivered Core work: PRJ-08 frozen v0/v1 migration is verified, EDT-07 output dimensions are covered, REC-16 owned-copy import/save/reopen passes (native export remains separate), and ZOM-01 must describe the new click-window/merge rules when Core integrates. FEATURES.md remains QA-owned.
- Editor: wire typingSuggestions() and new apply/dismiss/restore commands, mic preset/stereo paths, ratio padding and directional-shadow paths, new screen/cursor presets and start_early. Keep our extras after reference sections; hotkey layout/UI ordering stay with UI/Editor owners. Existing logical cursor artwork categories remain an additional selection; do not double-apply the numeric size.
- Existing Project.close() barrier, immutable key indexes, audio range mapping and F9 optional source-name support are integrated. Lead's previous native F6 audio-tail export acceptance remains valid; no new audio-clock change made here.

## Runtime and cleanup rules

No Yapcam app launched or process signaled for this assignment. Before any future launch check ~/Movies/Yapcam/QA/.app-lock, honor all other running instances, and launch through open -n -W <build>/Yapcam.app --args ... for TCC attribution. Only terminate exact PIDs Core started; never broad kill/quit, sudo or TCC reset.

All verification used core/scripts/with-temp.sh, reused normal build caches and cleaned its owned root on exit. The wrapper now lists its exact root before removal. Final check found no yapcam-core-run.* roots remaining. No recordings, credentials or dependencies added. Native Metal/device/export validation remains with the corresponding owners.
