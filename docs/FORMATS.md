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
{"t":220000000,"type":"marker","marker_id":"capture-generated-uuid"}
```

`key` events are only recorded when the user enables keystroke display.
Coordinates outside the captured content are kept (cursor may leave the area).

### Recording markers (CAP-3)

Capture writes marker events in the same segment-local clock as input, even when
keystroke recording is off. `{"q":"markers"}` returns timeline-ordered records:
`{id, marker_id, segment, segment_ns, src_ns, tl_ns, clip_id}`. `marker_id` is
capture identity; `id` identifies one retained occurrence (`marker:<segment>:<event
ordinal>:<clip_id>`). Every repeated clip gets its own occurrence. Missing/empty
legacy marker IDs get the stable fallback `marker:<segment>:<event ordinal>`.
Non-marker events never appear. Source intervals are half-open: cuts omit removed
markers, a split-boundary marker belongs only to the following clip, and the final
source endpoint is omitted. Speed and cut changes map through the same exact
rational clock as frames. Segment indices use the session's stored index.

Markers remain immutable recording events, require no project schema migration,
and are excluded from presets. Undo/redo and snapshots restore/query their
retained occurrences through the clip list; save/reopen does not rewrite input.
Swift `Project.markers()` returns `[TimelineMarker]`, with `markerID`, `clipID`,
`segment`, `segmentNs`, `srcNs` and `tlNs`. Editor owns timeline presentation.

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

`set` accepts the documented paths below and in the additive sections later in
this file. All numbers must be finite. Colors are
four sRGB RGBA components in [0,1]; lengths are output canvas pixels unless noted.
Arrays are replaced as a whole; indexing into arrays with a path is unsupported.
Nested objects (`canvas.background`, `canvas.shadow`, `canvas.animation`,
`cursor.spring`, `zoom_settings.spring`) can be replaced, with omitted fields
filled from defaults. Unknown paths/keys or invalid values fail transactionally.
Root setting objects are applied through `apply_preset`, not `set`.

The Default column in this inventory describes legacy missing-field decoding,
not the current `Project.create` factory preset. New-project overrides and the
old-to-new table are under [Factory defaults and compatibility](#factory-defaults-and-compatibility).
Setting a spring parameter opts into the aligned custom bounds described there;
loading a version-0 spring preserves its legacy bounds and response.

| Path | Type / allowed values | Legacy decode default |
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
| `cursor.speed_preset` | custom / slow / mellow / quick / rapid / smooth / medium / none | custom |
| `cursor.spring.tension` | 5…600 on edit; legacy version-0 decode 1…2000 | 250 |
| `cursor.spring.friction` | 5…200 on edit; legacy version-0 decode 1…200 | 28 |
| `cursor.spring.mass` | 0.1…15 on edit; legacy version-0 decode 0.1…10 | 1 |
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
| `zoom_settings.spring.tension` | 5…600 on edit; legacy version-0 decode 1…2000 | 250 |
| `zoom_settings.spring.friction` | 5…200 on edit; legacy version-0 decode 1…200 | 28 |
| `zoom_settings.spring.mass` | 0.1…15 on edit; legacy version-0 decode 0.1…10 | 1 |
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
- Highlight/mask: `{id, tl_start_ns, tl_end_ns, rect?, space?, kind?, blur_radius?, radius?, opacity?,
  dim_opacity?, fill?, stroke?, stroke_width?}`. IDs nonempty and unique;
  `canvas-fade` is reserved. Rect defaults [0.25,0.25,0.5,0.5], normalized with
  positive size inside [0,1]². Space defaults source (follows zoom/crop), or canvas.
  Source rect clips to visible source; hidden source produces no instruction.
  Radius defaults 12, stroke_width 3 (both 0…16384 px); opacity defaults 1,
  dim_opacity 0.4 (both 0…1); fill [1,0.85,0.2,0], stroke [1,0.85,0.2,1].
  Opaque fill masks the region; transparent fill plus outside dim creates a
  spotlight. At most 32 intervals may overlap; more fail before applying an edit,
  without truncation. Arbitrarily many non-overlapping intervals are supported.
  `kind` defaults `highlight` (unchanged spotlight/opaque-fill behavior), or `blur`.
  `blur_radius` defaults32, finite0…128 canonical canvas pixels, including0
  (identity Gaussian). It is independent of the rounded-corner `radius` and source
  zoom. Render scales it by output/canvas scale for both preview and export.
  Blur replaces the underlying composition inside the rounded rectangle with
  a Gaussian-filtered sample, blended by opacity; it does not apply highlight
  fill/stroke/outside dim. Opaque cover remains `kind:"highlight"` with opaque fill.
  Old records missing either new field keep their previous appearance.
  `insert_mask.patch` accepts both fields; replacing `canvas.highlights` edits
  existing masks. The remembered insertion style includes kind and blur_radius.

Fades draw black over the complete composition after all highlights, using a
stateless quintic ease. Durations clamp to project length; overlapping entrance
and exit fades use the darker result. No frames/time or audio edits are added.
Zoom/slide transforms are specified in the additive contracts below. Presets omit project-specific
highlights, cursor ranges, camera layouts and audio ranges.

### Portable preset boundary

`{"q":"preset"}` exports only style fields from canvas, cursor, camera, audio,
zoom_settings and export. `apply_preset` uses the same field filter and merges
provided style leaves into the destination. Omitted fields keep their current
values; it never replaces whole setting groups. Known style values still undergo
normal transactional validation and one-step undo/redo.

Presets omit and ignore project/recording metadata, timeline/clips and their
settings, zoom records, insertion history, notes, typing suggestions, media paths
and indices, source crop, highlights/annotations/reactions/captions, cursor/audio
ranges, camera layouts and music tracks (including duck activity ranges). Unknown
fields and these legacy fields are ignored on import, even if their IDs/ranges are
invalid in the destination. Style durations (animation, cursor idle/click/key
visibility) and palette `cursor.set_id` remain portable style settings.

Background image bytes travel only as the Swift file wrapper's `_background_image`
base64 payload. No source media index is exported/applied. Image import registers
fresh destination media and selects it in the same atomic batch; a raw
`background.kind:"image"` without embedded bytes does not select a destination
asset. Existing target effects, recording references, IDs and timeline times stay
unchanged when applying a preset from another project.

## Read-only queries (`yc_query`)

Queries are cold paths returning allocated UTF-8 JSON, freed with yc_string_free.

| q | Result |
|---|---|
| clips | clip array with exact rounded tl_start_ns/tl_end_ns |
| zooms / layouts | persisted zoom / camera layout arrays |
| duration | `{duration_ns}` |
| clicks (cursor_clicks alias) | sorted mouse-down event array with edited tl_ns; example below |
| events | all retained input events with the same source/timeline mapping |
| markers | retained marker occurrences mapped through cuts, speeds and repeated clips; see CAP-3 contract |
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

### Additive blur-mask extras companion (GAP-ED-16)

All existing C struct sizes/offsets and ABI3 stay unchanged. The additive Rust
export `yc_frame_mask_effects_at(project,tl_ns,&effects)` evaluates a separate
YcFrameMaskEffects: Int64 tl_ns; UInt32 highlight_count/reserved; 32 entries of
YcFrameMaskEffect {UInt32 kind; float blur_radius}. Kind0 means legacy highlight,
kind1 blur; radius is0 for kind0 and the mask's canvas-pixel radius for kind1.
Size272/alignment8, entries offset16, entry size8. The valid prefix corresponds
exactly to YcFrameExtras.highlights, including clipped/invisible filtering and
array order. Reserved/unused entries are zero; half-open ranges, time validation,
no allocation/IO and unchanged output on error match the existing extras call.
Lead owns appending the C declaration; Core's Rust export/cold query require no
changes to existing C structs. Use one immutable snapshot for separate calls.

`{"q":"mask_effects_at","tl_ns":N}` returns
`{tl_ns,highlight_count,effects:[{kind,blur_radius}]}` with only valid entries.
The Swift wrapper is `maskEffects(atNs:)`. `layers_at` and `effects_at.layers`
include blur rows with `kind:"blur"`, `blur_radius` plus the existing evaluated
rect/corner_radius/opacity and style fields. Existing highlight/text/fade rows
retain their meanings. Draw this complete list in order, with fade last;
do not draw the extras prefix a second time. Older C-only consumers see an
opaque black fill fallback (same opacity, no stroke/dim) for blur slots rather
than dropping sensitive masks. Real Gaussian rendering requires Render's new pass.

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
| `cursor.rotation_mode` | `static` / `tilt` / `follow`, revision2 factory `tilt` (legacy `static`); authoritative mode, synchronizes legacy `rotate_on_move` |
| `cursor.rotation_degrees` | finite degrees −180…180, default0; clockwise static rotation |
| `cursor.tilt_amount` | finite0…2, default1; multiplier on velocity tilt (maximum ±15° × amount) |
| `cursor.stop_before_end_ns` | nonnegative Int64 ns, 0 (off) |
| `cursor.remove_shakes` | bool, false; enable the positional deadband below |
| `cursor.shake_threshold` | finite100…2000 **millipoints** (one thousandth of a captured logical point), new-project default500 =0.5pt; used only when remove_shakes=true |
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
`rotation_mode=static` uses rotation_degrees at every visible frame, including time0,
cuts, idle and the stopped tail; tilt ignores that angle and scales the legacy
velocity response by tilt_amount. Legacy `set cursor.rotate_on_move` remains an
alias that sets rotation_mode to tilt/static; setting the mode updates that bool.
All four new paths are ordinary validated, undoable `set` leaves and portable style
settings. They survive save/reopen, snapshots, presets and recovery journals.
Schema1 and ABI3 are unchanged: rotation is emitted by existing `motion_at`,
`render_options_at`/`effects_at` and `yc_frame_motion_at.cursor_rotation_rad`;
position remains in YcFrame.cursor_x/y. Render already consumes these fields.

CUR-14 holds the cursor's canvas hotspot from `max(0,duration-stop_before_end_ns)`
through the endpoint. Visibility and click effects still evaluate at the current
time. Zero disables; a duration longer than the video holds its initial hotspot.
Loop-to-start runs before the hold point is sampled; stopping wins during the tail.
Cuts/speeds recompute the hold time from the edited duration; no event/media edits.

CUR-15 uses a cold-built positional index: each captured coordinate strictly below
shake_threshold/1000 logical points from the last accepted coordinate keeps that
anchor; distances at or above the threshold advance
it. Original timestamps/interpolation are retained so removing jitters does not
introduce motion before the next captured sample interval. The same filtered
positions feed cursor smoothing, loop-to-start and automatic follow-pan. Events
and click positions remain original; no changes to snapping or recorded data.
CUR-16 retains a cursor type until a replacement survives 80ms in source time;
shorter flickers are removed. The initial type is accepted immediately. The indexes
are built when event data loads and reused; toggles need no IO or frame allocation.
Shake-threshold changes build a new immutable index on the cold command path and
publish it with the edit; history and snapshots keep their matching index. Captured
held samples are compacted, retaining the last held sample before each movement
so interpolation and the last accepted move's idle clock match the dense trace.
Captured points precede source scaling, zoom and output rasterization, so this unit is
independent of Retina pixel density and output resolution. It is a displacement
deadband, not a velocity threshold. Raw events/click positions remain unchanged.

Migration: an existing project cursor object without rotation_mode derives it from
rotate_on_move (true→tilt, false/absent→static); explicitly supplied new mode wins.
An older cursor object without shake_threshold receives1000 to preserve the former
1pt deadband, including when filtering is initially off. Newly created projects use
500; projects without any cursor settings retain the off/default appearance.
Legacy preset cursor patches containing remove_shakes but no threshold similarly
use1000; a supplied threshold is retained. Legacy rotation-only preset patches set
the matching new mode. No recording/session/event files are rewritten on open.

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

### AUD-06 explicit enhanced microphone selection

Optional schema-1 `audio.mic_replacements` defaults to `[]`; existing projects
continue using their original microphone files. It contains
`{original:{path,size,head_hash},enhanced:{path,size,head_hash}}` records, at most
one per original mic file. Both identities use the registered-media FNV fingerprint
contract. The original must be a session microphone; the derivative must be a
registered file under `assets/`. A replacement never changes session.json.
The whole array is a set path. Nested array/identity fields are not set paths.
Presets omit these recording-specific bindings on both save and apply.

Command `{"op":"select_mic","original":{path,size,head_hash},"path":"assets/mic-….caf"}`
registers and selects a completed derivative in one undo step. The supplied
original identity must still match registered and on-disk media, rejecting a stale
processing result. `path:null` clears that original's selection. Missing path is
invalid. No processor runs inside this command. Swift's
`Project.microphoneIdentity(path:)` captures the registered source identity
before processing; `Project.importEnhancedMicrophone(_:forOriginal:)` takes that
identity and copies a successful
Capture VoiceIsolationService output into assets, verifies 48kHz Float32 mono/stereo,
original channel count and duration within one 48kHz sample, and applies this
command. It cleans staged output on failure/cancellation. Use this only after
successful processing; no adjacent-file discovery or automatic preference change.
`Project.useOriginalMicrophone(path:)` clears the binding. Original media remains
registered and untouched; undo/redo retains copied files for existing snapshots.

Cold query `{"q":"microphone_media"}` returns one row per distinct retained mic,
sorted by original path:
`{original:{path,size,head_hash},original_path,original_media_index,path,media_index,enhanced,stale}`.
`path`/`media_index` identify the effective source. A stored binding with changed
original or derivative identity becomes `stale:true,enhanced:false` and uses the
original; relinking an original therefore invalidates its previous enhancement.
Physical missing/changed media retains the normal missing-media error on open.
The same fields are appended to `speech_enhancement.media`, so optional mastering
uses the selected source. Selecting isolation and enabling mastering are separate
explicit choices; no audio is processed twice automatically.

`audio_ranges.path` uses the selected file while every source/file/timeline range,
track offset, clip speed, gain and mute value keeps its original meaning.
`map_audio_ranges` accepts either an original microphone path or its currently
selected path. Render's existing audio-range consumer therefore uses the same
selection for preview and export. Queries and frames perform no selection-related
disk IO; no C ABI layout/version changes. Native isolation quality/latency and UI
selection are separate acceptance work.


## CUR-06 authored palette, shape and logical-size selection

Schema 1 / ABI 3 remain unchanged. Existing cursor.style values and extras codes
0 recorded / 1 pointer / 2 touch / 3 arrow retain their meanings. New set paths
use normal batch/history/journal/save/preset validation:

| Path | Type / default / accepted values |
|---|---|
| `cursor.set_id` | nullable string; new-project default `original`, legacy missing-field default null; original, touch, classic, paper, soft-slate, soft-cloud, lagoon, coral, sage, violet, gold, precision-dark, precision-light, signal |
| `cursor.shape` | nullable string, null; arrow, pointing_hand, touch, text, resize_horizontal, resize_vertical, resize_diagonal_nwse, resize_diagonal_nesw, open_hand, closed_hand |
| `cursor.logical_size` | string, regular; small, regular, large, extra_large |
| `cursor.variants` | object keyed by the 10 shape IDs above plus `crosshair` and `not_allowed`, values `standard` / `alternate`; missing fields default to `standard`; unknown keys/values or null rejected |
| `cursor.variants.<shape_id>` | string `standard` / `alternate`, default `standard`; changes only that type, e.g. `cursor.variants.pointing_hand` |

`original` explicitly selects captured artwork; `touch` forces Render's touch type.
null palette/shape + regular size preserves the legacy recorded/default rendering path.
One of the 12 authored palettes or an explicit shape selects generated artwork;
`original` takes precedence and continues to use captured artwork. Variants are
stored independently for every type and remain selected when switching sets;
they apply to generated artwork, including touch, and do not modify captured PNGs.
Replacing the whole variants object defaults omitted fields to standard; applying
a portable preset merges supplied variant fields and preserves the others.
Shape is independent of the legacy cursor.style; explicit shape takes precedence
unless cursor.always_default is true, which forces effective shape arrow and legacy
style pointer/code 1. Selected palette and logical size remain effective. Legacy
Core pointer still means the system-arrow shape; pointing_hand is an explicit new
shape. Recorded cursor_id metadata remains unchanged except always_default's ID 0.

Root and timed render_options/effects_at append cursor_set_id, cursor_shape,
cursor_logical_size and cursor_variants (all 12 shape keys with string values).
Shape is effective (arrow when always_default); palette/size
reflect the project selection. No new field or code is added to YcFrame/Extras.
Renderer reads these cold options from the same immutable generation and maps them
to RenderConfiguration.cursorSetID/cursorStyle/cursorSize. Logical sizes scale own
artwork by 0.75/1/1.5/2 independently of raster density and existing cursor.size /
animated frame.cursor_scale; do not multiply that frame scale again in Core.
Recorded PNG dimensions/semantics stay unchanged.

New query `{"q":"cursor_library"}` returns
`{sets:[{id,name}],shapes:[string],logical_sizes:[{id,scale}],variants:["standard","alternate"]}`
with the IDs above. Set order is original, touch, then the 12 authored sets in
Render's CursorCatalog order. The existing `shapes` list retains its 10 explicit
override values; per-type variants also cover the captured crosshair/not_allowed
types that Render recognizes automatically. These descriptors expose 14 set
selections and 4 sizes; no
reference/system bitmap or palette data is copied. Renderer/Editor must connect
these fields and picker before claiming selections change preview/export pixels.


## Core behavior alignment (new-project revision 1)

CORE-1/2/3/5/6 contracts below are implemented. See docs/status/core.md for
verification and renderer/editor integration handoffs.

Existing schema-1 projects keep their serialized geometry and physics. New fields
missing in an older file select the legacy mode; opening does not regenerate zooms
or discard settings. The C ABI remains unchanged. All additions below participate
in transactional set/batch, undo/redo, journals, snapshots and save/reopen.

### Factory defaults and compatibility

`Project.create` writes `defaults_revision: 1` and applies the following factory
settings. `Project.open` does not apply that factory preset: schema-0 migration
only advances the schema number, and missing fields in an older schema-1 project
use the legacy values below. Explicit stored values, including `cursor.set_id:
null`, remain unchanged. `defaults_revision` is provenance, not an instruction to
reset values on open. Save/reopen and snapshots keep the selected mode.

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
| cursor.set_id | null, recorded cursor artwork | `original`, captured artwork (CUR-06 wiring); earlier revision-1 projects with `classic` retain it |
| cursor.style / shape / logical_size | `recorded` / null / `regular` | unchanged; set_id selects captured, touch or authored artwork |
| cursor.size / size_points | multiplier1 / null | stored multiplier1 remains inactive; 48 logical points on our 32pt authored canvas |
| cursor.smoothing / speed_preset | 0.15 / `custom` | 0 / `none` |
| cursor.click_effect | `ring` | `none` |
| cursor.physics_version / motion_blur | 0 / 0 | 1 / 1 |
| zoom_settings.physics_version | 0 | 1 |
| zoom_settings.spring (stiffness,damping,mass,overshoot) | (250,28,1,false) | (125,12,1.5,false) |
| default zoom level / follow_cursor | 2 / true | unchanged (default_scale2) |
| newly inserted music gain when omitted | -18dB (amplitude0.1258925412) | -26.0205999133dB (amplitude0.05); existing music gains retain their values |
| audio.click_sound.gain_db | -12dB (amplitude0.2511886432) | -12.0411998266dB (amplitude0.25); click sound remains disabled |

The legacy `canvas.shadow.radius:24` and `offset_y:8` are retained but inactive
for directional shadows; distance25/angle_deg45/blur20 drive that mode. New
mic-preset/stereo and typing metadata do not alter legacy DSP or media clocks.

For the uncropped 320x200 synthetic fixture, new factory aspect evaluates to
1728x1080, versus legacy 1920x1080. Screen destination changes from
(x172.8,y48,w1574.4,h984) to (x172.8,y108,w1382.4,h864). Canvas-space normalized
rect [0.25,0.25,0.5,0.5] evaluates to (432,270,864,540), previously
(480,270,960,540); a full-canvas fade is (0,0,1728,1080), previously
(0,0,1920,1080). Consumers must derive these rectangles from the frame canvas.

`cursor.set_id=null` retains legacy selection behavior. Restoring the current
factory cursor selection requires `original`. Existing projects keep explicit
null, classic or any other stored selection; missing set_id decodes as null.
Missing variants decode as standard for every type, preserving existing artwork.

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
| cursor.size_points | null or 16...128 logical points (our authored base is 32pt) | 48 / null (existing size multiplier) |
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
Selecting speed remembers typing.speed. Unsupported IDs/values fail atomically. Applied bursts remain queryable until
dismissed; applying the same speed again is a no-op. Bursts do not cross capture
segments and have no artificial lead/tail padding.

Microphone presets use Yapcam DSP recipes, not reference processing: voice disables
offline enhancement; noise_reduction selects an 80Hz high-pass, -42dB noise
threshold, 18dB reduction, unit compressor ratio and no normalization; podcast
uses 90Hz, -45dB, 12dB reduction, -20dB compressor threshold, ratio4 and -16LUFS
normalization. Both use -1dBFS peak ceiling. Explicit preset selection resets
the DSP recipe; loading missing preset metadata defaults to voice without changing
the stored enable flag or recipe. stereo_mic is a persisted consumer preference;
Core preserves original microphone channel count in offline prepared files.

The Swift wrapper adds TypingSuggestion, typingSuggestions(), EditCommand cases
applyTypingSuggestion(id:speed:), dismissTypingSuggestion(id:),
restoreTypingSuggestions, and autoSpeedTyping(speed:) with omitted remembered
speed. SpeechEnhancementPlan adds optional micPreset/stereoMic;
MicrophonePreset and setMicrophonePreset(_:) wrap the documented set path.
No C structure or ABI version changes are needed.

## Checked timeline edits and clip controls (CORE-4)

The additive `timeline_constraints` query reports clip/zoom minimum100000000ns,
layout/mask minimum500000000ns and insertion default3000000000ns.
`{op:"timeline_edit",command:{...}}` applies one command or batch atomically and
rejects newly created or retimed items below these limits. Unchanged existing
short items remain readable/editable; the existing precision commands remain
available for old packages and source-clock operations. Editor interactions must
use this checked envelope. Rejection preserves state/history/journal.

`insert_zoom`, `insert_layout`, `insert_mask` take `tl_start_ns` (default0), an
optional `duration_ns` (default3s) and an optional `patch` of the item's existing
fields (id/times immutable). Insertions clamp to the project end and reject a
remaining duration below the item minimum. Layout defaults to overlay; masks use
our existing highlight model. Explicit patches take precedence over default style.

Each clip gains `settings` (serde default): mic_gain/system_gain/external_gain
linear amplitudes0...1 (all1), hide_cursor=false, disable_smoothing=false.
`set_clip_settings {clip_id,patch:{...}}` replaces only supplied known settings;
invalid values/unknown fields fail atomically. Splits inherit settings, cuts and
speed edits retain them, snapshots/history/save preserve them. `clips` query and
Swift ClipInfo expose settings (unity/default settings may be omitted to keep
large project files compact; ClipInfo.effectiveSettings supplies defaults). Frame audio gains and audio_ranges incorporate
mic/system clip amplitudes; cursor flags override project settings. external_gain
is persisted metadata for external-track consumers; absent external media is not
invented. No numeric array-index set paths or C ABI changes are introduced.

## Interactive undo grouping (CORE-7)

`{op:"coalesced_edit",key:"gesture identity",command:{...}}` marks a continuous
interactive change. Successful changes with the same key, committed less than
100ms apart, share the first undo state; redo restores the final state. Different
keys, ordinary discrete commands, undo and redo end a group. Failed/no-op commands
never add a step. The key must be nonempty and <=256 UTF-8 bytes. Editor should
use a stable key per edited object/property during a gesture; discrete actions
remain separate even if clicked quickly. This explicit envelope preserves the
existing precision command API's one-command/one-step contract. Put the
coalesced_edit envelope outside timeline_edit when combining them; a batch is
a single discrete operation unless wrapped by an outer coalesced_edit.

All histories retain at most1000 undo steps, dropping the oldest after adding a
new step. History clocks/groups are runtime state, not serialized project style;
saving and reopening starts a new history as before. Cold `history` query returns
{undo_steps,redo_steps,limit:1000,coalesce_ms:100}. No C ABI change.

## Last edited insertion styles (CORE-8)

`insertion_styles` is persisted, undoable metadata with nullable zoom and mask
styles, initially null for old/new files. Zoom style includes mode, scale and
in/out durations; mask style includes kind, blur_radius, radius, opacity, dim_opacity, fill, stroke
and stroke_width. Geometry, source/timeline clocks, identities and disabled state
are never inherited. Explicit insertion fields override remembered style. New
insert_zoom/insert_mask and omitted add_zoom style fields use this metadata.

Successful manual zoom add/update and mask insertion or canvas.highlights edits
remember the edited style. Bulk mask replacement remembers the last changed row
in array order. Automatic zoom regeneration does not change manual insertion
style. Removing a range retains its remembered style. Undo/redo, snapshots and
save/reopen preserve style history; legacy files start with null metadata and
retain their existing item values. Read-only `insertion_styles` returns both
nullable styles. Metadata has no generic set path and does not change the ABI.

## Capability gates (CORE-9)

Cold `capabilities` returns booleans can_crop, can_round_corners, can_inset,
can_cursor, can_auto_zoom, can_camera, can_camera_layouts and can_external_audio,
plus device_frame_active/external_recording. can_external_audio is currently false
(the model can retain gain preferences, but no external audio mixer is exposed).

`canvas.device_frame` is nullable descriptive frame identifier (null by default;
nonempty <=128 bytes when set). It gates geometry; Core does not claim a device
artwork renderer. With an active frame or external-device/continuity recording,
crop evaluates full-frame and screen corners/inset evaluate zero, while stored
values remain available when the gate is removed. External source kind aliases:
device/external/external_device/iphone/ipad/continuity/screen_continuity. Local
video import is not an external-device recording.

Pointer overlays and automatic zoom require immutable captured mouse events and
are unavailable for external recordings. Cursor already baked into the video
also disables overlay rendering, while pointer events can still support zoom.
Auto zoom requests without mouse capability coerce to manual; regeneration cannot
manufacture pointer-driven ranges. Camera controls/layout capability requires an
actual camera track/file. Stored layouts are retained for compatible media and
presets; missing camera never synthesizes a frame. Editor must use the query to
hide/disable controls. Frame evaluation applies gates allocation-free without
rewriting saved crop/corners/inset/cursor settings. No C ABI changes.

## Full-project autosave and dirty revisions (CORE-10)

Cold `autosave_policy` returns {enabled,delay_ns:30000000000}; enabled reads the
existing autosave setting. Immediate recovery journals continue to protect each
edit; the 30-second quiet period applies to the full project.json save. An edit
restarts the timer. Changing autosave off cancels the pending full save.

Swift Project adds revision (UInt64) and isDirty, updated only after successful
mutations; create/recovery-journal open starts dirty, a clean open starts clean.
Failed/no-op commands do not advance the revision. apply/undo/redo advance it;
ordinary save captures and marks the current revision clean under the same
mutation gate. save(ifRevision:) returns false without writing when its captured
revision has become stale. Successful save never clears a later edit's dirty flag.
Reads still bypass the save/mutation gate as before; close rejects stale saves.

ProjectAutosaver is an opt-in MainActor coordinator owned by the document. It
observes Project.didChange, uses a trailing 30-second delay by default, and saves
on a worker task only if the revision is still current. cancel() cancels the timer
and unregisters observation; call before closing a document. Errors remain exposed
in lastError and keep the project dirty. Existing Editor autosave must adopt this
coordinator or align its own delay/revision guard; Core does not silently install
a second timer on every Project. Snapshots have independent revision lifetimes.


## Camera style (GAP-ED-8, Core/Render contract)

Schema-1 `camera.style` is additive and defaults to original/no grading, intensity1,
sharpen0, grain0, background_blur0 and full-frame crop, so old projects keep their
appearance. No new C ABI fields are needed: `render_options` / time-specific
`render_options_at` append `camera_style`; `{"q":"camera_style"}` returns the
same persisted settings. Rendering applies camera crop before face framing, then
grading/LUT at intensity, sharpen, grain and background blur. Core evaluates and
validates settings; Render owns the pixel implementation and must advertise its
availability in its UI integration.

| Set path | Values / default |
|---|---|
| camera.style | complete or serde-defaulted CameraStyle object |
| camera.style.preset | original / custom / lut / IDs from camera_style_library; default original |
| camera.style.intensity | 0...1 / 1 |
| camera.style.warmth | -1...1 / 0 |
| camera.style.background_pop | 0...1 / 0.2 (inactive with original) |
| camera.style.contrast | -1...1 / 0.25 (inactive with original) |
| camera.style.color_intensity | -1...1 / 0.15 (inactive with original) |
| camera.style.sharpen / grain / background_blur | 0...1 / 0 |
| camera.style.crop | normalized [x,y,w,h], positive inside unit rect / [0,0,1,1] |
| camera.style.lut_path | null or registered package-relative media path / null |

`{"q":"camera_style_library"}` returns twelve original Yapcam recipes with
`{id,name,warmth,background_pop,contrast,color_intensity}`. Their names/recipes are
our own, not reference strings/assets. Selecting a built-in recipe sets its four
parameters; selecting custom retains them. Original bypasses grading. Editing a
recipe parameter selects custom. LUT selects registered local `.cube` data;
intensity0 bypasses grading but retains choice. Mirror/face tracking use existing
camera.mirrored / camera.face_framing paths and retain their legacy defaults.

Swift `cameraStyle()` / `cameraStyleLibrary()` return typed records.
`importCameraLUT(from:)` parses UTF-8 3D CUBE data (size2...64, exactly N^3 RGB rows,
finite values and valid optional DOMAIN_MIN/MAX), copies it under assets, registers
it as media and selects it in one atomic undoable batch. Limit32MiB. No external
file path is retained. Invalid data/closed project/failed edit removes staged
assets; original source files remain unchanged. Undo retains the copied asset as
with background images. `CubeLUT(data:)` exposes parsed dimension/domains/values
to consumers without a new dependency.

Portable presets exclude camera crop and LUT path. Swift file presets carry LUT
bytes in `_camera_lut` base64 and register a fresh destination path on import;
raw lut preset choices without embedded data cannot select unrelated target
media. Full project save/reopen retains camera crop and registered LUT reference.


## Camera layout extensions (GAP-ED-9)

Additive camera.layout_settings configures root mode overlay/cutout/split and is
available in render_options as camera_layout. Existing layout segments accept
new modes cutout/split; legacy side_by_side keeps its previous geometry. Optional
segment `settings` replaces the root layout settings for that interval (omitted
members in that object use documented defaults, not root inheritance). Mode is
always the segment's mode when active. Missing fields retain legacy geometry.

| Set path | Values / default |
|---|---|
| camera.layout_settings | full settings object with fields below |
| camera.layout_settings.mode | overlay / cutout / split; overlay |
| camera.layout_settings.aspect | null (source aspect) or 16/9,4/3,1,3/4,9/16; null |
| camera.layout_settings.split_ratio | null (fit source/camera aspects, clamp 0.25...0.75), .5 or 2/3; null |
| camera.layout_settings.split_flip | bool / false |
| camera.layout_settings.split_padded | bool / false |
| camera.layout_settings.cutout_position | normalized center [x,y] / [1,1] |
| camera.layout_settings.cutout_size | .2...1 / .5 of canvas width |
| camera.layout_settings.edge_softness | 0...1 / .2 |
| camera.layout_settings.edge_inset | 0...8 output pixels / 0 |
| camera.layout_settings.corner_ratio | null (legacy pixel radius) or0...0.5 times shorter camera edge; null |
| camera.hide_during_silence | bool / false |
| camera.min_silence_ns | 2...15s / 5s |
| camera.silence_ranges | sorted, nonoverlapping `{tl_start_ns,tl_end_ns}` array / [] |
| camera.layouts | existing layout rows plus optional settings object and mode cutout/split |

Silence ranges come from decoded mic analysis, e.g. existing map_audio_ranges;
Core never decodes media on the frame path. Ranges are half-open. Hide only when
an interval's edited duration meets min_silence_ns; speed/cuts remap them with
other effects. Silence ranges never enter presets. They do not invent intervals
when no analysis exists. Hide-camera/fullscreen combinations fall back to screen.

Overlay retains existing root position/size and camera.zoom_scale behavior. An
explicit aspect chooses the fitted camera destination; crop remains a separate
camera-style source rect. Cutout uses bottom position/size and turns on background
removal (Render owns softness/inset pixel processing); corners are0. Split divides
the canvas on its longer axis, uses optional padding and fits each source into its
region. Flip swaps regions. Padded split honors legacy corner radius/optional
corner_ratio; unpadded split uses0. Settings are evaluated identically for preview
and export with no frame-path allocation. `{"q":"camera_layout_at","tl_ns":...}`
returns `{mode,settings,visible}`; time-specific render options agree. Swift
cameraLayout(atNs:) returns CoreCameraLayout, and CoreRenderOptions.cameraLayout
is optional for older libraries. Root layout settings/hide preference/minimum are
portable style; per-range records and silence ranges remain project-specific.


## Magnifying lens zoom (GAP-RND-5, Core contract)

Zoom records and remembered zoom insertion style append `style` (`classic` or
`lens`, default classic) and `lens:{radius,bevel,chromatic_aberration}`. Generic
update_zoom.patch accepts style, whole lens or existing zoom fields. Radius is
0.25...0.75 (default .35), bevel0...1 (default .2), chromatic_aberration0...1 (default
.5). add_zoom and insert_zoom inherit last-edited style/lens settings; automatic
zoom generation stays classic. Old projects decode classic and keep their crop.
No zoom records or source IDs enter portable presets.

Classic transforms the whole screen crop. Lens leaves the screen crop unchanged
and emits a local circular magnification instruction. `{"q":"zoom_lens_at",
"tl_ns":...}` returns null when inactive, otherwise
`{zoom_id,center:[canvasX,canvasY],source_center:[normalizedX,normalizedY],scale,
radius_px,bevel,chromatic_aberration,opacity}`. Center is clamped to visible source
bounds and follows filtered input for auto/follow-cursor zooms, independently of
cursor overlay visibility. Radius_px = radius * shorter screen destination edge.
Scale and opacity use the same early-start/ease/spring weight as classic; the
latest-start enabled active zoom wins. Camera-only/absent-screen frames emit null.

Time-specific render_options append optional zoom_lens with the same record;
untimed render_options emit null. Swift zoomLens(atNs:) returns CoreZoomLens?,
CoreRenderOptions.zoomLens is optional, ZoomSpec appends style/lens and ZoomLens
is Codable. These are cold drawing instructions; Render owns lens pixel sampling,
bevel and chromatic shading. Existing C ABI structs stay unchanged.


## Targeted transcript restoration (GAP-ED-7)

`insert_source {src_start_ns,src_end_ns,at_tl_ns,speed?:1,settings?:ClipSettings}`
inserts an original recording span as a new clip. Source bounds must be nonnegative,
positive length and inside the recording; speed uses existing .05...32 bounds.
At_tl_ns must be an existing rounded clip boundary (including0/end), otherwise the
whole command fails. To insert inside retained content, split first in one batch.
Repeated source spans are allowed. The new clip ID is returned in createdIDs.
All media tracks and input/marker events share the inserted clip mapping, so the
restored screen/camera/audio/events stay synchronized. Per-clip settings default to
unity/false; pass the original settings to preserve restored-word volume/cursor.

Later timeline-attached effect starts/ends shift by the inserted rational duration;
ends exactly at the insertion remain before it, starts exactly there move after it.
Effects spanning the boundary extend across the new interval. Existing clip IDs,
source ranges, settings and speeds stay unchanged. Clips/effects/history update in
one validated durable transaction. Undo/redo reverses only this insertion; it does
not undo unrelated edits made since the original deletion. Empty timelines can be
restored at0. Wrapped timeline_edit also enforces the100ms clip minimum; precision
insert_source supports shorter transcript spans.

Swift EditCommand.insertSource(startNs:endNs:atNs:speed:settings:) appends to the
existing enum. Editor can retain original source-word bounds from the immutable
capture transcript and restore a word at its cut boundary, optionally batching
add_caption to restore the label. Existing delete_range/remove_caption/
update_caption and batch primitives handle cut/hide/correct/filler/pause actions.
Core does not infer which deleted word a UI selection refers to; history remains
available for whole-action undo. No media is copied or recording files rewritten.


## Master motion-blur amount (GAP-RND-8, Core contribution)

`canvas.global_motion_blur` is null (legacy independent amounts) or0...1 (master
multiplier). New projects store1; old projects with missing/null fields retain
exactly their stored screen/zoom/pan/cursor amounts. No visible default changes.
Existing canvas.motion_blur, motion_blur_settings and cursor.motion_blur remain
available as extras. A master0 disables all blur; a master.5 scales every kind by
.5. The master is portable style and follows normal set/preset/history/save rules.

Frame.motion_blur, FrameMotion's three blur amounts, legacy Extras' cursor amount
and cold render options already include this multiplier. Render must not apply it
a second time. Untimed render_options append global_motion_blur as descriptive
metadata (Swift CoreRenderOptions.globalMotionBlur?). Renderer applies actual
preview/export fps divided by60 to the evaluated blur amounts, because Core's
recording max_fps is not necessarily the render rate. Preview may disable blur.
Editor should bind its single blur slider to canvas.global_motion_blur.

### RND-9 project screen-quality preference

Optional schema-1 `canvas.screen_quality` defaults to null for both existing and
new projects. Null/missing keeps the existing screen samples unchanged. Selecting
`{}` opts in with `improve_quality:0.5,upscaling:"quality"`. This is Render's
existing spatial filtering/resampling control, not a learned enhancement model.

| Set path | Value / limits |
|---|---|
| `canvas.screen_quality` | null or `{improve_quality:0...1,upscaling:"off"|"fast"|"quality"}`; object fields default as above |
| `canvas.screen_quality.improve_quality` | finite number 0...1; select an object first |
| `canvas.screen_quality.upscaling` | off, fast or quality; select an object first |

The existing `render_options`, `render_options_at` and `effects_at.render_options`
queries append `screen_quality` with the selected object or null. It is a portable
style setting, preserved by presets, batch edits, undo/redo, snapshots, journals
and save/reopen. Invalid values fail without changing project/history. Opening
older projects does not opt in. Frame geometry/timing and the C ABI remain
unchanged; filtering affects screen pixels only in Render's existing shared
preview/export compositor. Queries do not process pixels or perform file IO.
Swift exposes `CoreScreenQuality`, `Project.setScreenQuality(_:)` (nil to clear)
and `CoreRenderOptions.screenQuality`. Editor wires controls to these paths;
Render already decodes this query field. Native pixel acceptance remains with
Render/Lead.

### CAP-3 compatibility with UI marker sidecars

The optional `recording/markers.json` sidecar written by the toolbar contains
`{"markers_ns":[0,1234567890,...]}` in global source nanoseconds (pauses removed).
Core reads it once on create/open and merges flags into its immutable in-memory
capture events. It never rewrites the sidecar, session or event files. The existing
`markers` query/TimelineMarker API then applies the same split/cut/speed/repeat
mapping as event-log markers. Sidecar-only IDs are `ui-marker:<array-index>`;
the array index is retained even if earlier entries are discarded. Existing
captured markers win at the same exact source time; repeated sidecar times are
collapsed, retaining the first index. Unsorted sidecars are accepted and sorted
in memory; markers outside retained recording segments (including the final
recording end or a truncated recovery tail) are discarded.

Absent sidecars preserve old behavior. Invalid JSON, missing/non-array markers_ns
or non-integer timestamps return the usual invalid-JSON error; additional
sidecar metadata keys are ignored. Query/snapshot/frame paths never read the file;
changes to it are visible on the next create/open. No new set paths, commands,
queries, project fields or C ABI changes. New recording UI should eventually
forward flags directly to Capture's durable RecordingSession.addMarker API;
this reader preserves packages already written with the UI sidecar format.

### RND-7 inset origin

Schema-1 `canvas.inset_origin` is a two-number set path `[x,y]`, each finite and
in -1...1, default `[0,0]` for existing and new projects. Zero retains the centered
inner border. Positive values weight the existing inset toward right/bottom;
negative values toward left/top. Render keeps the total inset constant per axis.
The existing render_options/render_options_at/effects_at.render_options queries
append `inset_origin:[x,y]`, which Render already consumes. CoreRenderOptions
exposes `insetOrigin`. This portable style setting supports normal presets,
batch validation, undo/redo and persistence. No frame geometry, timing, ABI or
factory pixel changes; Core only supplies metadata for the existing renderer.

### ED-10 caption typography and timed reveal

Schema 1 / ABI 3 remain unchanged. Caption records in `canvas.captions` gain the
following `style` fields. The same TextStyle shape is accepted by add_caption,
update_caption's whole style patch, import_transcript.style, and the existing
whole-array set path `canvas.captions`. Array indices and nested record leaves
are not set paths; use update_caption by id. Annotation/reaction/key-overlay
styles share the typography fields, but only captions evaluate word reveal.

| Style field | Values / missing-field default |
|---|---|
| `font_family` | sans, serif, mono / sans (the existing sans-serif appearance) |
| `reveal` | line, word / line |
| `growth` | full, expanding, centered / full (preserves existing full-box layout) |
| `entrance` | appear, fade, slide / appear |
| `language` | auto or a bounded language/locale tag / auto |

A language tag is 2...8 ASCII letters followed by optional '-' or '_' separated
1...8 alphanumeric subtags, at most63 bytes. It records caption/recognition
language, not translation or recognition availability. Capture's actual on-device
speech service decides supported locales. No static list claims platform support.
If import style language is auto and transcript.locale is a valid tag, imported
records retain that recognized locale; otherwise they keep auto. The cold query
`{"q":"caption_options"}` lists font/reveal/growth/entrance choices and the
language-tag capability; UI can also use the typed Swift enum cases. Native
supported-language discovery belongs to Capture/Editor, not Core.

Optional record `words` defaults to `[]`. Entries are
`{text,tl_start_ns,tl_end_ns}` with exact absolute timeline Int64 clocks, positive
half-open ranges inside their caption, ordered without overlap. Their texts joined
with spaces must match the caption after whitespace normalization. Transcript import
continues creating one caption per retained word, with its actual mapped word timing;
no existing grouping behavior changes. A manually authored record without timings
uses uniformly spaced whitespace-delimited words across its range; this fallback is
an animation choice, not inferred speech alignment. Other effect kinds require words
empty. Timed entries follow the same exact edit mapping as caption bounds. Removed
words disappear from their caption text; a caption whose timed words are all cut
is removed. update_caption retiming without a words patch scales existing timings
with integer arithmetic. A text-only correction without a words patch clears old
word timing, avoiding mismatched transcription metadata. Supply explicit words to
retain corrected alignment.

The existing captions query returns these fields. layers_at/effects_at text layers
append font_family and a caption instruction:
`{full_text,visible_text,font_family,reveal,growth,entrance,language,line_opacity,
line_offset_y,words:[{text,tl_start_ns,tl_end_ns,visible,progress,opacity,offset_y}]}`.
Word mode accumulates words at their starts until the caption end. Entrance progress
runs over min(200ms, word duration); line mode animates the whole line from its start.
Fade opacity equals progress, slide offset_y is 0.25*(1-progress) of text box height,
and appear is immediate. Core evaluates line opacity/slide into existing layer
opacity/rect; the compatible text field is the visible text. For word animation,
Render consumes per-word opacity/offset after shaping. Full growth reserves full-line
layout; expanding fits the visible prefix with a stable left edge; centered fits
around the original center. Glyph measurements/font selection/background fitting
belong to Render; Core never approximates glyph widths. Default line/full/appear
keeps old pixels. Native font, growth and per-word animation require Render wiring;
metadata persistence alone is not pixel acceptance. No new C struct or hot-path IO.

Swift TextStyle adds typed FontFamily/Reveal/Growth/Entrance plus language;
TextEffectRecord adds [CaptionWord], both decoding older records with defaults.
CoreRenderLayer exposes optional fontFamily/caption evaluation. Presets continue
omitting caption records/timing, while shared style preferences remain portable.


## Round 5 factory revision 2

Only Project.create applies defaults_revision=2. Opening revision0/1 or files
without these fields keeps stored values and legacy decode defaults unchanged.

| Field | Revision1 factory → revision2 factory |
|---|---|
| camera.position / size / zoom_scale | [.82,.78] / .22 /1 → [1,1] /.5 /.8 |
| camera.layout_settings.aspect / corner_ratio | null/null →1/.15 |
| camera.layout_settings.edge_padding_ratio | new field, legacy0 → factory.5 |
| cursor.loop_duration_ns |400000000 →1000000000 (loop remains off) |
| cursor.remove_shakes / optimize_types |false/false →true/true |
| cursor.rotation_mode / rotate_on_move / tilt_amount |static/false/1 →tilt/true/.5 |
| canvas.inset_color |[1,1,1,1] →[0,0,0,.5] (size stays0) |
| canvas.screen_quality |null →{improve_quality:.5,upscaling:quality} |
| newly inserted highlight dim_opacity with no remembered style |.4 →.5 |

`camera.layout_settings.edge_padding_ratio` and the same field in each layout's
settings accept finite0…1, default0 on old decode. The inset from each canvas edge
is that ratio times evaluated canvas padding. Overlay/cutout geometry uses this
inset; screen/full-camera/split modes retain their own fitting rules. Stored
camera.radius remains available for legacy/null corner_ratio. New cursor palette
remains original and our calm dark background remains our own artwork choice.
All paths participate in normal set/batch, history, presets and save/reopen.


### Round 5 seamless cursor loop

Loop interpolation happens after crop/layout/entrance transforms, in canonical
canvas pixels. During the last min(loop_duration_ns,duration) of the edited
video, the cursor glides toward its first evaluated canvas hotspot using a
stateless quintic ease. The last evaluated hotspot equals frame0 even with
changes of source segment, speed, crop, zoom or camera layout. Loop takes
precedence over stop_before_end_ns; stored stop duration is retained. No frame
layout, ABI, field value or legacy duration is rewritten.

### Round 5 adaptive composition

New `zoom_settings.smart_framing` bool defaults false on legacy decode, true
for revision2 create. Auto zooms keep the evaluated cursor hotspot clear of a
visible overlay/cutout camera. The evaluator first chooses a bounded crop shift;
if source edges prevent that, the camera moves to the nearest clear corner and
shrinks only when all corners would cover the cursor. Manual zooms/hidden cameras
are unchanged. Selected source crop is never expanded and the policy is stateless.

New `canvas.avoid_empty_zoom_area` bool defaults false. When enabled, classic zooms
progressively fill their allocated screen region by adjusting the bounded crop
aspect; disabled retains the fitted screen/background. No source outside the
selected crop is sampled. `canvas.auto_layout` bool defaults false on legacy
files and true for revision2. It adapts canvas-space caption/shortcut rectangles
for portrait output and avoids the evaluated camera; shortcuts also avoid active
captions. Authored annotations/reactions/source-space items are unchanged. Turn
it off to retain fixed normalized text positions. This evaluates rectangles;
changing aspect never rewrites saved targets, rectangles, time ranges or IDs.

New optional `TextStyle.font_size_ratio` (null legacy; finite .005…0.25) is a
fraction of canvas height. Evaluated layers convert it to pixel font_size, while
stored font_size remains the explicit pixel fallback. `caption_defaults` query
returns the factory insertion style: revision2 sans/line/expanding/appear,
white on black, ratio.05, pixel fallback54; older projects retain the original
36px/full-line defaults. Importing a transcript without an explicit style uses
these defaults. Revision2 key-overlay style uses ratio.1/fallback108. The Swift
importTranscript style argument becomes optional; explicit styles retain their
values. Updating a caption's explicit pixel font_size clears its ratio unless
a ratio is supplied in the same style patch. Geometry/canvas/ABI types unchanged.


### Round 5 source-backed camera speech activity

New nullable `camera.speech_activity` stores analysis in recording source ns:
`{source:"vad"|"transcript",coverage_start_ns,coverage_end_ns,ranges:[{src_start_ns,src_end_ns}]}`.
Coverage is nonnegative, increasing and within recording duration; speech ranges
must lie within it. Unsorted/overlapping speech input is canonicalized to a sorted
union. Null is the legacy/manual mode. An empty range list inside known coverage
means confirmed silence; time outside coverage remains unknown/visible.

When this input or clips change, Core computes the complement, maps it through
cuts/speeds/repeated clips and restores, merges adjacent silence, and stores
camera.silence_ranges. Existing hide_during_silence/min_silence_ns semantics use
these output-timeline intervals (2…15s minimum, factory5s). New analysis is one
transaction/undo step. Setting camera.silence_ranges explicitly clears source
analysis (manual override); setting speech_activity=null clears its derived ranges.
Portable presets exclude both analysis and intervals. Source metadata survives
undo/redo, snapshots and save/reopen. Importing a complete capture transcript
updates transcript activity over the session; existing VAD activity takes priority.
Manual add_caption commands that omit style also use caption_defaults; explicit
styles and decoded existing records retain their appearance.
The typed Swift setCameraSpeechActivity(_:) accepts the same metadata. Use the
existing mapAudioRanges API for file-local VAD clocks, or provide global source
intervals directly with known coverage; do not relabel file clocks as source ns.

### Round 5 timeline item state and moving masks

Layout records append enabled (bool, missing=true). Disabled ranges retain all
settings but do not override the default/other enabled layout. Highlight/mask
records append enabled (bool, missing=true) and keyframes (default[]), a strictly
ordered list `{tl_ns,rect:[x,y,w,h]}` within that mask's half-open interval (an
endpoint key at tl_end_ns is allowed). Rectangles obey the existing normalized
bounds. Bounds interpolate linearly from the mask's initial rect/time to keys,
then hold the last key; exact keys use their rect. Crop/zoom clipping happens
after interpolation. Disabled masks emit no layers/extras and don't consume the
32 simultaneous-active slots. Geometry, enabled state and keyframes are never
inherited as insertion style. Cuts/speeds/restores retime keys along with masks;
collapsed times keep the last key. Curve knots are sampled at map slope changes
and immediately around cuts, preserving retained source motion; a mask spanning
restored time holds its boundary rectangle over the insertion. Editing arrays uses existing canvas.highlights
and camera.layouts paths. Existing C structs and extras slot geometry are intact.


### Round 5 directional cursor and remembered zoom level

`cursor.rotation_mode` additionally accepts `follow`. It aligns the authored
arrow's NW heading with evaluated canvas motion, then applies rotation_degrees.
Idle/hidden/cut frames return to the base angle; there is no mutable seek state.
Tilt adds its velocity angle to the base for revision2; older tilt projects retain
the original ignored-base behaviour. Follow ignores tilt_amount; the legacy
rotate_on_move alias selects tilt/static and both moving modes report it true.
Mode values, history, presets and save/reopen remain synchronized.

An explicit update_zoom patch containing scale in1…4 also remembers that scale
as zoom_settings.default_scale in the same undo step. Automatic zoom generation
never changes it; precision zooms above4 retain the prior default. Editor owns
the1s gesture debounce (then sends the final level); Core publishes atomically.


### Round 5 autosave retry

ProjectAutosaver retains the30s trailing delay after a save failure and retries
without requiring another edit. Every new edit restarts the pending timer; a
successful save/manual clean state clears the error. Dirty revision stays dirty
through failures. Closed, disabled or cancelled documents never reschedule.
Project.isClosed is a read-only synchronized lifecycle query. Journaling and
atomic-save semantics are unchanged; no busy retry loop or IO on frame calls.


### Round 5 hidden shortcut chords

`cursor.key_overlay.hidden_shortcuts` is a list of exact canonical display
chords (default[], max256 nonblank strings of at most256 UTF-8 bytes). Modifier
order is Ctrl/Option/Shift/Command, represented by ⌃⌥⇧⌘ followed by the captured
key. A hidden latest event suppresses the overlay until another eligible event;
it does not reveal a preceding chord. Source events/typing suggestions remain
unchanged. This display preference is portable, undoable and saveable.
`{"q":"key_overlay_shortcuts"}` lists unique nonempty captured keys/chords
remaining on the edited timeline as `{text,is_shortcut,hidden}`, sorted by text.
The query includes single-key presses so Editor can edit their preference even
when shortcuts_only currently filters them out. Swift keyOverlayShortcuts() and
setHiddenShortcuts(_:) use these payloads. These are cold queries; filtering does
not add event scans to frame_at or binary-search overlay lookup.
