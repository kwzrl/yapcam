# Yapcam architecture

Native SwiftUI app with a Rust core for the project model and all timing/effect math.
Pixels never cross the Swift↔Rust boundary.

```
┌──────────────── Swift (SwiftPM) ────────────────────────────────┐
│ Yapcam (app)        shell, vertical toolbar, windows, settings  │
│ YapcamCapture       ScreenCaptureKit, AVCapture cam/mic,        │
│                     cursor/click/key events, session lifecycle  │
│ YapcamEditor        timeline UI, inspector, preview player      │
│ YapcamRender        Metal compositor + AVFoundation export      │
│ YapcamCore          Swift wrapper over the C ABI ───────────┐   │
└─────────────────────────────────────────────────────────────│───┘
┌──────────────── Rust (core/) ────────────────────────────────▼──┐
│ yapcam-core  project model (versioned JSON), time model,        │
│              non-destructive edits + undo/redo, zoom/cursor/    │
│              layout/effect evaluation → FrameDescription        │
└─────────────────────────────────────────────────────────────────┘
```

## Core rule: one evaluator for preview and export

`yc_frame_at(project, timeline_time)` returns a `FrameDescription`: which source
frames to sample at which source times, plus every transform (canvas size,
background, padding, corner radius, shadow, screen crop + zoom rect, cursor
position/scale/visibility/click effect, camera rect/shape/visibility, audio gains).
`YapcamRender` draws a `FrameDescription` with Metal. The preview player and the
exporter call the *same* evaluator and the *same* compositor; they differ only in
clock (display link vs. offline frame loop) and sink (MTKView vs. AVAssetWriter).

## Time model

- **Capture clock:** every captured sample and input event is stamped in host time
  (`mach_absolute_time` via `CMClockGetHostTimeClock`), converted to nanoseconds.
- **Source time (`src_ns`, i64):** nanoseconds since the recording session start,
  pauses removed. A recording consists of *segments* (one per resume); each segment
  stores its host-time start and its `src_ns` offset. Tracks with different frame
  rates keep their own sample timestamps; nothing is resampled at capture.
- **Timeline time (`tl_ns`, i64):** the edited timeline. `Clip`s map timeline ranges
  to source ranges (`src_start`, `src_end`, `speed`). Cuts remove source ranges;
  all tracks (screen, camera, mic, system audio, events) share one clip list, so
  a cut can never shift audio against video or events.
- Rounding happens exactly once: when the renderer picks the source frame nearest
  to `src_ns` per track. Tests assert zero accumulated drift over 10 000 edits.

## Recording bundle / project package

A project is a directory package `Name.yapcam/`:

```
Name.yapcam/
  project.json            versioned project (schema_version), written atomically
  project.json.prev       previous good version (crash recovery)
  recording/
    session.json          devices, display id/scale/size, segments, host-time base
    seg-000/
      screen.mov          HEVC/H.264, native pixel size, VFR up to 60 fps
      camera.mov          optional
      mic.m4a             optional
      system.m4a          optional
      events.jsonl        cursor moves, clicks, scrolls, keys, window focus (src-relative ns)
  autosave/               journal for in-flight edits
```

Media references in `project.json` are package-relative paths plus size and a
content hash of the first MiB, so moved or missing media is detected and relinkable.
Writes: temp file → fsync → rename; the previous version is kept as `.prev`.
Recordings stream to disk while recording; an interrupted session is recovered from
whatever segments were finalized plus the fragmented-MP4 tail (movie fragments
every 2 s).

## Swift ↔ Rust boundary (C ABI)

Header: `core/include/yapcam_core.h` (owned by Lead; changes need a Lead commit).

- Opaque handle `YcProject*`.
- Cold path (open/save/edit) = UTF-8 JSON in/out. Edits are commands
  (`{"op":"split","at_tl_ns":…}`) applied by `yc_apply`, which records undo.
- Hot path `yc_frame_at` fills a `#[repr(C)] YcFrame` struct, no allocation.
- Every function returns `YcStatus`; error text via `yc_last_error()`.
- Strings returned by Rust are freed with `yc_string_free`.

## Capture

- Screen/window/area: `SCStream` + `SCRecordingOutput` (or `AVAssetWriter` when we
  need per-sample control), filter excludes Yapcam's own windows.
- System audio: `SCStreamConfiguration.capturesAudio`, separate file.
- Mic/camera: `AVCaptureSession`, separate files, host-time stamped.
- Cursor/clicks/keys: `CGEventTap` (listen-only) → `events.jsonl`; cursor images
  captured once per cursor change so the editor can render a scalable cursor while
  the screen track is recorded with `showsCursor = false`.

## Build

`scripts/build-app.sh` → `cargo build -p yapcam-core` (static lib) → `swift build`
→ bundle + sign. Rust tests: `cargo test` in `core/`. Swift tests: `swift test`.
