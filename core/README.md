# Yapcam core integration

Rust owns schema 1 `project.json`; `src/model.rs` is the authoritative type and
setting definition. Swift `YapcamCore.Project` owns the C handle; Rust serializes
mutations separately from concurrent readers. `snapshot()` copies capture/event state and disables autosave writes for
that independent handle. Preview and export call the same `frame(atNs:)` evaluator.
Successful `yc_frame_at` does not allocate, read files or mutate project state.

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
| auto_speed_typing | optional speed (default 3); ≥3 keys within 600 ms gaps; 150 ms padding |
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
- session / project: complete immutable session or current project data.
- preset: portable settings only; omits camera layouts, cursor/audio ranges,
  recording IDs, notes and media references.

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
  image bytes never cross C. Plain settings-only presets remain supported.
  Imported files remain on disk after undo (references are non-destructive).
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
