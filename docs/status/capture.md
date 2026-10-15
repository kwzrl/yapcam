READY 5d7fe82 + WORKTREE round-2 C1 no-speech window recovery/warnings; 97 capture tests, native say host gate pending
READY a52fc4a AUD-06 groundwork / PCM file tests; native model host gate pending
READY 63f4abb package 1 AUD-10 implementation/unit tests; real Speech host gate pending
READY 63f4abb package 2 injected-fault verification; unit tests pass
READY 63f4abb package 3 scale/multi-display geometry; math tests pass

# capture status

## Current handoff
- Audit 2026-10-15 03:09 CEST: C1 remains ready in the worktree, awaiting checkpoint
  and re-review; main remains 78a8a0e. No new capture finding or host Speech/isolation
  result. Capture implementation is unchanged since validation; no tests/Git writes
  repeated under the existing metadata restriction.
- Round-2 C1 implemented/unit validated before new features: retain spoken windows
  around no-speech errors and return/persist partial-result warnings. Only the exact
  native no-speech domain/code is recoverable; other failures preserve previous JSON.
- Validation 2026-10-15 03:02 CEST: main 78a8a0e export + owned changes builds/signs,
  Rust 61 pass; isolated capture target 97 tests / 5 opt-in skips / zero failures.
  Final main-based full Swift run also has no capture failure; host gates below.
- AUD-06 Apple voice isolation groundwork implemented/unit validated. Prior AUD-10,
  fault and geometry packages are implemented and integrated; native Speech remains
  a host gate. Added VoiceIsolationService.swift, VoiceIsolationTests.swift and README.
- Native Speech and isolation quality/alignment remain unverified; do not mark those
  features verified from unit tests or the independent review's software results.
- Package 1 files: Sources/YapcamCapture/{TranscriptionService,AppleOnDeviceSpeech}.swift,
  Tests/YapcamCaptureTests/TranscriptionTests.swift, tests README and this status.
- Observed local HEAD 5d7fe82 (parent 88f1995), main 78a8a0e. Lead continues to handle
  commits/rebase/push under read-only Git. Pending C1 files: AppleOnDeviceSpeech.swift,
  TranscriptionService.swift, TranscriptionTests.swift, tests README and this status.
  Only capture-owned source/tests/status changed; no new dependencies.

## Round-2 C1 — no-speech window recovery / implementation verified
- Preserve native NSError domain/code through SpeechRecognitionJob. Only
  kAFAssistantErrorDomain / 1110 is recovered as an empty window. Continue sequential
  recognition and keep earlier/later words; denial, timeout, decoding and other errors
  remain fatal. Cancellation takes precedence even if it races a no-speech callback.
- RecordingTranscript now exposes warnings and computed isPartial. Warnings are
  persisted atomically alongside usable words and logged through OSLog; UI should
  display their messages before importing captions (outside capture ownership).
- Additive optional schema-1 warnings array: each object has code=no_speech_detected,
  message, src_start_ns, src_end_ns, segment_index and track (mic/system_audio).
  Ranges cover the failed window's disjoint ownership interval, not its overlap;
  map through the same segment/track offsets as words and clip at the segment end.
  Older JSON decodes with warnings=[]; successful warning-free JSON omits the key.
  Lead: add this optional extension to FORMATS.md. Core's current word importer
  already ignores additional transcript fields, so caption import stays compatible.
- Four default regressions: spoken/error-1110/spoken with correct persisted warning;
  unrelated domain/code stays fatal and preserves current output; cancellation
  after no-speech; all-no-speech + source clipping + older JSON compatibility.
- Two say opt-in tests build a CAF with speech at 2 s and 92 s, leaving the entire
  44–89 s request silent. One uses actual file decoding and injected callback 1110;
  the other uses real on-device recognition. Successful native [] for silence is
  also valid (no error to recover); deterministic injection guarantees C1 coverage.
- Actual say tests attempted: both fail explicitly because say produces no usable
  speech frames in this sandbox. Host command is in README; log
  /tmp/yapcam-c1-say-attempt.log. Real synthesis/recognition is not claimed verified.
- Signed scripts/build-app.sh + strict codesign verification pass on main 78a8a0e
  export + owned files. Rust 61 pass. Full Swift attempt: Swift Testing 236 tests /
  31 issues (29 editor Metal-preview, 2 UI missing snapshots); XCTest 91 tests /
  31 skips / 6 E2E Metal failures. No capture issue; no all-green full-suite claim.
  Logs: /tmp/yapcam-c1-{app-build,capture,full-swift,rust}.log. Source/test gitleaks
  and git diff --check pass; no media/credentials/dependencies added.
- Lead/UI: surface RecordingTranscript.warnings (isPartial) to the user before
  encoding/importing captions; OSLog also reports partial results. No UI visibility
  claim is made from this capture-only change. Suggested checkpoint title:
  fix(capture): retain transcript around no-speech windows and expose warnings.
- Latest UI worktree now installs EditorWindows.transcriber and includes the Speech
  usage key (AppDelegate.swift / Resources/Info.plist; also reported in UI status).
  It currently encodes the returned transcript directly; add warning presentation
  before that encoding. Main 78a8a0e does not yet include the usage key, so this is a
  pending cross-team integration, not a capture implementation blocker.

## AUD-06 groundwork / assumptions and current evidence
- Use Apple's public AUSoundIsolation effect (standard voice, 100% wet) through
  AUAudioUnit in offline mode. AVAudioEngine VoiceProcessing explicitly requires
  device rendering; SoundAnalysis classifies audio rather than producing cleaned PCM.
  Public effect contract: https://developer.apple.com/documentation/audiotoolbox/kaudiounitsubtype_ausoundisolation.
- Intended API: VoiceIsolationService().processFile(micURL, to: optionalAdjacentCAF).
  Default mic.voice-isolated.caf, lossless Float32 48 kHz, mono/stereo; streamed 4096
  frame buffers, one duration rounding, reported AU latency removed, silence flush.
  Original and session manifest remain unchanged; no prompt/playback/network fallback.
- Core/render: use the derivative only after successful return; retain original mic
  track_start_ns and source clipping. Selecting/persisting enhanced media is your
  integration step, not an automatic mutation of required session keys.
- Publication uses fsync + exclusive hard link, preserving a competing destination.
  Cancellation/error removes temporary output; native effect absence is explicit.
- Public VoiceIsolationReport returns output URL, engine apple_au_sound_isolation_voice,
  sampleRate, channels, frames and compensatedLatencyFrames. Output length is
  round(original decoded frames * 48000 / original sample rate); no accumulated
  per-block rounding. Preserve original file-local time zero and mic track offset.
- No required session.json keys or project edits are introduced. Core/render should
  explicitly register/select the successful derivative as media, preserve original
  source ranges/offsets and invalidate it if the original is relinked/changed. Merely
  seeing an adjacent file is not a persisted user choice. Original mic stays available.
- Render's current P4 status confirms its separate original DSP helper is implemented
  but does not provide model-based isolation. The Apple isolation output can be an
  explicit input to that helper if core/editor elect to chain isolation and mastering.
  At 02:48 its status reports shared preview/export DSP integration commit-ready
  through optional render settings. Core persistence/editor toggle and native Apple
  isolation acceptance remain separate; this does not verify the isolation model.
- Sandbox AudioComponentFindNext returns no Apple effects. A direct AVAudioUnitEffect
  initializer probe crashed on that absence; production uses discovery plus the
  throwing AUAudioUnit initializer instead. Native quality/alignment is unverified.
- Validation 2026-10-15 02:08 CEST: isolated capture target 91 tests, 3 media skips,
  zero failures. Ten new isolation tests (one opt-in): mono/stereo exact PCM alignment
  at 0/137/5000 frames of latency; 16/44.1/96 kHz duration and waveform phase; invalid
  latency/input; nonfinite/error/cancellation cleanup; destination race; absent AU.
  Fixed EOF handling (AVAudioFile read after EOF can throw nilError) and the empty
  latency-window offset. Fixtures are serialized: concurrent native file/converter
  initialization stalled; all individual cases and serialized suite pass.
- Final actual main f640b35 export + owned files: signed scripts/build-app.sh passes,
  codesign --verify --strict passes. Rust 56 tests pass. Full Swift attempted:
  Swift Testing 210 tests / 24 issues (22 editor Metal preview unavailable, 2 UI
  snapshot missing-output issues); XCTest 75 / 26 skips / 6 E2E Metal failures.
  All capture tests including final resampler waveform assertions pass in that run.
  Full-suite log: /tmp/yapcam-isolation-full-suite.log. No all-green host claim.
- Native opt-in quality test was attempted, failing explicitly because say generated
  no speech frames; log /tmp/yapcam-isolation-native-attempt.log. README gives the
  authorized-host command and 6 dB noise-RMS + speech-energy checks. Listening,
  intelligibility and real AU latency alignment require host acceptance/review.
- Earlier pre-serialization SwiftPM capture run stalled (PID 75979, original temp
  export .build). Sandbox denies signalling that process; Lead please terminate that
  test runner and its children. Subsequent runs used bounded process-group watchdogs
  and separate scratch paths; the final full-suite attempt completed normally.
- Source/test gitleaks scans and git diff --check pass. No dependencies or media
  fixtures committed. VoiceIsolationService.swift, VoiceIsolationTests.swift, README
  and the prior status are checkpointed in a52fc4a. Only this status update is pending;
  Lead handles push and independent review.

## Package 1 — AUD-10 implementation / unit validation complete
- Public actor TranscriptionService: transcribe(package:localeIdentifier:track:)
  returns RecordingTranscript and atomically writes recording/transcript.json.
  Locale defaults to Locale.current.identifier. nil track prefers mic per segment,
  otherwise system audio; explicit .microphone/.systemAudio never switches tracks.
- Uses SFSpeechRecognizer for macOS 15 compatibility. Requires authorization,
  supportsOnDeviceRecognition and availability, then sets requiresOnDeviceRecognition
  on every request. Unsupported/missing local recognition returns an explicit error;
  there is no server fallback. Apple contract:
  [Apple on-device contract](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition).
- Long audio uses bounded 45 s PCM windows with 1 s overlap. Midpoint ownership
  partitions the overlap, avoiding duplicate words. Each request has a 60 s watchdog;
  timeout/cancellation cancels the native task and resolves its continuation once.
- Only finalized schema-1 packages with contiguous source segments are accepted.
  Advisory package lock excludes live capture/recovery and concurrent transcription.
  Unsafe/symlink-escaping paths are rejected. Failures/cancellation preserve previous
  transcript; successful replacement uses fsync/atomic rename with transcript.json.prev.
- Regressions: mic/system selection, pause removal + first-track offsets, stop clipping,
  invalid/overflow word times, confidence sanitization, JSON round trip, previous-file
  preservation, cancellation, active/unfinished packages, escaping paths/symlinks,
  bounded/contiguous chunk ownership, duplicate final callbacks and timeout cleanup.

## Transcript format — request for Lead / FORMATS.md
Optional UTF-8 recording/transcript.json, with no change to required session keys:
```json
{"schema_version":1,"engine":"apple_speech_on_device","locale":"en-US","words":[{"text":"Hello","src_start_ns":100000000,"src_end_ns":500000000,"confidence":0.9,"segment_index":0,"track":"mic"}]}
```
- words are ordered by src_start_ns; ranges are [src_start_ns, src_end_ns), signed
  nonnegative Int64 nanoseconds in the pause-removed source clock. Compute each as
  segment.src_start_ns + segment.track_start_ns[track] + recognized file time.
  Clip words at the finalized segment end; discard invalid/empty/out-of-range words.
- track is mic or system_audio; segment_index is the session segment index.
  confidence is finite in [0,1]. text preserves Apple's recognized word/utterance
  segment (no invented token timing). locale records the requested recognition locale.
- Empty words is a valid successful no-word result. No-speech windows may publish
  usable words plus the optional warnings documented above. Other recognition errors
  abort the whole update. Unknown newer schemas must be
  refused by consumers. transcript.json.prev is optional previous-version fallback.
- Existing files remain untouched except transcript.json/.prev and the metadata-free
  advisory .capture.lock. No absolute audio paths or recordings are embedded in JSON.

## Prior AUD-10 / fault / geometry validation and host gates
- Temporary export main 6d91a7f + owned source/tests at
  /tmp/yapcam-transcription-main.pnEG9w: scripts/build-app.sh passes, signature verified
  as Yapcam Dev Signing / mov.yapcam.Yapcam. External Swift shim adds --disable-sandbox
  and -j 4; CARGO_BUILD_JOBS=4. No tracked build/manifest edits.
- Capture suite after all packages: 81 discovered, 2 explicit media skips, zero
  failures. 15 transcription tests (one opt-in real test; path cases parameterized).
  Final audit also checks cancellation after recognition has actually started.
- Rust: 39 passed. Full integrated Swift attempted: Swift Testing 172 tests with
  18 editor issues (all Metal preview unavailable); XCTest 54, 22 hardware skips,
  6 E2E failures (all Metal unavailable). Not a green full suite; host run required.
- Lead reports baseline main 6d91a7f green on the host (151 Swift + 54 XCTest +
  39 Rust; strict render hardware 43/43) in docs/STATUS.md. Those results predate
  checkpoint 63f4abb and do not verify its Speech service or new regressions.
- Real synthetic-speech test was actually attempted with
  YAPCAM_TRANSCRIPTION_MEDIA_TESTS=1 and actualOnDeviceTranscriptionOfSaySpeech.
  Speech preflight reported denied. say Samantha and Fred each exited 0 but created
  zero-frame AIFFs (afinfo: audio bytes/packets 0). Opt-in test fails explicitly on
  empty generated audio. Real synthesis/recognition is NOT verified here.
- Lead/UI: add NSSpeechRecognitionUsageDescription to the signed app Info.plist.
  TranscriptionService.authorizationState is read-only; requestAuthorization()
  is explicit, validates the usage key, and must be called from a user action.
  transcribe() and tests never prompt. The authorized host runner also needs local
  speech assets/services; README contains the real say test command.
- git diff --check and gitleaks source/test scans pass. No sudo, permission reset,
  recordings, credentials or third-party dependencies added. Lead checkpointed all
  packages; independent review remains (especially native-task cancellation/chunk mapping).

## Package 2 — injected fault verification complete / integrated
- Existing production-coordinator tests verify mid-recording diskFull, revoked screen
  permission and disappearing-source callbacks: interrupted manifest, finalized
  prior screen data, exactly-once stream/writer cleanup and released package lease.
- Added full-session optional-device-loss injection: both device tracks start, mic
  meter rises, mic/camera disappear, warnings occur once, meter resets, future device
  samples are rejected while screen samples continue, and stop completes normally.
  Assertions cover sample counts, retained files, finalization counts and lock release.
- Added low disk before start (no package/stream) and permission revoked during pause
  (resume fails while the finalized earlier segment is preserved).
- Only SessionLifecycleTests.swift changes relative to package 1. Suggested commit:
  test(capture): verify injected device loss and lifecycle failure cleanup.
- Main 6d91a7f validation export: capture suite now 76 discovered, 2 media skips,
  zero failures. Signed app/Rust validation from package 1 is unchanged (test-only).
  Test sinks exercise routing and coordinator behavior; they do not encode media.

## Package 3 — geometry math verification complete / integrated
- Extracted the display-local area validation/global-coordinate conversion into
  CaptureGeometry.area(), used directly by the production resolver. Existing valid
  selection behavior is unchanged; tests do not request ScreenCaptureKit access.
- Four new tests (three parameterized at scales 1 and 2): areas on primary/left/above
  displays, windows with positive/negative global origins, cursor positions including
  outside content, resized windows crossing scales fitted to the initial surface,
  and invalid global/pixel/overflow/nonfinite area selections.
- Files: CaptureGeometry.swift and GeometryMatrixTests.swift. Suggested commit:
  test(capture): cover window and area geometry across display scales.
- Signed app build/signature rechecked after this production refactor; all capture
  tests pass. This is math-only evidence; real Retina/multi-display checks remain open.

## Existing capture handoffs retained
- Main FORMATS.md now specifies import_transcript consuming RecordingTranscript JSON
  and says track offsets must not be applied a second time. Editor's current worktree
  reports caption import/list/lane implemented with EditorWindows.transcriber as the
  app injection hook; real transcription/UI wiring and host permission remain pending.
  Editor now reports 226 full-suite tests green after a clean/rebuilt app; this is
  other-team validation and does not establish native Speech/isolation quality here.
- Round-2 independent review confirms all round-1 capture fixes, including H2/H3,
  cadence and recovery numbering. It reports a successful static-tail reader probe
  at 3 s in a file ending at 5 s. Real startup/resume flash and live input alignment
  remain hardware/permission acceptance checks; C1 is the new capture finding.
- Lead / FORMATS.md: optional seg-XXX/track-starts.json maps track keys to start offsets
  (new screen=0); optional seg-XXX/host-start.json is the absolute first written screen
  PTS as JSON Int64. Write host origin before offsets so recovery fixes a stale manifest.
  Also document optional recording/.capture.lock (empty advisory file, not metadata).
- Latest confirmed UI handoff: self-test flag, recovery prompt and editor open wired.
  Icon/notification forwarding through RecordingOptions still needs UI alignment;
  use stream filtering rather than Finder preference changes/restarts.
- Real capture remains gated by the current signing identity's Screen Recording grant
  (UI/QA reported SCStream -3801). No camera/mic; one non-Retina display. Unit/simulated
  checks do not establish real device sync/loss, Retina or multi-display acceptance.

## Next / Lead requests
1. Checkpoint C1's five owned files, rebase/advance this worktree to main and push
   under the agreed read-only Git workflow. Prior packages are integrated. No other
   independent capture implementation item remains in the current assignment.
2. Re-review C1's error classification and warning schema/clock mapping. Round-1
   findings are confirmed fixed by round-2 review. Run the full Swift suite on the
   host; sandbox editor/E2E/UI failures are not fixed or hidden by capture.
3. Integrate UI's usage key and production transcriber hook, present C1 warnings,
   then rerun the opt-in say tests on an authorized host with local models. UI already
   implements permission request + JSON encoding in its worktree; real Speech remains
   unverified. Append host results here; capture will address findings.
4. Add transcript JSON including optional C1 warnings and existing timing sidecars/lock
   to FORMATS.md; expose the warnings in the app's caption flow.
   Core already documents source-time import; complete consumer integration is outside
   capture ownership. QA should reconcile AUD-10 and fault/geometry rows
   from this evidence without marking real recognition or capture as verified.
5. Core/render: integrate explicit enhanced-mic selection using the AUD-06 contract
   above. Lead arrange real AUSoundIsolation noisy-speech and latency acceptance on
   the host; append findings here. UI must expose unavailable errors until supported.
