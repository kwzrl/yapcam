# Yapcam core integration

Rust owns schema 1 `project.json`; `src/model.rs` is the authoritative type and
setting definition. Swift `YapcamCore.Project` owns the C handle; Rust serializes
mutations separately from concurrent readers. `snapshot()` copies capture/event state and disables autosave writes for
that independent handle. Preview and export call the same `frame(atNs:)` evaluator.
Successful `yc_frame_at` does not allocate, read files or mutate project state.

Session `source.display_name` is optional for every source kind, including older
packages. Rust reads it as `Option<String>`; the in-memory session query and Swift
`SessionInfo.Source.displayName` use the recorded nonempty name, then a nonempty
window title for window sources, otherwise `Display <display_id>`. Swift retains
its existing nonoptional displayName API and also supplies this fallback when
decoding session JSON directly. Reading or saving the project does not rewrite the
recording manifest. Capture geometry/timing validation remains required.

`Project.close()` permanently disables apply/undo/redo/save on that Swift wrapper
with `CoreError.status(6, "Project is closed")`. It waits for an active mutation and
its journal IO to complete, then returns without saving or freeing the C handle.
Call it after the document's final save, before reopening the package. Frame/query
reads remain available and do not take the mutation gate. Export snapshots own
independent lifetimes. Notifications run outside the gate, so observers may close
the project. This is a per-wrapper lifetime boundary, not a package-wide lock;
callers must close each stale writer. Import helpers commit through the same apply
gate, rolling back their newly staged asset if that commit is rejected.

## Commands

Run Core checks through the cleanup wrapper so temporary fixtures are also removed
if a test process crashes:

```sh
zsh core/scripts/with-temp.sh env CARGO_BUILD_JOBS=4 cargo test --manifest-path core/Cargo.toml
zsh core/scripts/with-temp.sh swift test --disable-sandbox -j 4 --filter YapcamCoreTests
zsh core/scripts/with-temp.sh scripts/build-app.sh
```

It creates one `yapcam-core-run.*` root, exports `TMPDIR` for child fixtures and
`YAPCAM_CORE_TMP` for harness files, and removes the root on exit or HUP/INT/TERM.
Keep logs outside that root. Reuse the worktree's normal build caches; for isolated
builds put `--scratch-path "$YAPCAM_CORE_TMP/build"` inside the wrapped command.
Every new Core script creating a temporary directory must install a cleanup trap
immediately after creation, before copying or building. SIGKILL or host crashes
cannot run shell traps; list and inspect only Core-owned abandoned runs before
removing them.

All successful changes are one undo step; no-op commands do not create history.
Failed commands/batches change neither state nor history. `yc_apply` returns
`{"changed":[...],"createdIDs":[...]}`. Arrays below use integer nanoseconds.

| op | Arguments |
|---|---|
| split | at_tl_ns |
| delete_range | tl_start_ns, tl_end_ns; half-open range |
| set_speed | clip_id, speed (0.05…32) |
| add_zoom | zoom object, or fields at command top level: tl_start_ns, tl_end_ns, mode, target [x,y], scale, ease_in_ns, ease_out_ns, enabled (optional, default true); id generated |
| update_zoom | id, patch object; id immutable, unknown keys rejected |
| remove_zoom | id |
| set | path, value; known setting path only |
| batch | commands array; nested batches limited to depth 32 |
| auto_zooms | optional scale (default 2); replaces auto zooms and retains manual zooms |
| auto_speed_typing | optional speed (remembered, initially 3; 1.5…8); apply all non-dismissed captured bursts with gaps <500ms, span ≥1.5s and density ≥2 keys/s |
| apply_typing_suggestion | id, optional speed; apply one captured burst to every retained occurrence |
| dismiss_typing_suggestion | id; persist the source-stable dismissal |
| restore_typing_suggestions | clear dismissals |
| process_silence | ranges [{tl_start_ns,tl_end_ns}], mode `cut` or `speed`, speed if mode speed; merges overlap and applies from right to left |
| apply_preset | preset object containing only canvas/cursor/camera/audio/zoom_settings/export settings |
| add_media | path (existing package-relative file), role `asset` or `background`; returns asset-N and selects image background when requested |
| relink_project | recovery-only: complete project object and paths array; refreshes fingerprints only for selected paths, verifies every remaining reference, restores all edit state |

Swift mirrors these in `EditCommand`. `JSONValue.integer(Int64)` preserves precise
large values in generic settings; standard edit times encode directly as Int64.
`Project.clicks()` returns typed mouse-down records with edited `tlNs`; refresh
snapping caches after timeline changes. The complete set-path/default inventory
and ABI-v2 contract are now documented in `docs/FORMATS.md`.
`Project.relink(package:replacements:)` stages replacement files, preserves the
latest autosave edit state, and rolls back files/metadata if reconstruction fails.
Files must be compatible with the recorded dimensions and segment timing.

`audio_ranges` describes logical recording intervals from the session manifest,
track starts, clip edits and gain boundaries. Its file end is a requested endpoint;
Core does not inspect or decode the audio container to establish available samples.
Recording audio can end before the segment does. The media consumer must intersect
each requested file interval with the audio track's actual available time range,
map both trimmed endpoints back to the edited timeline, and leave unavailable
intervals silent. Preserve the project duration and track offsets. Container-level
duration, edited AVFoundation track duration and decodable sample extent can differ;
retain decoder errors instead of assuming that an arbitrary tail trim repairs them.

## Setting paths

Use `set` on the following objects or their documented leaves. Arrays are replaced
as a whole (a single undo step). Setting unknown fields or invalid values fails.
Nested setting objects can be replaced; omitted leaves take schema defaults. Root
setting objects are replaced through apply_preset.

- `canvas`: aspect (`source`, `custom`, or positive W:H), output_size [width,height],
  padding, radius, shadow.{radius,opacity,offset_y}, inset, inset_color RGBA,
  motion_blur, crop [x,y,w,h], background.{kind,color,color2,angle_deg,asset,blur,noise},
  window_chrome, highlights, animation (below).
  Background kinds: solid, gradient, image, blurred_screen. Colors are sRGB [0,1].
- `cursor`: visible, size (0.1…10), smoothing (0…1; zero gives raw interpolation),
  hide_when_idle, idle_timeout_ns, click_effect (none/ring/highlight),
  click_duration_ns, speed_preset, spring, loop_to_start, loop_duration_ns,
  ranges [{tl_start_ns,tl_end_ns,visible}], style (recorded/pointer/touch),
  motion_blur (0…1), spotlight_radius (output pixels). Latest active range wins.
- `camera`: visible, position [x,y], size (fraction of canvas width), shape
  (rounded_rect/circle/squircle), radius, mirrored, opacity, shadow_radius,
  background_removal, face_framing, layouts
  [{id,tl_start_ns,tl_end_ns,mode,camera_position?,camera_size?}]. Modes: screen,
  camera, overlay, side_by_side. A camera-only layout keeps screen visible when
  there is no camera track; absent camera samples never become fabricated media.
- `audio`: mic_gain_db, system_gain_db (−96…24), mic_muted, system_muted,
  ranges [{id,track,tl_start_ns,tl_end_ns,start_gain_db,end_gain_db}]. Track is
  mic or system_audio; automation adds a linear-in-dB envelope to global gain.
- `zoom_settings`: automatic, follow_cursor, dead_zone (0…0.45), speed_preset,
  spring. Global automatic=false also suppresses existing auto zooms in evaluation.
- `export.last_preset`, `notes` (speaker notes text), `autosave` (boolean).

Spring presets: custom, slow, mellow, quick, rapid. `spring` has tension (1…2000),
friction (1…200), mass (0.1…10), allow_overshoot. Event smoothing and zoom transitions
use analytic damped responses, so they do not depend on preview/export frame rate.
Effects use normalized coordinates; canvas lengths use output pixels.

## Queries

`Project.query(_:as:)` takes JSON, e.g. `{"q":"clips"}`. Results:

- clips: clip records plus tl_start_ns/tl_end_ns.
- zooms / layouts / media (assets alias): corresponding arrays.
- duration: {duration_ns}.
- audio_ranges: media intervals split at clip, segment, track-start and gain-range
  boundaries. Includes track, path, segment, clip_id, src_start_ns/src_end_ns,
  file_start_ns/file_end_ns, tl_start_ns/tl_end_ns, speed, gain, gain_start,
  gain_end, base_gain_db and muted. Gain values are linear amplitudes; exporters
  should honor endpoints as a dB ramp, not hold the legacy gain constant.
- audio_automation: persisted automation ranges.
- clicks (cursor_clicks alias): down events with segment, src_ns and tl_ns.
- events: all retained events with the same mapping; removed events disappear.
- markers: captured marker occurrences with id/marker_id/segment/segment_ns/
  src_ns/tl_ns/clip_id, exact cut/speed/repeated-clip mapping, half-open bounds.
  Swift Project.markers() returns [TimelineMarker]; markerID is capture identity,
  id is occurrence identity. Immutable event logs survive save/history unchanged.
- session / project: complete immutable session or current project data.
- preset: portable style fields only; omits clips, zoom records, timed effects,
  source crop, recording IDs, notes and media references. Export and apply share
  one schema filter. Apply ignores old foreign IDs/ranges and recursively merges
  style leaves, preserving destination edits and omitted settings.

## Files and recovery

Save writes a unique temporary file, fsyncs it, renames it, then fsyncs the directory.
The previous valid JSON becomes project.json.prev. A corrupt primary never replaces
a valid .prev; newer schemas are refused even when an older .prev exists. Version
0 prerelease data migrates to schema 1 with defaults. Missing/changed media returns
YC_ERR_MISSING_MEDIA and a JSON array of relative paths in the error string.

Autosave writes the validated next state to autosave/project.json before changing
memory. Open restores a valid journal with the matching project ID. Save clears the
journal after committing the primary. A journal IO failure rolls back the edit.
Undo/redo also journal their resulting state. There is one editor writer per package;
independent exports use snapshots and do not autosave.

The handle's writer mutex serializes apply/undo/redo/save. Edits stage under a read
lock; journal serialization/path checks/write/fsync/rename run with no state lock;
only successful durable states publish under a brief write lock. Save also copies
its state then runs disk IO outside the state lock. Swift adds no shared lock around
these calls, so frame/extras/read queries keep reading the previous complete state
while a writer waits on disk. Mutations still return synchronously after durability;
no debounce window or weaker recovery guarantee was introduced. Notifications run
after the writer gate is released. Tests pause all four disk stages deterministically,
verify allocation-free frames continue, test concurrent writer/history ordering,
and preserve rollback on IO failure. A caller must not free a handle during calls.

Every C export (including getters/free/error functions) contains Rust unwinds at
its outer boundary. Status functions return YC_ERR_INTERNAL on panic; scalar getters
return zero, last_error returns a static panic string, and void functions return
without an escaping unwind. A test injects a top-level panic at every header entry
and Rust C export; another injects a disk-stage panic and verifies frames still read.

Media fingerprints are `fnv1a64:` plus the hex FNV-1a hash of the first MiB and the
full file size. These detect changes, not authenticity. All media references must
stay within the package, including through symlinks; cursor PNGs are included.

Time mapping retains rational fractional nanoseconds and rounds at the integer API
boundary. Extreme denominator combinations use Q32 fractional nanoseconds instead
of rounding each clip. The screen, camera, system/mic audio and event clock share
one clip list. Per-track file time subtracts track_start_ns; before the first sample,
the track is absent. At durationNs, evaluation returns the last source nanosecond;
negative times and times after the duration fail. Empty timelines have no frame.

Cuts, speed edits and typing automation now use rational arithmetic when retiming
zoom/layout/cursor/audio/highlight ranges too. Snapped clip edges map to their
exact source endpoints; deleting the rounded whole duration removes the final
source sample rather than leaving a sub-nanosecond tail. A cut shifts effects by
the source media actually removed at the current rate; source-ns quantization can
make this differ slightly from the requested integer timeline range. Unchanged
speeds do not alter times, create undo entries, journal or notify. Decimal rates
are recognized only when the rational candidate reproduces the input Double
exactly; speed=1.000000001 remains distinct from 1. Tests cover clocks beyond 2^53
with independent integer oracles and real Swift/C ABI edits.

## Swift local helpers and explicit limits

- `Project.importVideo(_:package:) async`: copies a local movie into a new package,
  preserves muxed audio, and normalizes nonidentity orientation transforms. Rejects
  existing destination packages. Movie import needs no screen-capture permission.
- `importBackgroundImage(_:)`: validates a local bitmap with ImageIO, copies it into
  package assets, hashes it and selects its index through one undoable command.
- `exportPreset(to:)` / `importPreset(from:)`: local JSON presets, including custom
  background image bytes in an optional Swift-owned `_background_image` base64 field.
  Swift extracts this field and copies the image before invoking a Rust batch, so
  image bytes never cross C. No source media index travels in the preset; image
  imports select a fresh destination index. A bare image-kind setting without
  embedded bytes never selects an unrelated destination asset.
  Plain settings-only presets remain supported. Imported files remain on disk after undo (references are non-destructive).
- `AudioAnalysis.silence(in:thresholdDB:minimumNs:) async`: native PCM decoding and
  cancellation; returns file-local intervals. Pass those to
  `Project.mapAudioRanges(_:track:mediaPath:)` (track mic/system_audio; mediaPath
  from audio_ranges) before `processSilence`. The read-only helper uses the current
  shared rational clock, clips/segments/track starts and every retained occurrence;
  overlapping or adjacent results merge. Use a snapshot for frozen analysis, or
  map after decoding to use the latest edits. No decoder or file IO runs in mapping.
- Compressed audio codec services can be unavailable under restricted macOS
  execution; this returns explicit CoreError.status(6), never a guessed silence list.
- Supplemental effects use the renderer hooks described below. Core evaluation is
  verified, but Render/Editor adapters and GPU pixel checks remain integration work.
  Entrance/exit currently support none/fade; scene transforms and other animation
  presets fail explicitly until implemented.


## Supplemental render effects (M2)

`renderOptions()` returns typed `CoreRenderOptions` for Render's existing
`RenderConfiguration`: cursor style/blur/spotlight, background noise, window chrome,
camera background removal/face framing/shadow radius. Defaults match Render's
neutral defaults. Cache options after edits rather than querying every frame.
Camera Vision processing and visual effects still require renderer/host verification.

`renderLayers(atNs:)` returns ordered `CoreRenderLayer` instructions in canvas
pixels. The cold JSON queries are `render_options` and `layers_at` with integer
`tl_ns`; these preserve the 328-byte C frame and its allocation-free evaluator.
The Editor-owned ProjectRenderSource adapter should convert each record to
RenderLayer.highlight, pass rect/radius/opacity/colors/stroke through, and supply
these to `renderLayers(atNs:)` for both preview and the export snapshot. No effect
math belongs in the adapter; Rust uses the same crop/layout/zoom geometry as YcFrame.

Use `set canvas.highlights` with an array of records:

```json
[{"id":"focus-1","tl_start_ns":1000000000,"tl_end_ns":3000000000,
  "rect":[0.25,0.25,0.5,0.5],"space":"source","radius":12,
  "opacity":1,"dim_opacity":0.4,"fill":[1,0.85,0.2,0],
  "stroke":[1,0.85,0.2,1],"stroke_width":3}]
```

Times are half-open. IDs are unique. Rects are normalized in `source` (default) or
`canvas` space. Source highlights follow screen zoom/crop and are clipped to the
visible source; completely hidden regions produce no layer. Opaque fill masks the
selected region, transparent fill with dim_opacity creates a spotlight. Lengths
(radius/stroke) are output pixels. Array order defines stacking. Cuts and speed
changes retime highlights along with zoom/layout/cursor/audio ranges. Portable
presets omit highlights, which are project-specific timeline data.
At most 32 highlights may overlap; excess fails validation before changing state.
Non-overlapping intervals have no fixed count limit; `canvas-fade` is a reserved ID.

`canvas.animation` has entrance/exit (`none` or `fade`), entrance_duration_ns and
exit_duration_ns (default 400000000). Fades use an analytic quintic ease and draw
black over the complete composed frame as the last layer; durations clamp to the
project length and overlapping fades take the darker result. They do not add
frames or change audio. A snapshot freezes options and layers for export.

ABI version 2 also exposes `Project.frameExtras(atNs:)` / `yc_frame_extras_at`.
This is the allocation-free path for per-frame extras: YcFrameExtras (2600 bytes)
contains the above options, a valid prefix of 32 YcFrameHighlight slots, and final
fade_opacity. It shares highlight/fade math with the cold layer query. Draw highlights
in order then the black fade; do not also draw the cold-query layers or effects
would be doubled. Export frame/extras should use the same immutable snapshot;
each call locks independently. The old YcFrame layout and signatures are untouched.

Clip and audio interval queries now use the same rational mapping as frame/event
queries, including exact source interval endpoints, rather than accumulating
Double durations; long synthetic clocks verify this against an integer oracle.

The cold query behind the silence mapper is:

```json
{"q":"map_audio_ranges","track":"system_audio","path":"recording/seg-000/system.m4a",
 "ranges":[{"file_start_ns":500000000,"file_end_ns":2500000000}]}
```

It returns `[{"tl_start_ns":...,"tl_end_ns":...}]`, clipped to retained source media
and sorted/merged on the edited timeline. Paths must refer to the chosen session
track; intervals must be nonnegative Int64 with strictly greater ends. File ranges
beyond the segment produce no retained interval. No project/history mutation occurs.


## Additive backlog effects

REC-21 notes persist as a UTF-8 string through set/undo/redo/journal/save. The
explicit field/path contract and all new paths/queries were documented first in
FORMATS.md. Schema remains 1; old frame/extras layouts remain intact (ABI v3 motion below).
Old projects default to empty
collections and disabled new effects. Existing frame/extras structs stay fixed.

Canvas annotations/reactions/captions are timeline text records with normalized
source/canvas rects and styles. add/update/remove_annotation/reaction/caption edit
them; Swift exposes add/update/removeText. import_transcript consumes Capture's
schema-1 RecordingTranscript words and maps their exact source intersections to
current timeline caption segments, preserving cuts/speeds/repeated clips. Each
import is one transaction/undo step. All effects retime under cut/speed/auto typing.

Audio music records reference registered package media or original Render calm/
bright loops, with gain, fades, looping and explicit/caption-inferred duck activity.
Audio click_sound selects enabled original soft/crisp sounds at edited click times.
audio_overlays evaluates split gain envelopes with crossing corners; effects_at
includes exact-time gain_at and layers/options. Assets remain available for redo;
Swift importMusic validates/copies/registers/adds in one edit and cleans failed copies.
Existing asset directories support repeated music/image imports.

Opt-in cursor.key_overlay renders latest eligible captured key/modifiers. New
intro/outro zoom/slide modes transform primary frame geometry without allocation
or renderer tweening. Camera layouts can override existing Vision/shadow options;
frame_extras, render_options_at and effects_at agree at each time. layers_at now
returns text + separate styled backgrounds in defined order before the final fade.
Text payloads and music descriptions cross allocated JSON queries, never pixels or
new ABI fields. Swift effects(atNs:) returns a matched layers/options/audio state.
Render adapters own text drawing, external audio decoding/mix and Vision processing;
Core status records their integration requirements and native-host checks.


## Guide audit: cursor and motion (ABI v3)

CUR-12..16 add forced system pointer, velocity tilt, cursor tail hold, shake
suppression and cursor-type debounce. InputCache builds immutable 1-point-filtered
position and 80ms-stable type indexes once when events load. The toggles switch
index views; original event/snapping data remains unchanged. Tail hold samples the
edited duration minus the requested ns; stops dominate loop-to-start during the
tail. ANI-02 focused/smooth presets override zoom/pan springs analytically;
ANI-03 per-kind zoom/pan blur settings inherit the legacy strength when null.
CAM-07 scales overlay camera size with evaluated zoom progress; full/side-by-side
layouts retain their fitted regions. Disabled/default fields preserve prior behavior.

ABI version 3 adds YcFrameMotion (24 bytes) and yc_frame_motion_at; old frame 328
and extras 2600 layouts are unchanged. Motion returns signed bounded cursor tilt
and active cursor/zoom/pan strengths with no allocation/IO/mutation, and suppresses
velocity trails across clip boundaries. Legacy frame.motion_blur uses the same
screen-movement math. Every one of 19 C exports has panic-injection coverage.
The motion read also completes with zero allocations while durable apply/undo/
redo/save IO is paused outside project locks. Cold motion_at/render_options_at/
effects_at expose the same math; Swift frameMotion/motion bridge both surfaces.
Original procedural music_library descriptors match Render's calm/bright loops.

Full paths/defaults/queries were documented before implementation in FORMATS.md;
Swift signatures/layouts in SWIFT_API.md. Tests exercise repeat/backward seeks,
cuts, undo/save/reopen, zero allocation, layout/clamp bounds, type-flicker and jitter
fixtures, long Int64 tail settings, and prerelease schema migration with unchanged
media/clocks. Cursor tilt/per-kind rendering and UI controls remain integration
work for Render/Editor; actual hardware pixel checks are separate from model proof.


## M3 reproducible hardening harnesses

Run the normal suite with `cargo test --manifest-path core/Cargo.toml`. It includes
a frozen schema corpus in Tests/Fixtures/schema, exact-field migration/round-trip
checks, a fractional-edge oracle for indexed cut mapping, and 10,000 seeded random
JSON commands sent through the actual C ABI. Fuzz failures print seed, step and
command; checks cover rollback/history, valid state/frame outputs, immutable
snapshots, invalid UTF-8/JSON/deep batches and 100 durable save/open round trips.
The new Swift MigrationTests also opens frozen v0/v1 packages through the ABI.

The large benchmark is deliberately ignored by the normal suite; run:

```sh
CARGO_BUILD_JOBS=4 cargo test --release --manifest-path core/Cargo.toml scale_60_minutes -- --ignored --nocapture
```

It generates a 60-minute capture model with 3,600,000 events at 1kHz in memory,
5,000 clips and 1,000 zooms; no generated events or recordings enter the repository.
Media references come from copied synthetic fixtures. This measures evaluator/edit
scaling, not pixel decoding or capture-file load time. It calls the real yc_frame_at
boundary at 2,048 seeded random times after 32 warm-ups, checks zero hot allocations,
and reports nearest-rank p50/p99/max wall-clock latency from Instant. Property
apply/undo each have 64 samples with autosave off and on; speed/split/30-minute cut
and auto-zoom each have eight durable samples. Edit measurements include actual
journal writes/fsyncs when enabled. Save includes durable project/.prev publication;
project.json size is measured from the file. Limits: frame p99 <=1ms and every
sampled edit <=50ms. Times are host/load-specific; read docs/status/core.md for
the workload, measured results, and before/after fixes.


The review-2 key-overlay fix builds immutable source-key labels on project load,
and edited key-time/shortcut indexes on timeline changes. Edits/history stage new
indexes before durable publication; snapshots share them via Arc. The overlay does
two binary searches at most and creates only the selected text layers. Settings
(expiry, shortcuts-only, rect/style/enable) are read live, so unrelated settings
reuse the index. Key query metadata shares the same edited map. Raw capture changes
reload the project; unit fixtures explicitly rebuild the source index after direct
event mutation. Stable duplicate-time ordering and empty-key suppression match the
old full query. The scale harness now includes 36,000 keys (18,000 shortcuts) and
reports real yc_query/layers_at p50/p99 alongside frame and edit limits.


CUR-06 selection persists nullable cursor.set_id and cursor.shape plus
cursor.logical_size (regular by default). cursor_library exposes the twelve own
palette IDs, ten explicit shapes and four logical sizes. Root/timed options carry
those selections; always_default forces effective arrow shape while preserving
palette/size. Legacy style codes and frame layout/scale stay unchanged. Render
reads the cold options to select its generated artwork; the logical size changes
artwork dimensions, not Core's animated frame scale. FORMATS.md lists all values
and SWIFT_API.md documents CoreCursorLibrary and typed Swift enums. Pixel/picker
wiring belongs to Render/Editor, separately from the verified Core contract.


## Aligned behavior revision 1

New projects use source aspect, 10% short-edge padding, radius16, directional
shadow (.3 intensity,25px distance,45 degrees,20 blur mapped to radius160), our
calm dark background, our classic cursor at48 logical points, motion blur1,
zoom2 and no cursor smoothing until explicitly enabled. Our authored cursor
canvas is32pt; frame.cursor_scale already maps its48pt logical size through source
points (independent of Retina raster density). Existing projects decode into pixel
padding, classic shadow and version0 spring behavior. Missing metadata never
changes an old speech recipe. No Apple/reference artwork is included.

The additive set paths and queries are specified in docs/FORMATS.md under
"Core behavior alignment". Version1 screen springs use focused250/40/2.25 or
smooth170/50/3; cursor presets use smooth470/70/3, medium340/60/3,
rapid530/40/1 or none. Custom limits5…600/5…200/.1…15 apply when custom is active;
inactive legacy custom parameters are retained when choosing an aligned preset.
Finite screen ramps compress analytically to settle within the interval; under
two capture frames snaps. Optional start_early leads by350ms.

Swift Project.typingSuggestions() decodes source IDs and all retained timeline
ranges. Apply one/all, dismiss and restore use EditCommand. Default speed3 is
remembered, apply is idempotent, and captured groups are independent of edits.
Project.setMicrophonePreset(_:) accepts voice, noiseReduction or podcast and
selects our own offline DSP recipes; SpeechEnhancementPlan.micPreset/stereoMic
carry additive metadata. stereoMic is a consumer preference; Core's prepared
microphone files preserve original channels. Renderer/Editor consumers must wire
the x shadow offset and UI controls separately; no C layout changes are needed.


## Interactive edit policy and document autosave

`timeline_constraints` reports100ms clip/zoom minimums,500ms layout/mask minimums
and3s insertion defaults. Wrap Editor interactions in
`EditCommand.timelineEdit(...)`; old precision commands can still operate on
legacy sub-minimum timelines. `insertTimelineItem` supplies defaults/clamps, and
`setClipSettings` controls per-clip amplitudes and cursor flags. Default settings
may be omitted in JSON; use `ClipInfo.effectiveSettings`. Mic/system settings feed
frames and cold audio plans; external gain is metadata while the external mixer
capability is unavailable.

Wrap a continuous gesture in `coalescedEdit(key:command:)`, retaining the same key
for the same object/property. Commits less than100ms apart share the first undo
state and final redo state. Discrete commands remain separate. Put coalescedEdit outside timelineEdit when
combining policies. History caps1000.
`historyState()`, `insertionStyles()` and `capabilities()` expose cold metadata.
Zoom/mask style inheritance excludes geometry/time/identity/disabled state and is
undoable/persisted. Capability gates preserve stored appearance; Core does not
provide device-frame artwork or an external audio mixer.

One MainActor `ProjectAutosaver(project:)` per document performs trailing30s full
saves. It respects autosave off, cancels/reset timers after edits, and uses
`save(ifRevision:)` on a worker task. Project.revision/isDirty only change after
successful mutations/save; a stale captured revision cannot write or clear a
newer dirty state. Recovery journals remain immediate. Cancel the coordinator
before the document's final save and close; replace the existing Editor timer
rather than installing two coordinators. Deterministic virtual-clock tests cover
reset/cancellation, stale revisions, disabled autosave and closed save failures.
Full path/query/command contracts are in FORMATS.md. ABI3 and C layouts unchanged.


Camera style (ED-8) persists under camera.style; q camera_style /
camera_style_library returns settings and12 original scalar recipes. Render options
append camera_style (Swift optional CameraStyle). LUT import validates 3D CUBE data,
copies/registers package media and selects it atomically. CubeLUT exposes dimension,
domains and RGB entries; Project.cameraLUT() resolves the selected local asset.
Presets omit source crop/LUT path and carry `_camera_lut` bytes through Swift file
export/import, which registers a fresh destination path. Native grading remains
Render-owned; parameters are not a substitute for rendering acceptance.


Camera layout (ED-9): camera.layout_settings persists overlay/cutout/split parameters;
per-range Layout.settings replaces root settings in that interval. Existing
side_by_side retains old geometry. camera_layout_at / Project.cameraLayout(atNs:)
returns mode/settings/actual visibility; render_options includes camera_layout.
Camera silence ranges are decoded-input timeline ranges, remapped through edits
and omitted from presets. Frame/extras share the visibility/matting result and
remain allocation-free; Render owns softness/inset pixel processing.

Lens zoom (RND-5): ZoomSpec.style/lens and remembered style/lens use classic by
default. zoom_lens_at / Project.zoomLens(atNs:) returns an optional local drawing
instruction using the same spring timing as classic, without cropping the base
screen. Render owns lens shading. C ABI stays3.

Targeted source restoration (ED-7): EditCommand.insertSource inserts immutable
source bounds at an existing clip boundary (zero/end included), returning a clip
ID. It preserves later edits and shifts affected effect endpoints by exact rational
duration, keeping ends at insertion before the new source and starts after it.
Pass original ClipSettings to preserve local volume/cursor choices. All media and
events map through the new clip; no recording rewrite or copied media. Editor can
batch add-caption for the restored word, and must retain original transcript source
bounds. Split first in the same batch to insert inside an existing retained clip.


Master blur (RND-8): canvas.global_motion_blur is an optional multiplier for all
screen/zoom/pan/cursor strengths. New projects use1; absent/null keeps independent
legacy strengths. Core Frame/FrameMotion/Extras/cold options already contain the
multiplied strength, so Render must not multiply twice; actual fps/60 belongs in
Render. UI should bind its single master control to this path. Existing per-kind
amounts remain extras and are unchanged when switching the master off/on.

### Explicit microphone isolation media (AUD-06)

Capture the original identity before calling Capture's VoiceIsolationService:
`let original = try project.microphoneIdentity(path: originalPackageRelativePath)`.
Only after successful processing, call
`try await project.importEnhancedMicrophone(report.output, forOriginal: original)`.
The async import copies the output into package assets, validates 48k Float32 PCM
channel count/duration, and atomically registers/selects it. Source identity
comparison rejects stale processing results. Failed imports remove staged assets.
`try project.useOriginalMicrophone(path:)` clears selection. Both commands undo;
files remain for snapshots/history. No original recording/manifest is rewritten.

`microphoneMedia()` exposes original identity, original/effective media paths and
indices, `enhanced`, and `stale`. `audio_ranges` already emits the selected path,
so Render's existing authoritative range consumer handles preview and export.
No Render changes or ABI changes are needed for selection. Relinking either
input or derivative invalidates the old binding and falls back to original media.
Physical missing/changed assets retain normal missing-media errors on open.
The optional `audio.mic_replacements` array is never included/applied in presets.
Speech DSP mastering is independent; its plan uses the effective selected file.
Native Apple isolation quality/latency, Editor toggle/progress and user-facing
stale/error presentation remain Capture/Editor/Render acceptance work.

### Project screen quality (RND-9)

`canvas.screen_quality` is null by default for both legacy and fresh projects.
Select an object to use the existing renderer's spatial filtering/resampling:
`try project.setScreenQuality(.init(improveQuality: 0.5, upscaling: .quality))`.
Pass nil to restore unchanged screen samples. Options are off/fast/quality and a
finite quality amount0...1. The optional whole-object set path also accepts `{}`
(default0.5/quality); nested improve_quality/upscaling paths work once selected.
CoreRenderOptions.screenQuality appears on untimed/timed/effects queries and
matches Render's existing screen_quality wire field. Presets, history, snapshots
and persistence retain it. No geometry/timing/ABI default changes. Editor wires
its controls; native pixel quality remains Render/Lead acceptance work.

### Toolbar marker compatibility

Core's existing markers()/TimelineMarker query also reads the UI's optional
recording/markers.json ({markers_ns:[globalSourceNs]}) once at create/open.
Flags are merged in memory with capture events, sorted, bounded by recording
segments and deduplicated at the same exact source clock (capture flags win).
Synthetic marker IDs retain the source array index as ui-marker:<index>.
No recording/manifest/sidecar is rewritten, no query/frame does file IO, and
snapshots retain the flags they loaded. Malformed sidecars fail explicitly.
UI should forward new flags to Capture's durable marker API when wired; this
compatibility reader supports packages already saved by the toolbar.

`canvas.inset_origin` additionally accepts [x,y] in[-1,1], with centered[0,0]
for fresh/legacy projects. render_options[_at]/effects_at and the optional typed
CoreRenderOptions.insetOrigin expose it. Render's existing screenInsetOrigin
consumer weights the inner border while retaining its total size. It is a portable
style setting with normal validation/history/save behavior; Core frame geometry
and C ABI remain unchanged. Editor owns the X/Y controls.

### Caption typography and reveal (ED-10)

Caption records now carry style.font_family(sans/serif/mono), reveal(line/word),
growth(full/expanding/centered), entrance(appear/fade/slide) and language(auto/tag).
Defaults retain existing full-line sans/appear pixels; opening old records does
not select a new caption factory preset. Use typed TextStyle enum properties,
add/update caption or whole canvas.captions set; captionOptions() lists the choices.
There are no array-index set paths. A style patch replaces that style object;
merge existing values in Editor when changing one control.

Optional CaptionWord entries carry exact timeline clocks. Transcript import keeps
one caption per retained word and records timing plus valid transcript.locale when
style language is auto. Structural edits map these clocks with media; removing a
word also removes its text. Retiming a caption scales word timings; a text-only
correction clears old alignment unless an explicit words patch supplies it.
Manual multiword captions without entries use uniform reveal slots, not inferred
speech timings. Older Swift records default to empty timings and old style values.

CoreRenderLayer.caption supplies full/visible text, layout choices, language,
line opacity/offset and evaluated per-word visibility/progress/opacity/offset.
Core already applies line opacity/slide to the layer: do not multiply them again.
Render must shape/font-fit the full/visible text, fit growth backgrounds, and apply
per-word fade/slide after shaping. Metadata persistence is not native font/pixel
acceptance; Render's prior adapter ignores these new instruction fields. It still
uses the compatible visible text and already evaluated line opacity/rect.
No new C ABI fields; frame/frameExtras remain allocation-free. See FORMATS.md
for exact enums, timing/validation rules and half-open ranges. Core stores locale
preferences but cannot enumerate available on-device Speech languages; Capture/
Editor should expose native supported-locale discovery rather than a fake list.

Round3 cursor controls (schema1/ABI3): set cursor.rotation_mode=static/tilt,
cursor.rotation_degrees=-180...180, cursor.tilt_amount=0...2 and
cursor.shake_threshold=100...2000 millipoints. New defaults are static/0/1/500;
one millipoint is 0.001 captured logical point. Threshold applies only with
cursor.remove_shakes. Older cursor objects missing it migrate to1000 (the old1pt
filter); old rotate_on_move maps to the matching mode and remains a set alias.
An explicit mode wins over that legacy alias. These are portable style values,
with history, snapshots and save/reopen. Input indexes share immutable raw data;
threshold edits/history build a compact deadband on the cold path and publish it
with the project change. Retired indexes are released outside the FFI write lock.
The compact trace preserves the original dense trace's transition/idle clocks.
Static angles survive time0/cuts/idle; tilt scales the signed velocity response
and returns to zero when idle/stopped. Existing frameMotion/motion(atNs:) and
render_options_at emit cursor_rotation_rad; Render's Project adapter already
forwards that value to cursorRotationRadians. No header/renderer change required.

R3-01 audio regression: audio_ranges endpoint gains always use the row's clip
index, including when a rounded public start lies before the exact fractional
boundary. Timeline automation still uses the endpoint time; mute flags and
gain_start/gain_end now agree across adjacent clips at fractional speeds.
