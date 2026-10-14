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
| `canvas.animation.entrance` | none / fade | none |
| `canvas.animation.exit` | none / fade | none |
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
| `cursor.style` | recorded / pointer / touch | recorded |
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
Other animation modes are rejected until implemented. Presets omit project-specific
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

YC_ABI_VERSION and yc_abi_version() are 2. Schema version remains 1. All existing
YcFrame fields and signatures retain their v1 layout (328 bytes on arm64 macOS).
`yc_frame_extras_at(project, tl_ns, &extras)` fills the separate YcFrameExtras
defined in core/include/yapcam_core.h. Successful evaluation allocates nothing,
reads no files, and does not mutate state. Time validation matches yc_frame_at:
empty timelines, negative times or after-duration times fail; duration itself
evaluates the last source sample. Errors leave the output unchanged.

YcFrameHighlight is 80 bytes: YcRect canvas rect, float corner_radius/opacity/
dim_opacity, float[4] fill/stroke (sRGB), float stroke_width. YcFrameExtras is 2600
bytes with 8-byte alignment: Int64 tl_ns; UInt32 cursor_style (0 recorded, 1 pointer,
2 touch); float cursor_motion_blur/cursor_spotlight_radius/background_noise; UInt8
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
start and after speech end, with strongest active attenuation winning. Music fades
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
