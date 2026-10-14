# Capture validation

Lead must register `YapcamCaptureTests` in Package.swift with a dependency on
`YapcamCapture`. No permissions are requested by the default tests.

```sh
swift test -j 4 --filter YapcamCaptureTests
YAPCAM_CAPTURE_MEDIA_TESTS=1 swift test -j 4 --filter actualHEVCWriterAndInterruptedRecovery
```

The opt-in test writes real 64×64 HEVC samples, reopens their track, checks the
first-sample offset, and recovers an interrupted manifest. It needs working
VideoToolbox/IOSurface services and fails in restricted command sandboxes. Run it
from a regular terminal; skipping it is not evidence that recording works.

The app's hidden `--capture-selftest <seconds>` handler should call the main-actor
`CaptureSelfTest.run(seconds:)` helper, log the returned package or error, then
terminate. This must run from an app signed with the normal Yapcam identity and
bundle ID. The helper never requests permissions. Its default output directory is
`~/Movies/Yapcam/QA/capture`; these files must never be committed.

After a successful self-test:

1. Use ffprobe on `recording/seg-000/screen.mov` and `system.m4a`: HEVC, native
   pixel dimensions, no video cursor; separate AAC audio at 48 kHz stereo.
2. Compare movie packet timestamps plus `track_start_ns` to the segment-relative
   timestamps in `events.jsonl`. Verify monotonic event times, cursor assets, and
   clicks aligned with a visible action in the screen track.
3. Repeat via `CaptureSelfTest.run(seconds: 5, maxFPS: 30, pauseAfter: 2)` and at
   60 fps. Check two segment directories and that segment 1's source start equals
   segment 0's duration (the 0.5 s test pause is absent).
4. Exercise `.window(id)` and `.area(display: id, rect: ...)`, move/resize the
   window, close the source window, cancel a session and verify package deletion.
5. On camera/mic hardware, verify separate files, shared host-clock offsets,
   audible sync, meter levels, disconnect warnings, and continued screen capture.
6. For a real crash test, terminate only the test recording process after more
   than 2 s, discover with `interruptedPackages(in:)`, then call `recover(_:)`.
   Check recovered media and event tails. Preserve originals when reporting failure.

Retina and multiple-display hardware are still needed to verify the tested point/
pixel and global-coordinate math against actual ScreenCaptureKit output.
