# Capture validation

Focus metadata is sampled at 4 Hz during each Mac recording segment, with an
immediate initial lookup. `focus` events include `app_bundle_id`, `app_name`,
`window_id`, `window_title`, and capture-local `window_rect` when available.
The frontmost application's first visible normal-layer WindowServer window is
the focus proxy; no Accessibility access is used. Window titles can be redacted
without Screen Recording permission. Browser page titles use the window title;
URLs are not queried. Changes shorter than 250 ms can be missed.

```sh
swift test -j 2 --filter FocusEventsTests
zsh Tests/YapcamCaptureTests/Tools/run_focus_poller.zsh
```

The five-second harness prints actual focus JSONL through the production poller
and event writer. It does not record pixels, activate windows, start an input tap,
or request permissions. Only its temporary event directory is removed. The unit
tests inject window dictionaries and cover identity/title changes, missing
metadata, background backpressure, late-result rejection, and journal mapping.

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
Terminate only a PID you personally started. Launch through `open -n -W` so TCC
attributes access to the signed app; direct executable launch attributes it to the
shell. The helper below refuses to launch while any Yapcam process is running, or
when process inspection fails. Never use `open` while another instance runs.
Run from a regular host terminal after building the signed app, one command at a
time. Helper arguments are target, fps, and optional pause-after seconds; `-W`
waits for the self-test app to exit:

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
    capture_target="${1:-display}"
    capture_fps="${2:-60}"
    capture_pause="${3:-}"
    set -- -n -W --env "YAPCAM_CAPTURE_SELFTEST_TARGET=$capture_target" --env "YAPCAM_CAPTURE_SELFTEST_FPS=$capture_fps"
    if [ -n "$capture_pause" ]; then
        set -- "$@" --env "YAPCAM_CAPTURE_SELFTEST_PAUSE_AFTER=$capture_pause"
    fi
    exec /usr/bin/open "$@" build/Yapcam.app --args --capture-selftest 8
)
capture_selftest display 30
capture_selftest display 60 3
capture_selftest area:100,100,800,600 60
capture_selftest area:100,100,800,600 30 3
capture_selftest window:com.apple.TextEdit 60
capture_selftest window:com.apple.TextEdit 30 3
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

NV12/HEVC capture dimensions are rounded down to even pixels (minimum 2 per
dimension) before both stream configuration and manifest publication. For example,
a 1627×1015-point window at scale 1 uses 1626×1014 pixels; at scale 2 it uses
3254×2030. Logical content rectangles and cursor coordinates retain their original
points. Regression tests cover odd/fractional window/area sizes at scales 1/2 and
the configured/manifest pixel size across window resize, scale change and resume.
For QA F8, rerun the guarded window command on an odd-sized window and compare
`tracks.screen.pixel_size` against ffprobe dimensions for every screen segment.

Every source kind writes `source.display_name`: display/area use the selected
display's localized name; window uses the display with the greatest intersection
with its frame. The shared metadata builder looks up that display's ID, retaining
the original logical rect/scale and window descriptors. If the display has no
available name, encoding writes `"Display"`. Missing names in older recordings
remain decodable and acquire that fallback on the next manifest write. Serialization
regressions cover display/window/area, selecting a non-primary display's name, and
legacy missing-name input. This is capture's side of Lead's F9 write-always/read-optional
decision; core's legacy-reader fallback and a new real window open need host validation.

## USB iPhone / iPad screen capture (limited: no connected device)

```swift
let devices = try CaptureSources.loadDeviceScreens() // no Mac screen discovery
// Show devices by id/name; an empty list means no supported device is connected.
let options = RecordingOptions(target: .device(selectedID), systemAudio: true,
                               outputDirectory: outputDirectory)
let session = RecordingSession(options: options)
```

The combined `CaptureSources.load()` also returns `deviceScreens: [CaptureDevice]`
and `deviceScreenDiscoveryError: String?`. The standalone throwing discovery is
usable without Mac Screen Recording permission; it does not request camera/mic
authorization. UI must request `.camera`, plus `.microphone` when device audio is
enabled, before starting. `systemAudio` controls the DEVICE audio for this target;
Mac microphone/camera options remain optional separate auxiliary tracks.

CoreMediaIO's process opt-in exposes screen capture devices; discovery accepts
connected external/muxed video devices, excludes Continuity Camera and ordinary
webcams, and deduplicates video/muxed listings by uniqueID. Identification uses
capabilities rather than a phone's user-editable name. Wireless screen discovery is
not enabled. Refresh on connect/disconnect or reopen the picker: hardware enumeration
can update after the opt-in. CMIO failure is surfaced rather than treated as no device.

AVCaptureSession video/audio outputs use its common synchronization clock, converted
to the same host clock used by the existing writer. Device video goes to `screen.mov`
(HEVC); its audio goes to `system.m4a` (AAC, native incoming sample rate/channels
persisted on first audio and at stop). First video anchors zero; audio preroll is discarded. Pause/resume,
fragment sidecars, low-disk handling and recovery use the existing package pipeline.
Unplug/runtime errors interrupt the primary capture and preserve finalized media.

Additive source format: `kind: "device"`, `device_id: <AVCaptureDevice.uniqueID>`,
`device_name: <localizedName>`, `display_id: 0` (compatibility sentinel), and
`display_name: <localizedName>`. The logical rect is `[0,0,videoWidth,videoHeight]`
with scale 1; device input pixels serve as its coordinate space. No Mac display is
associated. Mac cursor/key taps are disabled: `events.jsonl` and `cursors.json` are
valid empty journals, and no iOS touches are inferred. Rotation/resolution changes
that change the encoded size require a new recording; resume rejects changed sizes.

Tests inject discovery candidates/enable failures, no-device and permission errors,
primary disconnect, and real synthetic CMSampleBuffers for shared-clock video/audio
routing, audio start offset, actual audio metadata and changed-size rejection. An
opt-in real discovery check expects this fleet's empty device list:

```sh
swift test -j 4 --filter 'usb|USB'
YAPCAM_CAPTURE_DEVICE_TESTS=1 swift test -j 4 --filter actualUSBDiscoveryWithNoConnectedIOSDevice
```

With a real device, use the guarded `capture_selftest device:<uniqueID> 60` helper
above (LaunchServices, QA app lock and other-instance checks still apply). Verify
native dimensions, both HEVC/AAC tracks, duration/A/V sync, pause/resume, portrait
orientation, unplug handling and core/editor open/export. This is NOT yet verified
on an iPhone/iPad; no device is connected here.

Primary API contracts:
[CoreMediaIO screen-device opt-in](https://developer.apple.com/documentation/coremediaio/kcmiohardwarepropertyallowscreencapturedevices),
[AVCaptureDevice media capabilities](https://developer.apple.com/documentation/avfoundation/avcapturedevice/hasmediatype(_:)).

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

## Reference capture controls (CAP-1 / CAP-2 / CAP-3 / CAP-6)

The implementation uses behavior notes only; no reference assets or implementation
are used. `RecordingOptions.systemAudioSelection` is `.off` by default,
`.allApplications`, or `.applications(bundleIDs: [String])`. The compatibility
`systemAudio` Boolean still works, and explicit old saved Boolean values migrate.
`CaptureSources.applications` supplies stable checklist IDs/names; the audio stream
has its own application filter, independent of the recorded picture. Missing apps
or an empty checklist fail preparation rather than accidentally capturing all audio.
USB device targets accept all/off, not a Mac application checklist.

`cameraMaxResolution` is `.hd720`, `.hd1080` (default), or `.uhd4K`. This bounds
native webcam dimensions, preserves aspect ratio and never upscales.
`cameraFrameRate` is `.fps30` (default) or `.fps60`; it is independent of the
screen refresh rate, with a 30 fps fallback when an explicit 60 fps request is
unavailable. Fractional 29.97/59.94 modes keep their supported native clock
(manifest fps is nominal). No suitable format
means a warning and screen recording without camera. USB screen dimensions are
independent. Actual webcam dimensions/fps remain in the existing manifest fields.
Real format negotiation is unverified here because there is no webcam.

`RecordingSession.addMarker() throws -> RecordingMarker` works only while actively
recording, independently of captured keys/input permissions. UI binds the rebindable
marker action to this API. It synchronizes an event before returning:

```json
{"t":123456789,"type":"marker","marker_id":"a UUID"}
```

`t` is segment-relative ns; add `segment.src_start_ns` for source ns. Returned
markers include `id`, `segmentIndex`, `segmentNs`, `srcNs`. Recovery's existing
journal repair preserves complete marker lines inside recovered media and removes
truncated/out-of-range lines. Marker position follows the same pause/cut mapping
as other input events. Core now consumes these events directly through `Project.markers()` returning
`TimelineMarker` records (`markerID`, `segmentNs`, `srcNs`, `tlNs`, `clipID` and a
unique occurrence `id`). UI forwards its marker action to capture's `addMarker()`;
editor uses `tlNs` for edited display/snapping. Core maps cuts/speed/repeated source;
consumers should not calculate edited positions from the recorder's elapsed meter.
The capture module/test target remains independent of Core. Core's marker tests
on integrated main f611874 use the same marker_id event bytes, including resume.

`CapturePreflight.check(options:sources:)` returns typed issues for silent camera,
missing auxiliary inputs, denied/undetermined selected-input permissions, closed
lid with a built-in microphone, and invalid app-audio selection. A missing lid
sensor is unknown, not closed. No permission requests or machine settings changes
are performed. UI owns the confirmation/continue-without-input flow.
`windowResizeIssue()` checks Accessibility for the resize action only, since
ordinary window recording does not require it.

Hardware-free regression tests are in ReferenceCaptureTests, SessionLifecycleTests,
SelfTestOptionsTests and SegmentFailureTests. Genuine injected BGRA/PCM samples
verify that camera size changes (larger or smaller), wrong media, missing clocks
and invalid timestamps disable only the camera. Frames queued after a failure
cannot restart it; the screen/mic continue and a single warning is emitted. Native acceptance still requires the signed app, launch
rules above, real tones, a camera, and (for the lid check) a laptop.

The existing signed `--capture-selftest` accepts additional environment values:

- `YAPCAM_CAPTURE_SELFTEST_AUDIO`: `off`, `all`, or `apps:bundle.id,other.bundle.id`.
- `YAPCAM_CAPTURE_SELFTEST_CAMERA_MAX`: `720`, `1080`, `2160`.
- `YAPCAM_CAPTURE_SELFTEST_CAMERA_ID` / `YAPCAM_CAPTURE_SELFTEST_MICROPHONE_ID`: device unique IDs.
- `YAPCAM_CAPTURE_SELFTEST_MARKERS`: `1` writes a marker after start and after resume.

Pass these with `open --env` in the existing guarded helper, never by launching
Contents/MacOS directly. No override changes ordinary app preferences. Self-test
keeps its historical audio-on fixture default; ordinary new RecordingOptions are
audio-off. Test selected-app audio with distinct tones from two running apps and
verify the unselected tone is absent while both apps remain visible in screen.mov.
Repeat for window/area, all/off, and pause/resume. Camera: inspect camera.mov and
manifest for each cap, with 60→30 fallback and smaller hardware. Markers: expect one
journal event per segment, inside segment duration and independent of pause length.

Guarded host commands, from the repository root (read the output package path from
Yapcam's self-test log; replace app/device IDs with the discovered selections):

```sh
capture_gap_selftest() (
    if [ -e "$HOME/Movies/Yapcam/QA/.app-lock" ]; then
        printf '%s\n' 'QA owns the app; do not launch.' >&2; exit 1
    fi
    if pgrep -x Yapcam >/dev/null 2>&1; then
        printf '%s\n' 'Another Yapcam is running; do not launch.' >&2; exit 1
    else
        capture_probe_status=$?
        [ "$capture_probe_status" -eq 1 ] || exit "$capture_probe_status"
    fi
    capture_target="${1:-display}"
    capture_audio="${2:-off}"
    capture_camera_cap="${3:-1080}"
    set -- -n -W --env "YAPCAM_CAPTURE_SELFTEST_TARGET=$capture_target" \
        --env "YAPCAM_CAPTURE_SELFTEST_AUDIO=$capture_audio" \
        --env "YAPCAM_CAPTURE_SELFTEST_CAMERA_MAX=$capture_camera_cap" \
        --env 'YAPCAM_CAPTURE_SELFTEST_MARKERS=1' \
        --env 'YAPCAM_CAPTURE_SELFTEST_PAUSE_AFTER=3'
    if [ -n "${CAPTURE_CAMERA_ID:-}" ]; then
        set -- "$@" --env "YAPCAM_CAPTURE_SELFTEST_CAMERA_ID=$CAPTURE_CAMERA_ID"
    fi
    if [ -n "${CAPTURE_MICROPHONE_ID:-}" ]; then
        set -- "$@" --env "YAPCAM_CAPTURE_SELFTEST_MICROPHONE_ID=$CAPTURE_MICROPHONE_ID"
    fi
    exec /usr/bin/open "$@" build/Yapcam.app --args --capture-selftest 8
)
# Play different tones in Safari and a second app before selected-audio tests.
capture_gap_selftest display apps:com.apple.Safari
capture_gap_selftest window:com.apple.Terminal apps:com.apple.Safari
capture_gap_selftest area:100,100,800,500 apps:com.apple.Safari
capture_gap_selftest display all
capture_gap_selftest display off
# With CAPTURE_CAMERA_ID set to an attached webcam's actual unique ID:
# capture_gap_selftest display off 720
# capture_gap_selftest display off 1080
# capture_gap_selftest display off 2160
```

Each run includes pause/resume and two markers. Audio-off must not leave system.m4a;
app-selected output must contain only the chosen tone with no video exclusions
caused by the audio choice. Native success is not implied by parser/unit tests.

## Round 3: German/English speech files

These tests measure file processing, not microphone capture or user interaction.
The generator uses installed Anna/Samantha voices, original scripts with names,
spelled-out numbers and three fillers per language, and explicit 0.3–2 s pauses.
Each file must be 60–90 s. Clean, seeded white-noise and 10 dB SNR mixture stems,
known text, and PCM sentence-activity bounds stay outside Git. A successful `say`
exit with zero samples is a failure, not a speech fixture (observed in the sandbox).

From the repository root on the host:

```zsh
python3 Tests/YapcamCaptureTests/Tools/generate_speech.py \
  "$HOME/Movies/Yapcam/QA/speech/capture-round3"
zsh Tests/YapcamCaptureTests/Tools/run_speech.zsh --prepare-app \
  "$HOME/Movies/Yapcam/QA/speech/capture-round3-tool/Yapcam.app"
# This helper atomically claims QA/.app-lock, refuses any running Yapcam or
# SpeechHarness process (also refuses an unreadable process list), and uses
# LaunchServices. Never run Contents/MacOS/SpeechHarness directly for TCC testing.
zsh Tests/YapcamCaptureTests/Tools/launch_speech.zsh \
  "$HOME/Movies/Yapcam/QA/speech/capture-round3-tool/Yapcam.app" \
  "$HOME/Movies/Yapcam/QA/speech/capture-round3" --request-speech
python3 -B Tests/YapcamCaptureTests/Tools/speech_metrics.py \
  "$HOME/Movies/Yapcam/QA/speech/capture-round3"
```

`--request-speech` is an explicit host-only authorization action and may show the
Speech permission dialog. Omit it once access is granted. Missing/denied permission
returns an actionable error; the ordinary library/tests never prompt. An existing
derived package/result is not overwritten: each measurement run needs a fresh
fixture directory. If launch is interrupted, the helper retains the lock because
the app may still be running. Lead should remove it after confirming that this
particular harness has exited. No process is killed by either script.

The signed **debug** tool links the actual capture, core, render and editor modules
without launching the main UI or playing audio. It writes `speech-probe.json`,
per-language `outcomes.json`, capture `*-transcript.json`, lossless DSP derivatives,
and `metrics.json`. It measures both clean and noisy recognition, applies actual
`EditorModel` transcript cuts/filler removal/pause tightening to Rust-backed projects,
and verifies retained source ranges at their start/midpoint/end, as well as duration.
The player is a test double: no preview playback is claimed. Native AUSoundIsolation
failure is reported separately from render's deterministic DSP chain.

Metrics report WER substitutions/deletions/insertions (case/punctuation normalized;
no number normalization), expected/recognized/aligned fillers, and median/maximum
absolute sentence-boundary timing offsets with coverage. The timing truth is the
first/last 10 ms PCM activity window at -45 dBFS of each independently synthesized
sentence, **not** an invented alignment of its interior words. Report that limitation
alongside timing results. DSP reporting independently decodes output with ffmpeg:
input SNR from retained stems, gain-fitted SI-SDR before/after, input/output LUFS,
peak dBFS, clipping count and exact duration. SI-SDR includes speech distortion;
it is not a claim of isolated output noise power. Pumping/voice quality still need
Lead's listening check. No clipping and a good loudness number cannot prove it.

For offline acceptance, first complete authorization and local model installation,
then disconnect **all** network interfaces in macOS settings and confirm with
`scutil --nwi`. Copy only `clean.wav`, `noisy.wav`, `noise.wav`, `screen.mov` and
`ground-truth.json` for each language into a new external fixture directory, and
run the same guarded LaunchServices command there without `--request-speech`.
Retain the network-state output and reports outside Git. No network settings are
changed by these scripts. This run is pending on the host; the sandbox has no
Speech permission and cannot certify offline recognition. All production window
requests enforce `requiresOnDeviceRecognition = true`; no server fallback exists.
A native request without a final callback times out after 60 s, cancels its task,
and preserves the previously published transcript (deterministic regression tests).

Local deterministic checks, requiring no speech models or permissions:

```zsh
python3 -B -m unittest discover -s Tests/YapcamCaptureTests/Tools -p 'test_*.py'
zsh Tests/YapcamCaptureTests/Tools/run_speech.zsh --probe
zsh Tests/YapcamCaptureTests/Tools/run_speech.zsh --contract
swift test --disable-sandbox -j 4 --filter YapcamCaptureTests.OnDeviceSpeechPolicyTests
```

`--contract` uses explicit synthetic word times and the repository's synthetic video
fixture: it verifies the editor/core data path, not recognition accuracy. Temporary
tool/contract directories have cleanup traps/defers. The prepared signed app remains
outside Git for Lead; delete it when host checks finish. `YAPCAM_SPEECH_SKIP_BUILD=1`
reuses existing core/render/editor debug modules when SwiftPM is blocked by a native
run, but always recompiles the current capture sources into its temporary static
library. It never tests a stale capture API. Otherwise dependencies build normally.

When SwiftPM's build lock is held by a stalled native run, the built speech tests
can also run with the toolchain's `swiftpm-testing-helper` and the matching Xcode
framework/library paths. This follows [Swift Testing's command-line runner guidance](https://github.com/swiftlang/swift-testing/blob/main/Documentation/CommandlineDebugging.md).

### Round 3 addendum: keyterms and typed errors

The additive public API is:

```swift
try await TranscriptionService().transcribe(
    package: package, localeIdentifier: "de-DE", track: .microphone,
    keyterms: ["Yapcam", "Clara Weiß"])
```

`keyterms` defaults to `[]`; existing callers need no change. Each segment/window
forwards the array unchanged to `SFSpeechRecognitionRequest.contextualStrings`,
while retaining `requiresOnDeviceRecognition=true`. Keyterms are neither logged
nor written into transcript JSON. Forwarding is tested; an accuracy benefit from
contextual bias is **unmeasured** until the authorized native run.

`TranscriptionError.unsupportedLocale(String)` identifies a locale absent from
Apple's supported locale list. `TranscriptionError.onDeviceModelNotInstalled(String)`
identifies Apple's documented `kLSRErrorDomain` / `102` missing-assets callback.
Generic outages and `supportsOnDeviceRecognition=false` remain
`.onDeviceUnavailable(String)`: that Boolean alone does not prove missing assets.
See [Apple's task error table](https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/error)
and [offline-support semantics](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition).
The public service preserves these error types and the previously published
transcript. No model download, network fallback or permission prompt was added.

For a fresh debug build/test of current capture sources that does not use SwiftPM's
build lock, run:

```zsh
zsh Tests/YapcamCaptureTests/Tools/run_speech_policy_tests.zsh
```

This builds a temporary capture static library and runs the actual policy and
transcription regression files with Swift Testing; native opt-in checks stay
skipped. Its EXIT trap removes the library, module cache and runner after the run.

### F13: preserve earlier utterances and verify the native rerun

The native baseline on main 8bce820 retained only the end of a 45-second request.
Capture previously disabled interim results and extracted words only from the
final result. It now requests interim results and merges each timestamped hypothesis
into a per-window history: a revision replaces its overlapping suffix, and a later
utterance preserves the earlier prefix. The final callback publishes the merged
history. Each window has its own recognizer/history, and existing overlap ownership
still emits a boundary word once. Errors/timeouts still fail atomically. PCM goes
to Speech in independent packets of at most 4096 frames rather than one long buffer.

`SpeechRecognitionResultsTests` injects partial utterances across two windows,
with `isFinal` only on the last result, through the real recognition job and chunk
collector. It verifies words at 1/20/44.6/54/64 seconds, cumulative corrections,
no duplicate final callback/overlap, and byte-exact interleaved/planar stereo packets.
These regressions and full capture tests pass; native speech accuracy after the fix
must still be measured by Lead.

A fresh input-only rerun is already prepared under `~/Movies/Yapcam/QA/speech/capture-f13`.
A new signed debug tool is at `~/Movies/Yapcam/QA/speech/capture-f13-tool/Yapcam.app`.
From the capture worktree **on the host**, honoring QA's app lock:

```zsh
zsh Tests/YapcamCaptureTests/Tools/launch_speech.zsh \
  "$HOME/Movies/Yapcam/QA/speech/capture-f13-tool/Yapcam.app" \
  "$HOME/Movies/Yapcam/QA/speech/capture-f13"
python3 -B Tests/YapcamCaptureTests/Tools/speech_metrics.py \
  "$HOME/Movies/Yapcam/QA/speech/capture-f13"
```

Speech permission is already granted; no authorization flag is required. Do not
reuse a directory with derived packages: `prepare_speech_rerun.py SOURCE DESTINATION`
creates a new external input-only run using hard links (copy fallback), preserving
all prior measurements. It refuses an existing destination and cleans only its own
partial output if preparation fails.

F13's AUSoundIsolation status -10876 is `kAudioUnitErr_NoConnection`, distinct from
format errors and -10874 (too many frames). The offline AU still reports no input
connection on Lead's host. Capture maps it to an explicit unavailable message that
suggests Noise reduction / Podcast; it preserves the original and publishes no
purported enhancement. The host-connection repair is unverified. Those presets use
render's built-in high-pass/expander/compressor/normalizer/limiter, not this optional
Apple isolation unit. See status for the exact recipes and measured baseline.

Measurement fixes: FFmpeg may emit progress after the loudnorm JSON; parsing now
accepts that trailing output. True filler positions are labeled in generated truth;
the older fixtures infer the known sentence-leading hesitations. Dictionary matches
elsewhere are separate candidates (German `um halb zehn` is not a filler). In
addition to SNR/SI-SDR/LUFS/clipping, the report measures noise RMS in the final
second only when the clean stem proves silence. Positive reduction means less
noise; negative means more. None of these metrics certify absence of audible pumping.
# Round 5 capture parity and crash safety

`RecordingOptions.maxFPS` defaults to **0 = follow the initial display refresh**.
Explicit positive caps (including older30/60 callers) still work. The manifest
stores a resolved positive nominal rate; it stays fixed through pause/resume.
`DisplaySource.refreshRate` exposes the display mode rate, with maximum display FPS
as the fallback for dynamic/unknown modes. `recordKeystrokes` now defaults true,
but the session enables key capture only when Input Monitoring is granted;
explicit false saved options remain false. System audio still defaults off.

`CaptureWindowControl.resize(windowID:to:)` modifies the real window with public
Accessibility APIs and returns refreshed **logical point** bounds. Permission,
ambiguous target, nonresizable window and app-clamped size are explicit errors.
`CaptureWindowSizePreset.fitting(in:)` lists exact sizes that fit, without scaling
the advertised size. Live resizing needs an authorized GUI host; injected tests
cover app refusal/readback and negative display coordinates.

The writer requests HEVC quality0.85 for screen and0.6 for camera, frame interval
2×fps plus2s duration, fragmented output about2s. Live writers retain one last
screen image and retime it at1Hz when there are no new complete screen frames, so
a static source can also close fragments. Heartbeats do not advance real-frame
ordering or cadence: if a newer real frame arrives with a PTS just behind an
already-written heartbeat, its pixels are retained and its output PTS is moved
1ns past that heartbeat. Background disk checkpoints are coalesced
to one pending flush; markers flush before acknowledgment and stop waits for a
final flush. Sudden loss can discard the in-flight fragment. This does not certify
power-failure behaviour on every filesystem/storage device.

All capture unit tests, built fresh without using a locked SwiftPM directory:

```sh
zsh Tests/YapcamCaptureTests/Tools/run_capture_tests.zsh
```

Strict **native encoder/decoder + SIGKILL** regression, no app/window/TCC access:

```sh
zsh Tests/YapcamCaptureTests/Tools/run_crash_recovery.zsh
```

The signed standalone CLI writes injected64x64 screen and camera samples into real
fragmented HEVC MOVs, waits for complete fragments, kills **only its own child PID**
with signal9 at three seeded media times (one static-source case), recovers the
unfinalized package, checks at most2.1s of missing tail, reads actual decoded images
with monotonic timestamps, validates source origin/events/marker and media integrity.
It never finalizes the killed writer. Native failure is a failure, never a portable
pass/skip. No physical camera or microphone is used. All own fixture/build temp
directories are listed and deleted by cleanup traps. No media is committed.
Sandboxed native encoder failure (-12903) requires this command to run outside
the sandbox; unit tests do not establish native HEVC quality acceptance or crash
recovery. `CAPTURE_SIGKILL_PASS` lines are the required native evidence.


## R5b consumer handoffs

- `@MainActor CameraFormatPolicy.effectiveSize(deviceID:maximum:fps:)` is a
  read-only optional `(width: Int, height: Int)` query. `fps` defaults 30, with the
  same 30/29.97 behavior as recording; pass 60 for an explicit high-rate camera. Uses actual
  connected camera formats and the production cap/rate chooser. nil means no
  permission/device/compatible mode; no prompt, capture session or device mutation.
- `TranscriptionService.supportedLocales() -> [Locale]` returns the native Speech
  recognizer list in identifier order. It does not mean on-device assets are
  installed; transcribe still throws typed locale/model/unavailable errors. UI can
  replace its direct Speech query with this shared API without changing its picker.
- `recording/seg-XXX/cursors.json` entries gain optional `shape`: `arrow`, `pointing_hand`,
  `text`, `resize_horizontal`, `resize_vertical`, `resize_diagonal_nwse`,
  `resize_diagonal_nesw`, `open_hand`, `closed_hand`, `crosshair`, `not_allowed`.
  A shape is emitted only for an observed standard AppKit object identity. An
  image-equivalent custom object, unknown snapshot or absent system observation
  omits it; dedup keys include provenance, so identical PNG bytes cannot cause an
  unknown cursor to inherit an earlier standard tag. PNG/hotspot/size stay intact.
  **Public AppKit does not guarantee semantic identity across processes**; tags
  may be sparse/absent in real recordings. No numeric/private cursor API or bitmap
  classification is used. Native cross-app identification coverage is unverified.
- Desktop icons already use `RecordingOptions.hideDesktopIcons` (defaultfalse)
  and the ScreenCaptureKit filter. UI must forward its toggle instead of modifying
  Finder preferences. Display/area captures share the filter; normal Finder folder
  windows remain visible. A desktop-independent window capture has no desktop
  icons to remove. This API needs no Finder restart/restoration.

`CursorMetadataTests` inject retained object identities and CPU artwork snapshots
for the journal test (native cursor objects/rasterization are unavailable in the
standalone sandbox runner). They prove metadata/provenance, not global WindowServer
recognition, and never set the user's cursor.
`IncomingRequestTests` exercise format cap/rate/no-device selection and compare
locale enumeration against the native recognizer without requesting authorization.
Run the capture-only test script above; native codec certification belongs to Lead.
Native Speech inventory is opt-in: `YAPCAM_CAPTURE_LOCALE_TESTS=1 zsh Tests/YapcamCaptureTests/Tools/run_capture_tests.zsh`.
It passed in an earlier standalone run, but the later SwiftPM suite stalled in
sandbox (no cause proven), so service inventory stays outside default regressions.
It does not request Speech authorization or download models.
