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

### Signed-app window / area / pause commands

The existing app handler reads these optional environment switches inside
`CaptureSelfTest.run`: `YAPCAM_CAPTURE_SELFTEST_TARGET` (`display`, `window:<id>`,
`window:<bundleID>`, or `area:x,y,width,height` on the first display),
`YAPCAM_CAPTURE_SELFTEST_FPS` (30/60), and `YAPCAM_CAPTURE_SELFTEST_PAUSE_AFTER`
(positive seconds below the recording duration). Rectangles use display-local
points. A missing window or invalid option fails explicitly. Open a disposable
TextEdit document for the window cases; a bundle selector picks its first available
window. Numeric window IDs let the host choose a specific window.

All builds share `mov.yapcam.Yapcam`. Before every launch, check
`~/Movies/Yapcam/QA/.app-lock`: when present, QA owns the app; do non-live work until
it is gone. Never quit another Yapcam instance or use process-name kill commands.
Terminate only a PID you personally started. Do not use LaunchServices `open` for
these tests; it can reuse/activate another instance. The helper below also refuses
to launch while any Yapcam process is running, or when process inspection fails.
Run from a regular host terminal after building the signed app, one command at a
time; direct execution waits for that self-test process to exit:

```sh
capture_selftest() (
    if [ -e "$HOME/Movies/Yapcam/QA/.app-lock" ]; then
        printf 'QA owns Yapcam; skipping live test.\n' >&2; exit 1
    fi
    if pgrep -x Yapcam >/dev/null 2>&1; then
        printf 'A Yapcam instance is running; skipping live test.\n' >&2; exit 1
    else
        capture_probe_status=$?
        if [ "$capture_probe_status" -ne 1 ]; then
            printf 'Cannot inspect running apps; skipping live test.\n' >&2; exit 1
        fi
    fi
    exec env "$@" build/Yapcam.app/Contents/MacOS/Yapcam --capture-selftest 8
)
capture_selftest YAPCAM_CAPTURE_SELFTEST_FPS=30
capture_selftest YAPCAM_CAPTURE_SELFTEST_PAUSE_AFTER=3
capture_selftest YAPCAM_CAPTURE_SELFTEST_TARGET=area:100,100,800,600
capture_selftest YAPCAM_CAPTURE_SELFTEST_TARGET=area:100,100,800,600 YAPCAM_CAPTURE_SELFTEST_FPS=30 YAPCAM_CAPTURE_SELFTEST_PAUSE_AFTER=3
capture_selftest YAPCAM_CAPTURE_SELFTEST_TARGET=window:com.apple.TextEdit
capture_selftest YAPCAM_CAPTURE_SELFTEST_TARGET=window:com.apple.TextEdit YAPCAM_CAPTURE_SELFTEST_FPS=30 YAPCAM_CAPTURE_SELFTEST_PAUSE_AFTER=3
```

Results/package paths are in `~/Library/Logs/Yapcam/probe.log`. Check complete status,
no `.capture.lock`, screen offset zero, HEVC dimensions and AAC/event timestamps for
each package. Pause cases must have two contiguous source segments; the 0.5 s pause
must be absent from source duration. On this scale-1 host the area is 800×600 pixels.
Move/resize TextEdit during the window run and its pause; encoded dimensions stay
fixed to the initial window surface. Inspect startup/resume frames for a blank flash,
and verify a static tail decodes through the stop time. Do not infer these live
properties from the parser or injected lifecycle tests.

An advisory `recording/.capture.lock` excludes a live/paused recording from
recovery. Normal lease release removes the file while still locked (including
clean stop, recovery and transcription); process death releases the OS lock but can
leave the empty file for the next owner to reclaim. Acquisition verifies the locked
inode is still at the path, and release never unlinks a replacement inode.
`seg-XXX/track-starts.json` is an optional
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
Apple's specific no-speech error (`kAFAssistantErrorDomain`, 1110) is recoverable per
45 s window: keep words from the other windows and publish `warnings` with code
`no_speech_detected`, message, source-time range, segment index and track. Ranges
use the failed window's disjoint ownership interval (the overlap belongs to its
neighbors), clipped to the segment end. `RecordingTranscript.isPartial` reports
whether warnings exist; callers should show their messages before importing words.
A partial-result warning is also logged through OSLog. Other recognition errors,
timeouts and cancellation still abort without replacing the old transcript.
Legacy schema-1 JSON without warnings decodes to an empty array; successful results
without warnings omit the JSON key. Core's word importer remains compatible.

The C1 regression injects native callback error 1110 between two spoken windows and
checks both words, offsets, warning persistence and legacy decode. Additional tests
keep unrelated native domain/codes fatal and verify cancellation after no-speech.
For the real 45-second silence fixture generated with `say`:

```sh
YAPCAM_TRANSCRIPTION_MEDIA_TESTS=1 swift test -j 4 --filter SilentWindowSpeechMediaTests
```

One test reads the generated spoken/silent/spoken CAF through the production decode
and window path, injecting 1110 only for the entirely silent window. The other uses
the actual on-device recognizer. Some OS/models return successful empty words for
silence instead of 1110; that result needs no warning. Both tests require working
speech synthesis; the native test also requires Speech authorization/local assets.
They fail explicitly on a missing prerequisite and never request permission.

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

AUD-06 voice-isolation groundwork: `VoiceIsolationService().processFile(micURL)`
creates `mic.voice-isolated.caf` beside the original, using Apple's AUSoundIsolation
voice effect in offline mode. A new adjacent CAF path can be passed with `to:`.
No microphone permission or audio device is needed. Missing effect registration,
unsupported native formats or model/resource errors fail explicitly; there is no
copy-through fallback. Call only after recording stops. Consumers retain the
original mic track start offset; the output is 48 kHz Float32 with the original
file-local duration and declared AU latency trimmed. The original/manifest are
unchanged; selecting this derivative in core/render is a separate integration step.

Default tests use actual PCM CAF input/output and an injected delay/failure kernel:
mono/stereo sample alignment, resampling duration, exclusive publication, invalid
input, nonfinite output and cancellation cleanup. These tests do not measure Apple's
model. Run the real model test outside the sandbox on a host with Apple Audio Units:

```sh
YAPCAM_VOICE_ISOLATION_MEDIA_TESTS=1 swift test --filter actualAppleVoiceIsolationReducesNoiseAndRetainsSpeech
```

This generates temporary speech with `say`, mixes deterministic noise, runs the
native effect, checks quiet-region noise RMS falls by at least 6 dB, retains nonzero
speech-region energy, preserves frame count and leaves the original unchanged.
It fails when synthesis/effect support is unavailable. Listening quality and native
latency alignment still need independent host acceptance; energy is not an
intelligibility measurement.

## M3 hour / crash hardening

```sh
swift test -j 4 --filter LongSessionTests
YAPCAM_CAPTURE_MEDIA_TESTS=1 swift test -j 4 --filter NativeFragmentTests
```

The default hour test advances timestamps rather than sleeping: 216,000 screen
buffers at 60 Hz, mic/system PCM, and 46,800 real event-log rows. Production routing,
sidecars, event recording and recovery run unchanged. The injected media sink writes
an explicitly tagged `SIMCAP01` fragment ledger, not fake playable media. Its sizes
are exact test-record sizes, not HEVC/AAC bitrate estimates. One hundred seeded
crash snapshots include torn fragments/events/manifests and check recovery duration,
source/host offsets, exact event prefixes, `.prev`, locks and idempotence. Crashes
before the first completed fragment preserve originals and fail explicitly.

The opt-in native test injects a one-hour **media clock** at sparse 1 Hz into the
actual HEVC writer, retrying test input on encoder backpressure. It checks the real
MOV's fragment count, file bounds, duration, compressed-sample PTS and keyframes.
It needs VideoToolbox/AVFoundation services but no Screen Recording grant. It is not
a sustained 60 fps throughput test; the ordinary simulation cannot establish native
fragment durability, power-loss behavior or real storage requirements. Native failures
are explicit. No generated media is checked in; all fixtures use temporary storage.
Apple's fragmentation and atom contracts:
[AVAssetWriter fragments](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval),
[QuickTime atoms](https://developer.apple.com/documentation/quicktime-file-format/atoms).

## Temporary build directories

Every capture validation script that creates a temporary repo, harness or cache must
install cleanup traps before allocating it. Keep all run artifacts inside that one
directory, run children synchronously, and terminate/wait for timed-out children
before exiting. Preserve small logs separately when needed. For example:

```sh
#!/bin/sh
set -eu
capture_run_root=
capture_cleanup() {
    if [ -n "$capture_run_root" ]; then
        printf 'Removing capture temp directory: %s\n' "$capture_run_root"
        rm -rf -- "$capture_run_root"
    fi
}
trap capture_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
capture_run_root="$(mktemp -d "${TMPDIR:-/tmp}/yapcam-capture-run.XXXXXXXX")"
# Put the run's repo/harness, build output and caches under "$capture_run_root".
# Run the validation here in the foreground.
```

Swift fixtures use `defer` to remove their temporary directories. For abandoned
script runs, list exact paths and establish capture ownership and absence of active
users before deleting them. Shared names such as `tmp.*` do not establish ownership.
