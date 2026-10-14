# Capture validation

`YapcamCaptureTests` is registered on main. No permissions are requested by the
default tests. Simulated routing tests use test-only media sinks; the production
writer always uses AVAssetWriter, and encoding remains a separate real-media gate.

Controlled session tests exercise the production coordinator and package writes:
pause/resume timelines, low disk, revoked permission, source loss, stale callbacks,
cancel during startup, failed finalization, and fixed window output after a resize.
Input tests feed value snapshots through the production translation path for
clicks, drags, scrolling and opt-in Unicode/modifier keys. These tests neither post
system events nor prove encoder output or actual OS permission behavior.

```sh
swift test -j 4 --filter YapcamCaptureTests
YAPCAM_CAPTURE_MEDIA_TESTS=1 swift test -j 4 --filter actualHEVCWriterAndInterruptedRecovery
```

The opt-in test writes three real 64×64 HEVC frames, ends the writer at 2 s,
checks the full track duration and reads a frame at 1.8 s in the static tail. It
also checks a zero screen offset and recovery before the manifest catches up.
It needs working
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
   Each segment's host_start_ns is its first written screen PTS; screen's
   track_start_ns must be zero. Device/system-audio preroll is discarded.
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
7. Test `hideDesktopIcons: true` and `captureNotifications: false` via the helper.
   Finder folder windows must remain visible. Desktop preferences are untouched;
   icon/notification exclusion is a capture filter, with notification behavior
   subject to macOS. Repeat with `recordKeystrokes: true` for opt-in key events.

The helper also supports `microphoneID`, `cameraID`, and `target`. Test window
movement/resizing both during capture and during the pause. Check the mic meter
resets to zero after a disconnect and that the screen track continues.

An advisory `recording/.capture.lock` excludes a live/paused recording from
recovery. The OS releases it on a crash. `seg-XXX/track-starts.json` is an optional
crash sidecar containing segment-relative first-track offsets; `.prev` is a fallback.
The additional optional `seg-XXX/host-start.json` is a JSON Int64 containing the
first written screen PTS in host nanoseconds. It is written before track offsets,
so recovery can establish screen offset zero even before session.json is updated.

Review regressions cover full stop-time propagation, a delayed first frame at both
start and resume (including event timestamps), jittered 30/60 Hz cadence, double-rate
input rejection, dropping first/middle/last unreadable segments during recovery,
and input delivery timestamps converted from the CoreMedia host clock. Real input
delivery uses that clock directly instead of assuming units for CGEvent.timestamp.

Retina and multiple-display hardware are still needed to verify the tested point/
pixel and global-coordinate math against actual ScreenCaptureKit output.

## On-device transcription

`TranscriptionService().transcribe(package:localeIdentifier:track:)` writes
`recording/transcript.json`. A nil track prefers mic per segment, falling back to
system audio; `.microphone` and `.systemAudio` select one track explicitly. Word
ranges use the pause-removed source clock, including each audio track's start offset.
Finalization is atomic and retains `.prev`; errors/cancellation keep previous output.

The default tests inject recognized words, exercise real manifest/output IO and
test the recognition callback/cancellation/timeout races without Speech permission.
They are not evidence that Apple's recognizer decoded speech.

```sh
YAPCAM_TRANSCRIPTION_MEDIA_TESTS=1 swift test -j 4 --filter actualOnDeviceTranscriptionOfSaySpeech
```

That opt-in test runs `say` with Samantha into a temporary AIFF, requires nonempty
audio, transcribes it on device, and checks words/ranges/output. It must run on a
host where speech synthesis, local recognition models and Speech Recognition
authorization are available to the runner. It fails explicitly if a gate is missing.
The test never prompts. For app onboarding, Lead/UI must add
`NSSpeechRecognitionUsageDescription` and call
`TranscriptionService.requestAuthorization()` from an explicit user action.
