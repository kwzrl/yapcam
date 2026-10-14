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
