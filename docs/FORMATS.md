# Data contracts

Owned by Lead. Capture writes `session.json` + `events.jsonl`; the Rust core reads
them and owns `project.json`. Change a contract only with a Lead commit that updates
this file, the fixtures in `Tests/Fixtures/synthetic/`, and both sides.

All times are signed 64-bit **nanoseconds**. All capture coordinates are **points**
relative to the top-left of the captured content (display, window or area), y down.
`scale` converts points to the pixel size of the screen track.

## recording/session.json (written by YapcamCapture)

```json
{
  "schema_version": 1,
  "app_version": "0.1.0",
  "created_at": "2026-10-14T21:00:00Z",
  "status": "complete",                        // "recording" | "complete" | "interrupted"
  "source": {
    "kind": "display",                         // "display" | "window" | "area"
    "display_id": 2,
    "display_name": "SyncMaster",
    "content_rect_points": [0, 0, 1680, 1050], // global display coords of captured content
    "scale": 1.0,
    "window_title": null,
    "app_bundle_id": null
  },
  "tracks": {
    "screen": { "pixel_size": [1680, 1050], "max_fps": 60, "codec": "hevc", "cursor_in_video": false },
    "camera": null,                             // { "device_name", "pixel_size", "fps", "mirrored" }
    "mic": null,                                // { "device_name", "sample_rate", "channels" }
    "system_audio": { "sample_rate": 48000, "channels": 2 }
  },
  "segments": [
    {
      "index": 0,
      "dir": "seg-000",
      "src_start_ns": 0,
      "duration_ns": 5048333333,
      "host_start_ns": 912345678901234,
      "files": { "screen": "seg-000/screen.mov", "system_audio": "seg-000/system.m4a",
                 "events": "seg-000/events.jsonl", "cursors": "seg-000/cursors.json" },
      "track_start_ns": { "screen": 0, "system_audio": 1200000 }  // first sample relative to segment start
    }
  ]
}
```

A segment is one uninterrupted stretch between start/resume and pause/stop.
`src_start_ns` of segment n+1 = `src_start_ns + duration_ns` of segment n (pauses removed).


> F9 decision (2026-10-15): `source.display_name` is written by capture for every source kind, and readers treat it as optional (fallback: display id / window title). Descriptive fields never block opening a recording.

## seg-XXX/events.jsonl (written by YapcamCapture)

One JSON object per line, `t` = ns relative to the segment start, monotonic:

```
{"t":0,"type":"move","x":812.5,"y":400.0}
{"t":16000000,"type":"down","button":"left","x":812.5,"y":400.0}
{"t":95000000,"type":"up","button":"left","x":812.5,"y":400.0}
{"t":120000000,"type":"scroll","dx":0,"dy":-12}
{"t":130000000,"type":"cursor","id":3}
{"t":200000000,"type":"key","key":"k","modifiers":["cmd"]}
{"t":210000000,"type":"focus","app_bundle_id":"com.apple.Safari","window_rect":[0,25,1680,1025]}
```

`key` events are only recorded when the user enables keystroke display.
Coordinates outside the captured content are kept (cursor may leave the area).

## seg-XXX/cursors.json

`{"3": {"file": "cursors/3.png", "hotspot": [4, 4], "size_points": [17, 23]}}` —
PNG at 2× (or native) resolution, written once per distinct system cursor.

## project.json (owned by yapcam-core)

Versioned with `schema_version`; older versions are migrated on open, newer
versions are refused with a clear error. Authoritative definition: the Rust types in
`core/src/model.rs` (serde). Top level:

```
{ schema_version, id, created_at, modified_at,
  recording: "recording/session.json",
  media: [{ path, size, head_hash }],
  timeline: { clips: [{ id, src_start_ns, src_end_ns, speed }] },
  zooms:   [{ id, tl_start_ns, tl_end_ns, mode: "auto"|"manual", target, scale, ease_in_ns, ease_out_ns }],
  cursor:  { visible, size, smoothing, hide_when_idle, click_effect, ... },
  camera:  { visible, layout segments, position, size, shape, radius, ... },
  canvas:  { aspect, output_size, background, padding, radius, shadow, inset, ... },
  audio:   { mic_gain_db, system_gain_db, ... },
  export:  { last_preset } }
```

## Edit commands (`yc_apply`)

JSON objects with an `op` field, e.g. `{"op":"split","at_tl_ns":…}`,
`{"op":"delete_range","tl_start_ns":…,"tl_end_ns":…}`, `{"op":"set_speed",…}`,
`{"op":"add_zoom",…}`, `{"op":"update_zoom","id":…,"patch":{…}}`,
`{"op":"set","path":"canvas.padding","value":48}`. Each successful command is one
undo step; `{"op":"batch","commands":[…]}` groups several (e.g. a drag gesture).
The full list lives in `core/src/commands.rs` and is mirrored in `Sources/YapcamCore`.

## Documented `set` paths (schema 1)

`set` accepts only the following paths. All numbers must be finite. Colors are
four sRGB RGBA components in [0,1]; lengths are output canvas pixels unless noted.
Arrays are replaced as a whole; indexing into arrays with a path is unsupported.
Nested objects (`canvas.background`, `canvas.shadow`, `canvas.animation`,
`cursor.spring`, `zoom_settings.spring`) can be replaced, with omitted fields
filled from defaults. Unknown paths/keys or invalid values fail transactionally.
Root setting objects are applied through `apply_preset`, not `set`.

| Path | Type / allowed values | Default |
|---|---|---|
| `canvas.aspect` | `source`, `custom`, or positive W:H string | `16:9` |
| `canvas.output_size` | [width,height], integers 1…16384; height sets output height, width used for custom aspect | [1920,1080] |
| `canvas.padding` | 0…16384; evaluation clamps to keep content visible | 48 |
| `canvas.radius` | 0…16384 | 18 |
| `canvas.shadow.radius` | 0…16384 | 24 |
| `canvas.shadow.opacity` | 0…1 | 0.3 |
| `canvas.shadow.offset_y` | −32768…32768 | 8 |
| `canvas.inset` | 0…8192 | 0 |
| `canvas.inset_color` | RGBA | [1,1,1,1] |
| `canvas.motion_blur` | 0…1, zoom/pan movement strength | 0 |
| `canvas.crop` | normalized source [x,y,w,h], positive size contained in [0,1]² | [0,0,1,1] |
| `canvas.background.kind` | solid / gradient / image / blurred_screen | solid |
| `canvas.background.color` | RGBA | [0.12,0.14,0.18,1] |
| `canvas.background.color2` | RGBA | [0.24,0.29,0.38,1] |
| `canvas.background.angle_deg` | finite degrees | 45 |
| `canvas.background.asset` | UInt32 index into project.media; must exist when kind=image | 0 |
| `canvas.background.blur` | 0…16384 | 24 |
| `canvas.background.noise` | 0…1 | 0 |
| `canvas.window_chrome` | boolean | false |
| `canvas.highlights` | highlight records below | [] |
| `canvas.animation.entrance` | none / fade / zoom / slide_left / slide_right / slide_up / slide_down | none |
| `canvas.animation.exit` | none / fade / zoom / slide_left / slide_right / slide_up / slide_down | none |
| `canvas.animation.entrance_duration_ns` | positive Int64 ns | 400000000 |
| `canvas.animation.exit_duration_ns` | positive Int64 ns | 400000000 |
| `cursor.visible` | boolean | true |
| `cursor.size` | 0.1…10, multiplier | 1 |
| `cursor.smoothing` | 0…1; zero preserves raw interpolated positions | 0.15 |
| `cursor.hide_when_idle` | boolean | false |
| `cursor.idle_timeout_ns` | nonnegative Int64 ns | 2000000000 |
| `cursor.click_effect` | none / ring / highlight | ring |
| `cursor.click_duration_ns` | positive Int64 ns | 400000000 |
| `cursor.speed_preset` | custom / slow / mellow / quick / rapid | custom |
| `cursor.spring.tension` | 1…2000 | 250 |
| `cursor.spring.friction` | 1…200 | 28 |
| `cursor.spring.mass` | 0.1…10 | 1 |
| `cursor.spring.allow_overshoot` | boolean | false |
| `cursor.ranges` | cursor visibility records below | [] |
| `cursor.loop_to_start` | boolean | false |
| `cursor.loop_duration_ns` | positive Int64 ns | 400000000 |
| `cursor.style` | recorded / pointer / touch / arrow | recorded |
| `cursor.motion_blur` | 0…1 | 0 |
| `cursor.spotlight_radius` | 0…16384; zero disables | 0 |
| `camera.visible` | boolean | true |
| `camera.position` | normalized [x,y], each 0…1 | [0.82,0.78] |
| `camera.size` | 0.01…1, fraction of canvas width | 0.22 |
| `camera.shape` | rounded_rect / circle / squircle | rounded_rect |
| `camera.radius` | 0…16384 | 24 |
| `camera.mirrored` | boolean | true |
| `camera.opacity` | 0…1 | 1 |
| `camera.layouts` | layout records below | [] |
| `camera.shadow_radius` | 0…16384 | 0 |
| `camera.background_removal` | boolean; renderer performs Vision processing | false |
| `camera.face_framing` | boolean; renderer performs face detection | false |
| `audio.mic_gain_db` | −96…24 dB | 0 |
| `audio.system_gain_db` | −96…24 dB | 0 |
| `audio.mic_muted` | boolean | false |
| `audio.system_muted` | boolean | false |
| `audio.ranges` | gain automation records below | [] |
| `zoom_settings.automatic` | boolean; disables existing auto zoom evaluation too | true |
| `zoom_settings.follow_cursor` | boolean, follow during auto zoom | true |
| `zoom_settings.dead_zone` | 0…0.45, inset fraction of zoom crop | 0.15 |
| `zoom_settings.speed_preset` | custom / slow / mellow / quick / rapid | custom |
| `zoom_settings.spring.tension` | 1…2000 | 250 |
| `zoom_settings.spring.friction` | 1…200 | 28 |
| `zoom_settings.spring.mass` | 0.1…10 | 1 |
| `zoom_settings.spring.allow_overshoot` | boolean | false |
| `export.last_preset` | string | mp4-1080p |
| `notes` | speaker notes string | empty |
| `autosave` | boolean, journal edits before publishing in memory | true |

REC-21 speaker notes are arbitrary UTF-8 text (including newlines), stored in
`project.json.notes`. Older schema-1 projects without the field default to `""`.
`{"op":"set","path":"notes","value":"Opening line\nNext point"}` is undoable,
journaled and saved; non-string values fail atomically. Setting the same text is
a no-op. Read notes with `{"q":"project"}`; notes are excluded from presets and
frame/render evaluation. UI can edit them without changing recording clocks.

Timeline records use half-open `[tl_start_ns,tl_end_ns)` intervals with nonnegative
start and strictly greater end. Cuts and speed changes retime all these records
along with zooms; collapsed intervals are removed. Latest-start active camera
layout/cursor visibility/gain range wins. Highlights draw in array order.

- Cursor range: `{tl_start_ns, tl_end_ns, visible}`. An active range overrides
  cursor.visible; idle and embedded-cursor checks still apply.
- Camera layout: `{id, tl_start_ns, tl_end_ns, mode, camera_position?, camera_size?}`.
  IDs unique; modes screen/camera/overlay/side_by_side. Position/size use the same
  limits as camera settings. Camera-only falls back to screen without a camera track.
- Audio range: `{id, track, tl_start_ns, tl_end_ns, start_gain_db, end_gain_db}`.
  IDs unique; track mic/system_audio; gains −96…24 dB. Linear dB interpolation adds
  to global track gain, with mute applied separately.
- Highlight: `{id, tl_start_ns, tl_end_ns, rect?, space?, radius?, opacity?,
  dim_opacity?, fill?, stroke?, stroke_width?}`. IDs nonempty and unique;
  `canvas-fade` is reserved. Rect defaults [0.25,0.25,0.5,0.5], normalized with
  positive size inside [0,1]². Space defaults source (follows zoom/crop), or canvas.
  Source rect clips to visible source; hidden source produces no instruction.
  Radius defaults 12, stroke_width 3 (both 0…16384 px); opacity defaults 1,
  dim_opacity 0.4 (both 0…1); fill [1,0.85,0.2,0], stroke [1,0.85,0.2,1].
  Opaque fill masks the region; transparent fill plus outside dim creates a
  spotlight. At most 32 intervals may overlap; more fail before applying an edit,
  without truncation. Arbitrarily many non-overlapping intervals are supported.

Fades draw black over the complete composition after all highlights, using a
stateless quintic ease. Durations clamp to project length; overlapping entrance
and exit fades use the darker result. No frames/time or audio edits are added.
Zoom/slide transforms are specified in the additive contracts below. Presets omit project-specific
highlights, cursor ranges, camera layouts and audio ranges.

## Read-only queries (`yc_query`)

Queries are cold paths returning allocated UTF-8 JSON, freed with yc_string_free.

| q | Result |
|---|---|
| clips | clip array with exact rounded tl_start_ns/tl_end_ns |
| zooms / layouts | persisted zoom / camera layout arrays |
| duration | `{duration_ns}` |
| clicks (cursor_clicks alias) | sorted mouse-down event array with edited tl_ns; example below |
| events | all retained input events with the same source/timeline mapping |
| audio_ranges | file intervals split at clip, segment, track-start and gain-range boundaries; track/path/segment/clip_id, source/file/timeline start/end ns, speed, gain/gain_start/gain_end, base_gain_db and muted |
| audio_automation | persisted audio.ranges |
| media (assets alias) | `{path,size,head_hash}` array |
| session / project | complete session or current project object |
| preset | portable setting objects only, without project-specific timeline ranges |
| render_options | cursor_style, cursor_motion_blur, cursor_spotlight_radius, background_noise, window_chrome, camera_background_removal, camera_face_framing, camera_shadow_radius |
| layers_at, with integer tl_ns | ordered highlight drawing records in canvas pixels, plus final canvas-fade when nonzero |

`{"q":"clicks"}` returns records such as:

```json
[{"t":500000000,"type":"down","button":"left","x":100,"y":100,
  "segment":1,"src_ns":3500000000,"tl_ns":2500000000}]
```

`t` stays segment-local capture ns, `src_ns = segment.src_start_ns + t`, and `tl_ns`
is the edited timeline position using the same rational clock as frames/audio.
Cuts omit removed events; speeds retime them; a split-boundary click occurs once.
Repeated source clips can repeat events at distinct timeline positions. The array
sorts by tl_ns, retains event metadata, and is empty for imports without events.
Editor snapping uses tl_ns and refreshes its cached list after timeline mutations.
Audio endpoint gains are linear amplitudes derived from dB ramps; renderers should
interpolate in dB between gain_start/gain_end rather than hold legacy gain constant.

## C ABI version 2: frame extras

YC_ABI_VERSION and yc_abi_version() are now 3 (motion extension below). Schema
version remains 1; these ABI-v2 extras retain their layout. All existing
YcFrame fields and signatures retain their v1 layout (328 bytes on arm64 macOS).
`yc_frame_extras_at(project, tl_ns, &extras)` fills the separate YcFrameExtras
defined in core/include/yapcam_core.h. Successful evaluation allocates nothing,
reads no files, and does not mutate state. Time validation matches yc_frame_at:
empty timelines, negative times or after-duration times fail; duration itself
evaluates the last source sample. Errors leave the output unchanged.

YcFrameHighlight is 80 bytes: YcRect canvas rect, float corner_radius/opacity/
dim_opacity, float[4] fill/stroke (sRGB), float stroke_width. YcFrameExtras is 2600
bytes with 8-byte alignment: Int64 tl_ns; UInt32 cursor_style (0 recorded, 1 pointer,
2 touch, 3 arrow); float cursor_motion_blur/cursor_spotlight_radius/background_noise; UInt8
window_chrome/camera_background_removal/camera_face_framing/reserved; float
camera_shadow_radius/fade_opacity; UInt32 highlight_count; 32 YcFrameHighlight
slots. Reserved and unused slots are zero. Highlight_count is the valid array
prefix; draw it in order, then a full-canvas black overlay with fade_opacity.
No pixels or file data cross this boundary. Query layers_at remains available for
UI identities and cold adapters; its geometry/fade math shares the extras evaluator.

Each frame/extras call holds a read lock independently. Use an immutable export
snapshot (or serialize editor mutations) when two calls must use the same edit state.
Renderer integrations must opt into the extras hook; an existing v1 renderer keeps
working with the unchanged YcFrame, but cannot display extras until wired.

## Media change detection and recovery

Approved head_hash format: `fnv1a64:` followed by 16 lowercase hexadecimal digits
of FNV-1a64 over up to the first MiB, together with the full file size. It detects
changed media, not authenticity. References are package-relative and cannot escape
through symlinks. Missing or changed media returns YC_ERR_MISSING_MEDIA with a
JSON array of relative paths in the error message; relink refreshes selected files.
Autosave journals validated complete state before in-memory edits; open restores a
same-project journal, save commits primary/.prev then removes the journal. Export
snapshots never journal over the editor.


## Backlog contracts: additive schema-1 effects

These fields default when absent. Arrays are replaced as a whole by `set`; array
indices are not set paths. Edits use the existing transactional batch/undo/journal
mechanism. Persisted ranges are half-open and retime with cuts/speeds; collapsed
ranges disappear. IDs must be nonempty and unique within their collection; IDs
starting `core:` and `canvas-fade` are reserved. No change to C ABI v2 sizes.
Implementation/checkpoint progress is in docs/status/core.md.

| New set path | Value / default |
|---|---|
| `canvas.annotations` | text/annotation records, [] |
| `canvas.reactions` | text records (emoji/reaction glyphs), [] |
| `canvas.captions` | caption text records, [] |
| `cursor.key_overlay` | complete key overlay settings object, defaults below |
| `cursor.key_overlay.enabled` | bool, false |
| `cursor.key_overlay.duration_ns` | positive Int64 ns, 1000000000 |
| `cursor.key_overlay.shortcuts_only` | bool, true (cmd/ctrl/alt combinations) |
| `cursor.key_overlay.rect` | normalized canvas [x,y,w,h], [0.3,0.82,0.4,0.12] |
| `cursor.key_overlay.style` | complete text style, defaults below |
| `cursor.key_overlay.style.font_size` | 1…1024 canvas px, 36 |
| `cursor.key_overlay.style.color` | sRGB RGBA, [1,1,1,1] |
| `cursor.key_overlay.style.background` | sRGB RGBA, [0,0,0,0.65] |
| `cursor.key_overlay.style.radius` | 0…16384 canvas px, 12 |
| `cursor.key_overlay.style.opacity` | 0…1, 1 |
| `audio.click_sound` | complete click sound settings object |
| `audio.click_sound.enabled` | bool, false |
| `audio.click_sound.variant` | soft/crisp, soft (original procedural sounds) |
| `audio.click_sound.gain_db` | −96…24 dB, −12 |
| `audio.music` | music track records, [] |

Text records: `{id,tl_start_ns,tl_end_ns,text,rect?,space?,style?}`. UTF-8 text is
nonempty; rect defaults [0.1,0.75,0.8,0.15], must fit [0,1]² with positive size.
Space is canvas (default) or source. Source records clip/map through current zoom
and crop; canvas records use output pixels. Style is `{font_size,color,background,
radius,opacity}`, with defaults/limits shown above. Caption/reaction records use
the same format; glyph/text content is caller-provided, no external asset library.
A style background becomes a separate highlight preceding the text. `layers_at`
orders highlights, annotations, reactions, captions, key overlay, final fade.
Every returned layer retains the existing numeric highlight fields (zero for text)
and adds optional `text`, `font_size`, `color`; text layers have `kind:"text"`.
Text layer IDs are `core:annotation/reaction/caption:<record-id>` to avoid
collisions across collections; their style background appends `:background`.

Commands (all undoable): `add_annotation`, `add_reaction`, `add_caption`, `add_music`
carry `record:{...}`; optional omitted/empty id is generated and returned in
createdIDs. `update_annotation/reaction/caption/music` use `{id,patch:{...}}`;
patch cannot change id and unknown fields fail. `remove_annotation/reaction/caption/music`
use `{id}`. Generic set supports replacing their collections.

`import_transcript` accepts `{op:"import_transcript", transcript:{schema_version:1,
engine,locale,words:[{text,src_start_ns,src_end_ns,confidence?,segment_index?,track?}]},
style?:{...},replace?:true}`. This is Capture's `RecordingTranscript` JSON (read
recording/transcript.json in Swift, pass its JSON object). No Speech dependency in
Core. Each word intersects each retained clip, using exact source boundary mapping;
cut words disappear, cut-spanning words split, repeated clips repeat words, speeds
retime them. Each output word is a caption segment with timeline range, text and
style. Default replace=true replaces captions in one undo step; false appends.
Invalid schema, timestamps, blank words or style fail the entire command. Zero
rounded-duration intersections are omitted. Source timestamps exclude pauses and
include Capture's per-track offsets; Core must not apply those offsets again.

Music record: `{id,tl_start_ns,tl_end_ns,source?,path?,file_start_ns?,file_duration_ns?,
gain_db?,loop?,fade_in_ns?,fade_out_ns?,ducking?}`. Source file (default), calm or
bright; calm/bright are Render's original 8-second procedural loops. File path is
package-relative and must already appear in media (`add_media` can precede it in a
batch). File duration is required positive for source=file, 8s for built-ins.
File start >=0 and < duration; gain −96…24 dB (default −18), loop=true, fades
nonnegative ns (default 500ms each). Non-loop tracks stop when the file runs out.
Ducking: `{enabled:false,gain_db:-12,attack_ns:50000000,release_ns:200000000,
ranges:[]}`; ranges are `{tl_start_ns,tl_end_ns}`. When enabled, empty ranges use
caption ranges as speech activity; no captions means no inferred speech. Explicit
ranges override that inference. Duck attenuation ramps linearly in dB after speech
start and after speech end, with strongest active attenuation winning. A speech
range shorter than attack releases from its attained attenuation. Music fades
are linear amplitude; overlap multiplies the two fades. Cuts/speeds remap music
ranges and explicit duck ranges; external music has its own output-timeline clock,
independent of recording playback speed.

New queries:

| q | Result |
|---|---|
| annotations / reactions / captions / music | persisted record array |
| key_events | edited, sorted `type:"key"` events with src_ns/tl_ns and metadata |
| audio_overlays | music and enabled click instructions described below |
| effects_at, integer tl_ns | `{layers,render_options,audio}` from one immutable state; validates time as frame_at |
| render_options_at, integer tl_ns | render_options with active camera layout overrides |

`audio_overlays` rows: `{id,source,path,tl_start_ns,tl_end_ns,file_start_ns,
file_duration_ns,loop,gain,gain_start,gain_end,fade_in_ns,fade_out_ns}`. Music splits
at duck envelope boundaries; start/end gains are amplitudes for a linear-dB ramp,
excluding fades (apply fades relative to `envelope_start_ns/envelope_end_ns`, the
original music range). `source` is file/calm/bright/soft/crisp; clicks use mapped
mouse-down times, clamp duration to project end (soft 80ms, crisp 50ms), no loops.
`effects_at.audio` gives active rows with an additional `gain_at` including duck
and fade; no decoding or IO. Consumers preserve `file_start_ns` and advance it by
elapsed timeline time, wrapping modulo file_duration_ns when loop=true. These
allocated JSON queries complement, and do not grow, YcFrameExtras.

Key overlay derives the latest eligible retained key event within duration_ns;
cmd/ctrl/alt/shift become ⌘/⌃/⌥/⇧ followed by key text. It is opt-in, defaults to
shortcuts only, and never displays events removed by cuts. Array layer ID is
`core:key-overlay`; synthetic style background IDs start `core:`.

EDT-14 uses existing `canvas.animation.entrance/exit` set paths with additional
modes `zoom`, `slide_left`, `slide_right`, `slide_up`, `slide_down`. Existing
positive duration paths remain unchanged. A quintic ease scales zoom from/to 0.85
about canvas center, or slides screen/camera/cursor from/to one canvas width/height.
Transforms affect source-space layers; canvas-space overlays remain fixed. Zoom
and slides transform the primary content, retain background, and add no media/time.
Fade remains the final full-composition black layer. Frame destinations/cursor
geometry contain evaluated transforms, so no second renderer-side tween is needed.

CAM-04/05: existing root `camera.background_removal/face_framing` remain defaults.
Layout records append optional `camera_background_removal`, `camera_face_framing`,
`camera_shadow_radius` (0…16384). Latest-start active layout overrides these fields;
null/omitted inherits root. FrameExtras' existing camera fields now evaluate those
per-layout options; render_options_at/effects_at agrees. Vision processing remains
Renderer-owned. Use a snapshot/matched time for frame/extras/config/layers.

Existing `map_audio_ranges` query accepts `{q:"map_audio_ranges",track:"mic"|
"system_audio",path:"recording/seg-NNN/file",ranges:[{file_start_ns,file_end_ns}]}`
and returns sorted merged `{tl_start_ns,tl_end_ns}` intervals. It maps every retained
file occurrence through clips, track offsets and speeds without IO or mutation.
Presets omit annotations, reactions, captions, music and duck activity ranges,
as well as existing project-specific collections.

## Guide audit: cursor, screen motion and camera zoom (Core contracts)

Additive schema-1 fields default to prior behavior. `set` accepts each listed path,
including whole `canvas.motion_blur_settings` objects. All edits are undoable,
journaled, validated and included in portable presets. Arrays and recorded events
are unchanged. No invented reference option values: defaults/thresholds below are
Yapcam choices; implementation/checkpoint progress is in Core status.

| New set path | Type / limits / default |
|---|---|
| `cursor.always_default` | bool, false; force pointer style and cursor_id=0 |
| `cursor.rotate_on_move` | bool, false; evaluated tilt up to ±15° |
| `cursor.stop_before_end_ns` | nonnegative Int64 ns, 0 (off) |
| `cursor.remove_shakes` | bool, false; suppress displacements under 1 captured point |
| `cursor.optimize_types` | bool, false; debounce recorded cursor type changes by 80ms |
| `zoom_settings.animation_style` | custom / focused / smooth, custom |
| `camera.zoom_scale` | 0.25…4, 1; overlay size multiplier at full zoom |
| `canvas.motion_blur_settings` | object `{zoom:null,pan:null}` |
| `canvas.motion_blur_settings.zoom` | null inherits canvas.motion_blur, or 0…1 |
| `canvas.motion_blur_settings.pan` | null inherits canvas.motion_blur, or 0…1 |

CUR-12 `always_default` wins over recorded/touch style and suppresses recorded
cursor IDs. CUR-13 tilt uses evaluated horizontal canvas displacement over the
previous 16,666,667 timeline ns, clamped at ±15° for ±600 canvas pixels/second.
Invisible or stopped cursors have zero tilt; backward seeks are stateless.

CUR-14 holds the cursor's canvas hotspot from `max(0,duration-stop_before_end_ns)`
through the endpoint. Visibility and click effects still evaluate at the current
time. Zero disables; a duration longer than the video holds its initial hotspot.
Loop-to-start runs before the hold point is sampled; stopping wins during the tail.
Cuts/speeds recompute the hold time from the edited duration; no event/media edits.

CUR-15 uses a cold-built positional index: each captured coordinate within 1 point
of the last accepted coordinate keeps that anchor; larger displacements advance
it. Original timestamps/interpolation are retained so removing jitters does not
introduce motion before the next captured sample interval. The same filtered
positions feed cursor smoothing, loop-to-start and automatic follow-pan. Events
and click positions remain original; no changes to snapping or recorded data.
CUR-16 retains a cursor type until a replacement survives 80ms in source time;
shorter flickers are removed. The initial type is accepted immediately. The indexes
are built when event data loads and reused; toggles need no IO or frame allocation.

ANI-02 custom retains the existing speed_preset/custom spring. Focused selects
(tension=500,friction=45,mass=1,allow_overshoot=false); smooth selects
(160,22,1,false). Both zoom transitions and follow-pan use that effective spring.
Follow-pan eases analytically over the previous 100ms timeline window so seek and
export use identical motion without mutable simulation state. Mode changes do
not rewrite existing explicit springs or zoom ease durations. Per-kind blur gates
zoom strength on crop/destination-scale changes, pan strength on crop/destination-center changes, and the
existing cursor.motion_blur strength on cursor movement. Legacy frame.motion_blur
is the maximum active zoom/pan strength; static plateaus are sharp.

CAM-07 camera.zoom_scale blends from 1 to the configured factor with the actual
zoom crop progress, including crop and instant zoom. It applies to overlay camera
layouts; full-camera and side-by-side layouts retain their explicit fitted areas.
Overlay position remains the configured center with robust canvas clamping.

New query `{"q":"motion_at","tl_ns":<integer>}` returns
`{tl_ns,cursor_rotation_rad,cursor_motion_blur,zoom_motion_blur,pan_motion_blur}`.
Time validation matches frame_at; negative, empty or after-duration clocks fail.
Motion across a clip boundary is suppressed so cuts cannot create a velocity trail.
`render_options_at` and `effects_at.render_options` append cursor_rotation_rad,
zoom_motion_blur, pan_motion_blur and evaluated cursor_motion_blur. Parameterless
render_options supplies zero rotation and configured strengths for old consumers.
`music_library` returns original procedural source descriptors:
`[{id:"calm",name:"Calm",duration_ns:8000000000},
{id:"bright",name:"Bright",duration_ns:8000000000}]`; audio.music.source accepts
these IDs. No external/reference samples are bundled or read.

ABI v3 appends `YcFrameMotion` and `yc_frame_motion_at`; YcFrame remains 328 bytes
and YcFrameExtras remains 2600 bytes. YcFrameMotion is 24 bytes/alignment 8:
int64 tl_ns + four float fields cursor_rotation_rad, cursor_motion_blur,
zoom_motion_blur, pan_motion_blur. Successful evaluation allocates nothing, reads
no files and mutates nothing. Errors leave output unchanged. Every entry point
has the same top-level unwind containment guarantee; snapshots match frame,
extras and motion at a time. ABI_VERSION becomes 3; all old signatures/layouts
remain valid. Renderer must opt into tilt/per-kind motion evaluation; no pixels
cross C. Swift adds Project.frameMotion(atNs:) and typed motion(atNs:).

## AUD-06 offline microphone enhancement

Schema 1/ABI 3 stay unchanged. New settings default off and use the existing
transactional set/batch/undo/journal/preset mechanism. Every new set path:

| Path | Type / limits / default |
|---|---|
| `audio.speech_enhancement` | bool, false |
| `audio.speech_enhancement_settings` | whole settings object, defaults below |
| `audio.speech_enhancement_settings.high_pass_hz` | 20…300 Hz, 90 |
| `audio.speech_enhancement_settings.noise_threshold_db` | −70…−15 dB, −45 |
| `audio.speech_enhancement_settings.noise_reduction_db` | 0…60 dB, 30 |
| `audio.speech_enhancement_settings.compressor_threshold_db` | −60…0 dB, −24 |
| `audio.speech_enhancement_settings.compressor_ratio` | 1…10, 3 |
| `audio.speech_enhancement_settings.target_lufs` | −36…−10 LUFS, −16 |
| `audio.speech_enhancement_settings.peak_ceiling_dbfs` | −12…0 dBFS, −1 |
| `audio.speech_enhancement_settings.normalize_loudness` | bool, true |

Limits/defaults match Render's SpeechEnhancementSettings. This opts into Render's
original offline DSP (high-pass, quiet-region expansion, compression, gated
normalization and sample-peak limiting); no speech-isolation/model claim. It
changes the decoded microphone signal, not source/file/timeline clocks or gains.
System audio and music remain separate. Toggle/settings alone never decode audio,
rewrite recording files or perform file IO on frame paths.

New cold query `{"q":"speech_enhancement"}` returns
`{enabled,settings,media:[{path,media_index}]}`. Media paths are package-relative
registered microphone files that intersect retained clips after track_start_ns;
each file appears once, sorted by path. Cuts/repeats/speeds do not cause duplicate
processing. Muted retained microphones still appear so a prepared result remains
usable after unmute. Disabled and no-retained-mic states are represented explicitly;
no eligible media means an empty media array. Query allocates metadata only.

Swift `Project.prepareSpeechEnhancement(using:)` snapshots settings and source
metadata, returns [] without calling a processor when disabled/no mic, and calls
an injected async processor once per eligible file. Core cannot import Render
(which depends on Core); Editor passes a closure that calls Render's real
SpeechEnhancer.processFile. Core verifies approved source size/head fingerprints
before/after processing, checks output is 48k Float32 mono/stereo PCM with original
channel count and file duration (within one 48k sample), and returns replacement
URLs under a unique package cache/speech/<run-id>/ directory. Source references,
file-local gaps, track offsets, timeline mapping and gain automation stay intact.
Original recordings are never replaced or registered as processed assets. Failed
or cancelled runs delete all their staged cache outputs; success keeps outputs for
the caller's render/export lifetime. No persistent cache reuse/stale-settings claim.
Call on an immutable export snapshot, or discard preview results when its edit
settings change. Renderer/Editor substitute URLs by original media path and keep
existing file_ns sampling unchanged. Input/codec unavailability is an explicit
error, never a successful unprocessed result.


## CUR-06 fixed arrow cursor contract

`cursor.style` additionally accepts `"arrow"`. Root `render_options` and timed
`render_options`/`effects_at` report `cursor_style: "arrow"`; frame extras reports
`cursor_style = 3`. Codes 0 recorded, 1 pointer and 2 touch retain their meanings.
`cursor.always_default = true` still overrides any stored style with pointer/code 1
and cursor_id 0. A fixed style selects the renderer texture; the frame cursor_id
otherwise continues to reflect captured events. Schema 1 and ABI 3 remain unchanged,
and YcFrame/YcFrameExtras retain every field, size and offset. The existing set path
uses normal undo/redo, preset and persistence behavior. Render adapters must accept
code 3 and map it to their original vector arrow before enabling this selection.


AUD-06 integration update: Render's native AudioTimeline now provides preparation
via optional `ExportSettings.speechEnhancement` and PreviewPlayer constructor/setter
settings. Editor maps the persisted enabled flag to settings-or-nil and supplies
the same frozen configuration to preview/export. This is an alternative to the
Core preparation callback for custom sources, with timeline-owned temporary files.
Do not process the same microphone through both paths. Project persistence and
source/time/gain contracts above are identical for either path.


## CUR-06 authored palette, shape and logical-size selection

Schema 1 / ABI 3 remain unchanged. Existing cursor.style values and extras codes
0 recorded / 1 pointer / 2 touch / 3 arrow retain their meanings. New set paths
use normal batch/history/journal/save/preset validation:

| Path | Type / default / accepted values |
|---|---|
| `cursor.set_id` | nullable string, null; classic, paper, soft-slate, soft-cloud, lagoon, coral, sage, violet, gold, precision-dark, precision-light, signal |
| `cursor.shape` | nullable string, null; arrow, pointing_hand, touch, text, resize_horizontal, resize_vertical, resize_diagonal_nwse, resize_diagonal_nesw, open_hand, closed_hand |
| `cursor.logical_size` | string, regular; small, regular, large, extra_large |

null palette/shape + regular size preserves the recorded/default rendering path.
A selected palette or explicit shape opts into Render's original generated artwork.
Shape is independent of the legacy cursor.style; explicit shape takes precedence
unless cursor.always_default is true, which forces effective shape arrow and legacy
style pointer/code 1. Selected palette and logical size remain effective. Legacy
Core pointer still means the system-arrow shape; pointing_hand is an explicit new
shape. Recorded cursor_id metadata remains unchanged except always_default's ID 0.

Root and timed render_options/effects_at append cursor_set_id, cursor_shape,
cursor_logical_size. Shape is effective (arrow when always_default); palette/size
reflect the project selection. No new field or code is added to YcFrame/Extras.
Renderer reads these cold options from the same immutable generation and maps them
to RenderConfiguration.cursorSetID/cursorStyle/cursorSize. Logical sizes scale own
artwork by 0.75/1/1.5/2 independently of raster density and existing cursor.size /
animated frame.cursor_scale; do not multiply that frame scale again in Core.
Recorded PNG dimensions/semantics stay unchanged.

New query `{"q":"cursor_library"}` returns
`{sets:[{id,name}],shapes:[string],logical_sizes:[{id,scale}]}` with the IDs above.
These descriptors mirror Render's 12 authored palettes, 10 shapes and 4 sizes; no
reference/system bitmap or palette data is copied. Renderer/Editor must connect
these fields and picker before claiming selections change preview/export pixels.


## Core behavior alignment (new-project revision 1)

CORE-1 is implemented. Additive CORE-2/3/5/6 contracts below are being implemented;
consult docs/status/core.md READY entries before depending on a new field/query.

Existing schema-1 projects keep their serialized geometry and physics. New fields
missing in an older file select the legacy mode; opening does not regenerate zooms
or discard settings. The C ABI remains unchanged. All additions below participate
in transactional set/batch, undo/redo, journals, snapshots and save/reopen.

Auto zoom regeneration uses retained mouse-down events on the edited timeline.
Each click contributes a window from 300ms before to 2500ms after it, with a 1ms
minimum start and an end no later than 800ms before the project ends. Clicks at or
after the final second are excluded. Windows separated by at most 2500ms merge,
regardless of cursor distance. Manual zooms retain priority. Missing pointer data
selects manual mode; key events alone do not generate zooms. Existing saved zooms
are retained until explicitly regenerated. Default level is 2.0 and cursor follow
is enabled for new projects.

| Additional set path | Type / meaning | New project / legacy decode |
|---|---|---|
| canvas.padding_ratio | null or 0...0.25 of the shorter canvas edge | 0.10 / null (use existing pixel padding) |
| canvas.shadow.style | classic or directional | directional / classic |
| canvas.shadow.distance | 0...100 output pixels | 25 / inactive for classic |
| canvas.shadow.angle_deg | 0...180 degrees | 45 / inactive for classic |
| canvas.shadow.blur | 0...30; directional blur maps to radius x8 | 20 / inactive for classic |
| cursor.size_points | null or 16...128 logical points (base cursor 16pt) | 48 / null (existing size multiplier) |
| cursor.physics_version | 0 legacy or 1 aligned spring rules | 1 / 0 |
| zoom_settings.physics_version | 0 legacy or 1 aligned spring rules | 1 / 0 |
| zoom_settings.default_scale | 1...4; used for omitted new zoom levels | 2 / 2 |
| zoom_settings.start_early | begin incoming transition 350ms before zoom range | false / false |
| typing.speed | 1.5...8; remembered speed for applying suggestions | 3 / 3 |
| typing.dismissed | array of stable captured-burst IDs | [] / [] |
| audio.music_volume | 0...1 linear gain for newly inserted music without an explicit gain | 0.05 / 0.05 (does not modify existing tracks) |
| audio.mic_preset | voice, noise_reduction or podcast; selecting applies owned DSP settings | voice / voice (existing stored DSP settings retained on load) |
| audio.stereo_mic | boolean microphone channel preference for consumers | false / false |

Setting legacy canvas.padding clears padding_ratio; setting cursor.size clears
size_points. Legacy shadow.radius/offset_y selects classic. Selecting a spring
preset or editing its custom parameters selects physics_version 1. Older stored
preset names use version 0 until that setting is edited. Aligned screen presets:
focused 250/40/2.25, smooth 170/50/3. Aligned cursor presets: smooth 470/70/3,
medium 340/60/3, rapid 530/40/1, none (raw). Legacy slow/mellow/quick remain accepted.
The three numbers are stiffness, damping and mass; custom ranges are 5...600,
5...200 and 0.1...15. When a transition is too short for settling, stiffness scales
quadratically and damping linearly with the compression ratio; less than two
capture-frame periods snaps. Existing version-0 transitions retain their curve.

New-project overrides also use radius 16, motion blur 1, a 125/12/1.5 screen
spring, a 48pt authored cursor from our classic palette, click sound gain 0.25,
and our own calm dark background. Cursor smoothing starts off because the
reference's new-recording spring selection is ambiguous; explicit presets enable
it. No wallpaper or cursor asset from the reference is imported.

Cold render_options / render_options_at append screen_shadow (style, offset_x,
offset_y, radius, opacity), padding_ratio and cursor_size_points. Frame scalar
padding, shadow radius/opacity/y offset and cursor_scale are already evaluated;
consumers use the extra x offset for directional shadows and must not rescale
cursor_scale a second time. speech_enhancement appends mic_preset and stereo_mic.

New query {q:"typing_suggestions"} returns records {id,src_start_ns,src_end_ns,
key_count,speed,ranges:[{tl_start_ns,tl_end_ns}]}. Bursts use adjacent key gaps
strictly below 500ms, span at least 1500ms and density at least two keys/second.
IDs derive from captured source boundaries and survive cuts/speeds; repeated
source occurrences share one ID and return all retained timeline intersections.
Dismissed IDs are omitted. Commands dismiss_typing_suggestion {id},
restore_typing_suggestions {}, and apply_typing_suggestion {id,speed?} modify one
history step; auto_speed_typing {speed?} applies all non-dismissed suggestions.
Selecting speed remembers typing.speed. Unsupported IDs/values fail atomically.
