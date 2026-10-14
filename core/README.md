# Yapcam core integration

Rust owns schema 1 `project.json`; `src/model.rs` is the authoritative type and
setting definition. Swift `YapcamCore.Project` serializes calls and owns the C
handle. `snapshot()` copies capture/event state and disables autosave writes for
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
  motion_blur, crop [x,y,w,h], background.{kind,color,color2,angle_deg,asset,blur}.
  Background kinds: solid, gradient, image, blurred_screen. Colors are sRGB [0,1].
- `cursor`: visible, size (0.1…10), smoothing (0…1; zero gives raw interpolation),
  hide_when_idle, idle_timeout_ns, click_effect (none/ring/highlight),
  click_duration_ns, speed_preset, spring, loop_to_start, loop_duration_ns,
  ranges [{tl_start_ns,tl_end_ns,visible}]. Latest active range wins.
- `camera`: visible, position [x,y], size (fraction of canvas width), shape
  (rounded_rect/circle/squircle), radius, mirrored, opacity, layouts
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

Media fingerprints are `fnv1a64:` plus the hex FNV-1a hash of the first MiB and the
full file size. These detect changes, not authenticity. All media references must
stay within the package, including through symlinks; cursor PNGs are included.

Time mapping retains rational fractional nanoseconds and rounds at the integer API
boundary. Extreme denominator combinations use Q32 fractional nanoseconds instead
of rounding each clip. The screen, camera, system/mic audio and event clock share
one clip list. Per-track file time subtracts track_start_ns; before the first sample,
the track is absent. At durationNs, evaluation returns the last source nanosecond;
negative times and times after the duration fail. Empty timelines have no frame.

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
  cancellation; returns file-local intervals. Map them through audio_ranges before
  passing edited timeline intervals to `processSilence`.
- Compressed audio codec services can be unavailable under restricted macOS
  execution; this returns explicit CoreError.status(6), never a guessed silence list.
- Masks/highlights, intro/outro transforms, camera shadow and cursor motion blur
  require a Lead-owned fixed frame ABI extension. Unknown settings/commands fail
  explicitly until that contract is available; these effects are not claimed done.
