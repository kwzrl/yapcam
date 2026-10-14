# Yapcam core integration

Rust owns schema 1 `project.json`; `src/model.rs` is the authoritative type and
setting definition. Swift `YapcamCore.Project` owns the C handle; Rust serializes
mutations separately from concurrent readers. `snapshot()` copies capture/event state and disables autosave writes for
that independent handle. Preview and export call the same `frame(atNs:)` evaluator.
Successful `yc_frame_at` does not allocate, read files or mutate project state.

## Commands

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
