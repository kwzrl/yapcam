# Team capture (YapcamCapture)

Own: `Sources/YapcamCapture/**`, `Tests/YapcamCaptureTests/**`.
Implement the `YapcamCapture` surface in `docs/SWIFT_API.md`, writing packages exactly
per `docs/FORMATS.md`.

## M1 (in this order)
1. `CaptureSources.load()` (SCShareableContent + AVCaptureDevice discovery) and
   `CapturePermissions`.
2. `RecordingSession` for `.display`: ScreenCaptureKit stream, screen track to
   `seg-000/screen.mov` via AVAssetWriter (HEVC, native pixel size, VFR ≤ maxFPS,
   `showsCursor = false`, fragmented writing so a crash leaves a readable file),
   system audio to `system.m4a`, host-time stamps → `track_start_ns`, `session.json`
   written at start (`status: recording`) and finalized at stop.
3. Cursor/click/scroll/key events via listen-only `CGEventTap` (fallback NSEvent global
   monitor) → `events.jsonl`; cursor images → `cursors.json` + PNGs.
4. Exclusion of Yapcam windows (`CaptureExclusions`) in the SCContentFilter.
5. Pause/resume = new segment; stop; cancel deletes the package.
Verify with real recordings (add a hidden `--capture-selftest <seconds>` entry point
in your module that the app can call; the ui team wires the flag): ffprobe the files,
check timestamps of events against the screen track.

## M2
`.window` and `.area` targets, mic + camera via AVCaptureSession (separate files,
same host clock), device loss mid-recording (warning, continue), source disappearing,
permission revoked, low disk (stop cleanly before 1 GB free), interrupted-package
recovery, display scale/Retina math, multi-display coordinates, keystroke capture
option, recording at 30/60 fps, audio level metering.

## Tests
Unit-test event serialization, time conversion, segment math, package layout.
Real-capture tests via the self-test entry point; record results in your status file.
