READY 9b0cadc capture LOCAL implementation backlog empty; consumer wiring and native acceptance remain external
READY 9b0cadc CAP-2/M3 camera sample failure hardening; 136 capture tests + Rust + signed build pass; native gates remain
READY 9b0cadc CAP-1 per-app system audio + CAP-2 webcam resolution caps; capture tests/signed build pass; full-suite host gate
READY 9b0cadc CAP-3 durable recording markers + CAP-6 preflight API; signed build/capture tests pass; UI/native gates
READY 8c3345e USB iPhone/iPad source/API; build + 118 tests, LIMITED (no physical device)
READY 4817b58 F9 always-write containing display_name; signed build/unit verified; Lead reports fixed
READY f400c3e QA F8 even-size pixel metadata; unit verified + QA native pass on 3b68bde
READY a3a51ad clean-finish lock cleanup / signed-app live variants; host checks pending
READY 7383d08 M3 hour simulation / 100 crash trials / capture limits; native MOV hour host gate pending
READY 4c5420b round-2 C1 no-speech window recovery/warnings; native say host gate pending
READY a52fc4a AUD-06 groundwork / PCM file tests; native model host gate pending
READY 63f4abb package 1 AUD-10 implementation/unit tests; real Speech host gate pending
READY 63f4abb package 2 injected-fault verification; unit tests pass
READY 63f4abb package 3 scale/multi-display geometry; math tests pass

# capture status

## Reference gap work (2026-10-15)
- Latest continuation check: 2026-10-15 18:02 UTC; main 3dd0d3b, local HEAD e268f6a
  (based on c1bf553). Capture sources/tests still match main. Lead's next rebase
  is pending; no Git retry/workaround. Local capture implementation Next is empty.
- NEW HOST EVIDENCE from QA's TEST_REPORT (main c1bf553, 19:45): display overlay /
  Start / Stop yields a complete 12.19 s package; scripted input 47/47, timing
  0.27–8.67 ms (mean 1.95), position <=0.98 point, 5 paired clicks. Area 800x500,
  window 1626x1014 with matching manifest, pause 2.17 + 1.85 s all PASS. QA also
  reports real auto-zoom and export/clipboard/model checks passing. These are QA
  host runs, not new capture runs here; no new capture failure was reported.
- F10 (editorOpened=true / editorInFront=false) is UI-owned and may be activation
  behavior in the self-test. QA did not run reference hotkeys (another app instance)
  or after-recording buttons (missing hook). Selected-app audio isolation, durable
  marker action forwarding, Speech and hardware-specific acceptance remain open;
  the successful baseline runs do not close those checks. No app launched here.
- CAP-3 integration discrepancy in updated main FEATURES: the row now lists only
  editor presentation as pending, but RecordingController.addMarker still writes
  elapsed*1e9 into its UI array and EngineSession/LiveEngine expose no capture marker
  action. The hotkey exists, but never calls RecordingSession.addMarker; therefore
  it does not produce durable events.jsonl markers for Project.markers(). Keep UI
  forwarding pending alongside editor presentation, as well as native acceptance.
  This is a code audit, not a live defect reproduction; files are UI/QA owned.
- Module APIs and docs/host commands remain ready. No app launch, unchanged tests
  or denied Git mutation repeated. Only this integration status needs checkpointing.
- Freeze lifted / integration audit: 2026-10-15 16:40 UTC. Lead reports main f611874
  integrated and green: 465 Swift + 189 XCTest + 91 Rust. This is Lead's host
  evidence, not a capture rerun; it supersedes the earlier full-suite integration
  gate for that baseline, but does not prove optional speech/device/media checks.
  Local clean HEAD is still 73221c6; Lead handles the Codex rebase. Capture sources
  and tests have no delta versus f611874, so independent module work remains ready.
- Main FEATURES now acknowledges CAP-1/2/3/6 capture APIs/tests, keeps CAP-2/5
  hardware-limited, records CAP-4's keep-30/60 decision and assigns CAP-7 to UI.
  No new capture-owned implementation gap or QA failure was added. UI/editor first
  fix preset/test isolation per Lead; the integration requests below follow that.
- CAP-3 dependency CLOSED in core on main: Project.markers() / TimelineMarker read
  our events.jsonl marker_id directly and map exact source/segment/timeline ns
  through cuts, speed changes and repeated source. Rust core/src/markers.rs and
  Swift ProjectTests' multi-segment marker fixture use the exact capture wire
  format; Lead's 91-Rust/full-Swift green evidence includes these changes. Core's
  marker query is delivered; editor presentation and UI forwarding remain open.
  README now tells consumers to use marker.tlNs for edited timeline positions.
- Remaining consumer handoff (still present on f611874):
  * UIRecordingOptions/LiveEngine.Session need systemAudioSelection and
    cameraMaxResolution. New picker settings still default the audio Bool to true;
    use off for new settings while preserving explicit saved choices.
  * EngineSession needs a throwing marker action forwarding to
    RecordingSession.addMarker(). Use returned srcNs, not elapsed*1e9; current
    UI-only markers.json is written at clean stop and is a distinct path. Core
    consumes durable event markers directly; a derived sidecar must not duplicate
    or replace them. Lead/UI/editor settle the optional sidecar consumer contract.
  * Present CapturePreflight.check/windowResizeIssue. CAP-7 cue timing/gain is UI
    owned. No new capture default or contract change is needed for these handoffs.
- Live-test gate rechecked: QA .app-lock absent, but pgrep could not get the process
  list (sysmond unavailable). QA's current handoff also says another instance is
  running. No app launched; Lead/QA must run native acceptance outside the sandbox
  after confirming the app is free. Existing guarded commands below/README apply.
- CAP-2/M3 hardening follow-up: extracted the existing AV sample validation into
  AuxiliarySamples (same callback/writer queue) and tested the real SegmentWriter
  with genuine injected BGRA video/48 kHz PCM. Camera format changes larger OR
  smaller than negotiation, wrong media, missing clocks and invalid PTS preserve
  prior camera samples while screen/mic continue; failed-before-first-frame cameras
  create no track. Five injected cases across two parameterized regressions pass.
- Fixed an ordering gap identified while adding these cases: the callback previously enqueued
  disable on its own writer queue, letting already-queued restored-size camera
  frames slip through before disable executed. Validation now disables immediately
  on the writer queue, with dispatch preconditions; device notifications on other
  queues still use the queued deviceUnavailable API. A failed camera cannot resume
  mid-segment, warnings are once per failed track, and other tracks remain usable.
- Follow-up validation: capture 136 tests / 7 explicit opt-in skips / zero failures
  (20.1 s including hour/100-crash simulation). Rust 69 pass / 1 ignored. Canonical
  signed app + strict codesign pass (Yapcam Dev Signing). Rebuilt again AFTER Lead
  rebased onto the icon integration: bundled AppIcon.icns equals Resources source,
  CFBundleIconFile=AppIcon (extension omitted) and strict codesign passes. Icon not
  regenerated or edited; the canonical script copied Lead's integrated resource. Source/test/status privacy scans and shell syntax
  checks pass, as does git diff --check. Full Swift host gate from the earlier attempt remains:
  six E2E Metal-unavailable failures plus mixed-runner signal 6, not rerun unchanged.
  Logs: /tmp/yapcam-capture-auxiliary-{focused,tests,rust,app,privacy}.log.
  No app launched, no icon/source outside capture ownership touched. Public APIs
  and package formats are unchanged from the ready handoff below.
- Cleanup audit: the two previously documented capture-owned isolation roots are
  still IN USE (main.o0iym76c: PIDs 75979/76125; harness.igb_95s6:
  PIDs 77512/77831). They were listed and retained. No other team directories
  inspected/deleted; the current build's tiny Swift wrapper was cleaned by its
  EXIT trap. Lead's existing request to terminate those stalled jobs outside the
  sandbox remains. New cleanup plan /tmp/yapcam-capture-auxiliary-cleanup.json is
  empty because neither old root is safe to delete while in use.
- Lead icon integration acknowledged: main badc4e4 owns AppIcon.icns,
  CFBundleIconFile and the build-script copy. Capture did not modify/regenerate
  the icon. Earlier staging/rebase failures were Git sandbox denials; Lead resolved
  the pending checkpoint/rebase as 9b0cadc. Current post-rebase build/resource
  verification above supersedes the earlier pre-icon build evidence.
- CAP-1 implemented: `SystemAudioSelection.off / .allApplications /
  .applications(bundleIDs: [String])`; `RecordingOptions.systemAudioSelection`,
  `CaptureSources.applications: [CaptureApplication]` (bundleID/name/id). New
  recordings default off. Legacy explicit systemAudio=true/false settings decode
  unchanged; the compatibility Bool enables all apps only when changing from off.
  UI: default NEW picker preferences off too (existing UI explicitly passes its
  Boolean and must migrate to the enum); retain a user's saved explicit choice.
  Use the enum for the three audio modes and the application list for checklist
  identity; persist bundle IDs, never process IDs. A selected app missing on
  start/resume or an empty checklist produces an explicit error, never all audio.
  USB sources support all/off for device audio; a Mac-app checklist is rejected.
- A separate audio-only SCStream uses the app filter, keeping screen/window/area
  video independent of audio selection and desktop/notification exclusions. Both
  streams use the same host-clock writer/preroll handling. Startup failure rolls
  back audio, shutdown attempts both streams even after one fails. No new package
  format: selected apps mix into the existing system.m4a track. App own audio is
  excluded. Application discovery de-duplicates bundle IDs and omits Yapcam.
- CAP-1 validation: signed canonical app + strict codesign pass, 123 capture tests
  (7 opt-in skips), Rust 69 pass / 1 ignored. Full Swift attempted: mixed
  XCTest has 6 E2E export failures (Metal unavailable) / 46 skips of 129 tests;
  Swift Testing mixed bundle then aborts with signal 6 after media/IOSurface
  denials, precise abort cause not established. Isolated capture suite passes; Lead must rerun full suite on host. Logs:
  /tmp/yapcam-capture-cap1-{tests,app}.log and reference-{rust,full-tests}.log.
  No app launched. Host gate: two apps play distinct tones; select one and confirm
  only its tone in system.m4a while video still includes both apps, repeat with
  window/area and pause/resume, all/off. Signed self-test overrides below permit
  native testing before UI wiring; honor QA app lock/other-instance rules.
- CAP-2 implemented: `RecordingOptions.cameraMaxResolution: CameraMaxResolution`
  (`.hd720`, `.hd1080`, `.uhd4K`; Codable integer 720/1080/2160). Default and
  legacy missing-field default are 1080p. UI: camera menu selects this property;
  it caps webcam only, not the screen/USB source. Largest supported native format
  within the landscape-or-portrait size envelope wins; prefer requested fps when
  dimensions tie, otherwise fall back from 60 to 30. Never upscale/exceed the cap.
  29.97/59.94 modes preserve their native supported frame duration; manifest
  fps remains the nominal 30/60, while sample PTS determines actual cadence.
  Unsupported formats disable the auxiliary camera with an explicit warning;
  screen recording continues. Frames with unexpected negotiated dimensions also
  disable the camera rather than silently violating the cap/manifest dimensions.
  Camera remains HEVC. Existing session.tracks.camera stores ACTUAL size/fps;
  requested maximum is an options preference, not new recording metadata.
- CAP-2 validation: 126 capture tests pass (7 explicit media skips), canonical
  signed build/strict codesign pass. Native camera remains LIMITED (no webcam).
  Host: connect a 4K webcam; test each limit at 30/60, inspect camera.mov and
  session.json, verify fallback on a 720p-only device and camera loss. Logs:
  /tmp/yapcam-capture-cap2-{tests,app}.log. CAP-1/CAP-2 need Lead Git checkpoints.
- CAP-3 implemented: `@MainActor RecordingSession.addMarker() throws -> RecordingMarker`
  (id/segmentIndex/segmentNs/srcNs), only while actively recording and not busy.
  Uses first written screen frame as segment origin, adds previous segment duration,
  excludes pauses; works with key recording off and without global input permission.
  Events journal is synchronized before acknowledgement; no separate sidecar.
  Additive event contract for Lead FORMATS/core/editor: events.jsonl line
  `{"t":123456789,"type":"marker","marker_id":"UUID"}`. t is segment-local ns;
  source time = segment.src_start_ns + t. No coordinates/key text on marker events.
  Existing core Event.kind String/details map accepts the extra event/UUID; core
  needs a marker query mapped through edits, editor needs timeline presentation.
  UI: wire the rebindable marker action (Command+Option+Control+F default) to this
  method. Capture never installs its own competing hotkey or records shortcut keys.
  Tests cover idle/paused/finished rejection, first-screen origin, pause removal,
  distinct IDs, persisted events and recovery trimming partial/out-of-media lines.
- CAP-6 implemented read-only `CapturePreflight.check(options:sources:) ->
  [CapturePreflightIssue]` (kind/message/permission/id). UI: present issues before
  starting: camera without mic, selected camera/mic missing, missing permissions,
  closed laptop lid with INTERNAL mic, invalid Mac app checklist/USB combination.
  `CaptureDevice.isBuiltIn` comes from AV transport; no lid sensor is unknown.
  `CapturePreflight.windowResizeIssue()` is only for resizing another app's window;
  recording it ordinarily needs no Accessibility permission. No prompts/settings
  changes happen in these APIs. Injected tests cover all branches; laptop warning
  and real-camera behavior remain hardware limited. UI still owns confirmations,
  changing missing selections and permission actions; do not mark dialogs verified.
- CAP-4 DECISION: retain our 30/60 upper-rate option (default 60), actual frames
  follow source/display cadence below it, VFR preserved; no support claim for
  120/144 Hz recording. HEVC screen/webcam and two-second keyframe/fragment target
  remain. Numeric reference qualities (screen 0.85 / webcam 0.6) are NOT implemented
  or claimed equivalent: AVAssetWriter's AVVideoQualityKey is documented in the
  installed SDK for JPEG/HEIC/ProRAW only. Retain its HEVC rate control rather than
  pass an unsupported property. If exact encoder quality control is required,
  Lead should assign a reviewed VideoToolbox backend change with native acceptance.
- CAP-5 already implemented/checkpointed in 8c3345e; no duplicate USB implementation.
  Device frame editor section belongs to core/editor; real USB hardware remains open.
- CAP-7 HANDOFF to UI (ownership boundary): current RecordingController plays a
  system cue then waits 450 ms, with no explicit volume. Use an original/OS sound
  at gain 0.33, wait for completion capped at 540 ms BEFORE session.start(); stop
  cue after finishing. Do not copy extracted reference sounds. Capture does not
  play cues. UI needs timing/cancellation tests and live sound-leak acceptance.
- Self-test API/environment now permits native verification before UI changes:
  YAPCAM_CAPTURE_SELFTEST_AUDIO=off|all|apps:bundle.id,other.bundle.id;
  CAMERA_MAX=720|1080|2160, CAMERA_ID/MICROPHONE_ID=device unique ID,
  MARKERS=0|1 (all keys prefixed YAPCAM_CAPTURE_SELFTEST_). Markers enabled writes
  one after start and after resume. Existing target/FPS/pause switches remain.
  Self-test's explicit legacy audio-on default remains; NEW recording options off.
  Tests reject invalid/empty overrides. README documents APIs/format/host gates.
- Final validation: 134 capture tests / 7 explicit opt-in skips / zero failures
  (18.1 s including hour/100-crash simulation). Final canonical signed build
  and strict codesign pass with Yapcam Dev Signing / mov.yapcam.Yapcam.
  Rust 69 pass / 1 ignored. Privacy scans and README shell syntax pass;
  git diff --check passes. No live app launch and no capture media committed.
  All temporary Swift flag wrappers were removed by EXIT traps. Listed/removed
  27 inactive capture fixtures left by this run's mixed-bundle abort; manifest
  /tmp/yapcam-capture-reference-cleanup.json. No other teams' directories touched.
  Logs /tmp/yapcam-capture-reference-{tests,rust,full-tests,app,privacy}.log.
- Apple implementation references (behavior notes above remain own prose):
  [SC application filter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:including:exceptingwindows:)),
  [AV native format configuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activeformat).
- No H capture gaps in the reference inventory. Priority: CAP-1, CAP-2 camera cap,
  CAP-3 marker API, then CAP-4/5/6/7. Behavior notes read in gap-list capture section
  and reference A2–A6; own implementation/prose only, no extracted assets/code.
- Rebase attempt from clean d931104 onto main dee1061 denied creation of Git's
  rebase-merge directory. Lead still checkpoints/rebases/pushes this worktree.
  UPDATE: Lead has since rebased onto badc4e4 (app icon) and checkpointed all
  19 owned files as 9b0cadc (including four new source files and one new test file).
  Only the current status follow-up needs checkpointing. No Git workaround used.
  Existing USB source is checkpointed as 8c3345e, not the old WORKTREE label.

## USB baseline handoff (historical validation; checkpointed)
- USB iPhone/iPad screen source is IMPLEMENTED / LIMITED (no device attached).
  UI API ready in this worktree:
  CaptureTarget.device(String /* AVCaptureDevice.uniqueID */),
  CaptureSources.deviceScreens: [CaptureDevice],
  CaptureSources.loadDeviceScreens() throws -> [CaptureDevice] (no SC/TCC discovery),
  and CaptureSources.deviceScreenDiscoveryError: String? on the combined load result.
  UI: add Device source mode, list deviceScreens, pass .device(id) via LiveEngine;
  systemAudio controls DEVICE audio for this target. No connected device means an
  empty list; a discovery failure is explicit. Mac screen permission is not needed
  for this target; AV camera/audio authorization applies. Exact API/format handoff below.
- Validation 2026-10-15: capture suite 118 tests / 7 opt-in skips / zero failures
  (16.7 s incl. hour/100-crash simulation). Separate REAL no-device discovery
  passes: CAPTURE_USB_DISCOVERY devices=0. Rust 69 pass / 1 ignored; canonical signed
  app build + strict codesign pass (Yapcam Dev Signing / mov.yapcam.Yapcam).
  No Yapcam app launched, no recorded media or credentials committed. Only a tiny
  temporary Swift flag wrapper was created and removed by an EXIT trap; no repo copy.
- Local HEAD c21286e; main d71b663 adds the final handover. Rebase before USB edits
  denied Git metadata writes as before; Lead checkpoints/rebases/pushes. USB changes
  are 13 owned files (9 source, 3 test/README, this status; 3 new files). Logs:
  /tmp/yapcam-capture-device-{module,focused,tests,native-discovery,rust,app}.log.
  Final audio-metadata callback regression included; signed app rebuilt afterwards.
  Source/test/status gitleaks scans, shell-snippet syntax and git diff --check pass.
- F9 is checkpointed as 4817b58/integrated; Lead's 13:00 handover reports F9 fixed
  and live window open verified. Older QA retest at 511f831 predates the code fix.
- New QA handover confirms F8 fixed/native verified on 3b68bde and clean lock
  removal verified. Native hour/Speech/voice-isolation remain open. Old F8/lock host
  acceptance requests below are superseded by that QA evidence.
- New QA input evidence on main: 38/38 scripted input events match, maximum timing
  error 15.4 ms and position error 0.98 point; real clicks also drive auto-zoom.
  Older no-Accessibility notes are superseded. QA's latest handover also reports
  hotkeys PASS; this is host evidence from QA, not a capture test rerun.
- Lead update 2026-10-15 12:12: ALL app permissions granted (screen/system audio,
  Accessibility, Input Monitoring, mic, camera). LaunchServices --drive-input-selftest 6
  reports accessibility=true/inputMonitoring=true; scripted moves and both clicks
  appear at the exact expected point in events.jsonl. This supersedes earlier false
  permission readings from direct executable launches. No mic/camera hardware here.
- Launch rule corrected: use open -n -W <build>/Yapcam.app --args ... after checking
  QA .app-lock AND confirming no other Yapcam instance runs. Direct executable
  launch attributes TCC to the shell. Helpers below/README now use guarded open
  with explicit --env values. QA lock absent at 12:13 audit; no app launched.
- F8 request rechecked 2026-10-15 12:17 CEST: the fix and odd-size regressions are
  checkpointed in f400c3e and integrated in main c504858. Capture source/tests/README
  match main. At scale 1, the reported 1627x1015 window now configures/stores
  1626x1014 encoded pixels while source.content_rect_points retains 1627x1015.
  Scale-1/2 geometry and coordinator resume tests pass; prior signed build/106-test
  verification remains applicable. Native odd-window file readback is still pending.
  This is historical F8 verification; current pending source changes are F9 only.
- Fleet app rule acknowledged 2026-10-15 10:54 CEST; QA .app-lock existed then.
  NO Yapcam launch performed. Check it before every launch, and do non-live work
  while it exists. Never quit another instance or kill by process name; only stop
  PIDs started by capture. Host commands below now use LaunchServices and refuse
  to launch if QA owns the app, another instance runs, or inspection fails.
- Lead checkpointed lock cleanup/self-test variants as a3a51ad and integrated them
  in main 248630a. Fleet-rule docs are checkpointed in e66eae5/integrated in 529db15.
  Lock-cleanup and self-test-variant host results remain pending; status update only.
- Screen Recording grant CONFIRMED by Lead since 10:25 for mov.yapcam.Yapcam /
  Yapcam Dev Signing. Lead's --capture-selftest 6 completed: HEVC 1680x1050,
  352 frames / 6.09 s, AAC system audio offset 1 ms, 95 events. This supersedes
  historical TCC-denial notes; it is a display baseline, not window/area/pause or
  speech/model acceptance. Lead will run native/live checks outside the sandbox.
- Fixed clean-finish .capture.lock residue: every normal lease release unlinks its
  own inode while still holding flock. This includes recording stop, recovery and
  transcription; paused sessions retain the file/lock. Crashes can leave an empty
  file, safely reclaimed by a later lease. Acquisition rechecks inode identity so
  an opener racing unlink cannot acquire a detached lock; release preserves a
  replacement inode. No recording/manifest format change.
- Tests cover active/paused presence, stop after resume, stop while paused, retained
  exclusivity, replacement-inode protection, and recovery/transcription cleanup.
  Hidden self-test environment options now select display/window/area, 30/60 fps
  and pause, using the existing signed-app handler. Parser tests cover malformed,
  nonfinite/out-of-bounds geometry, absent windows, fps and pause validation.
- Validation: capture suite 104 tests / 6 explicit media skips / zero failures
  (33.8 s, including one-hour/100-crash simulation); Rust 68 pass / 1 ignored.
  scripts/build-app.sh passes; strict codesign confirms Yapcam Dev Signing and
  mov.yapcam.Yapcam. Initial link failure was a stale Rust release library and was
  resolved by rebuilding it. The temporary Swift flag wrapper used cleanup traps
  and was deleted on exit; no repo/harness copy was created.
  Final recovery/transcription lock-file assertions pass in a focused 2-test rerun.
  Source/test/status gitleaks scans and git diff --check pass. No full unrelated
  Swift/UI/Metal rerun; native host checks above remain pending.
  Logs: /tmp/yapcam-capture-lock-{core,tests,rust,app,followup}.log.
- M3 implementation/unit validation complete. The one-hour 60 fps
  writer/event simulation and 100 seeded crash trials pass; capture limits are below.
  Native fragment probe compiles but remains a sandbox media-services host gate.
- C1 is checkpointed in 4c5420b and integrated; no duplicate fix needed. Lead reports
  main a02a89e green (256 Swift + 97 XCTest + 61 Rust; render 86/86 on Metal).
- Validation used main a02a89e source + owned changes. Signed build and Rust 61
  pass; isolated capture suite 100 tests /
  6 media skips / zero failures. Final main-based run also passes the hour simulation
  and capture tests; full-suite environment failures are recorded below.
- Native Speech/isolation, real capture and long-session encoder/device behavior are
  not established by simulation or the separate renderer Metal hardware results;
  the confirmed short display capture above is additional host evidence.

## USB device source — UI / Lead API and format handoff
- UI uses CaptureSources.loadDeviceScreens() throws -> [CaptureDevice] without
  ScreenCaptureKit. Combined load() also fills deviceScreens and an explicit optional
  discovery error. Add a Device mode to UITarget/settings/picker/RecordingController,
  map it in LiveEngine to CaptureTarget.device(selectedID), and request .camera plus
  .microphone when device audio is enabled. Refresh after connect/disconnect; CMIO
  enumeration may update after process opt-in. Empty list is the no-device state.
- CoreMediaIO kCMIOHardwarePropertyAllowScreenCaptureDevices=1 enables process-level
  discovery. Candidates are connected external/muxed video devices, deduplicated
  by uniqueID; ordinary cameras/Continuity Camera are excluded. We do not opt in to
  wireless devices or match hard-coded/localized iPhone names. Assumption: the muxed
  external screen capability exposed by CMIO identifies wired iOS screen sources.
- DeviceScreenStream/Driver implements CaptureSessionStream via AVCaptureSession.
  Blocking configuration/start/stop runs on a serial control queue; both delegates
  use the writer queue and the SAME session synchronization clock, converted to the
  host clock. Native input format is selected on macOS; screen.mov is HEVC and
  system.m4a is the device's audio (AAC). Native audio ASBD rate/channels are persisted
  on first accepted audio and finalization, not assumed stereo/48k. First video defines zero; audio preroll
  is discarded. maxFPS remains a 30/60 cap, not a native-device frame-rate promise.
- Package additions for Lead FORMATS.md: source.kind="device", source.device_id=AV
  uniqueID, source.device_name=localizedName, display_id=0 (compatibility sentinel),
  display_name=device name, content_rect_points=[0,0,nativeWidth,nativeHeight], scale=1.
  Phone input pixels define its coordinate space; no host display is associated.
  Add optional deviceID/deviceName to source metadata descriptions. Same session
  schema/seg-XXX files/host-start and track-starts sidecars as other recordings.
- Mac cursor/key taps are intentionally not attached for USB targets: events.jsonl
  and cursors.json are valid empty journals; phone touches are not available through
  these capture APIs. Optional Mac mic/camera still use existing auxiliary tracks.
  Device unplug/runtime error interrupts the primary recording while preserving the
  package; auxiliary device loss keeps its existing warn/continue policy. Changed
  device dimensions/orientation require a new recording; resume rejects changed size.
- Tests: injected opt-in/discovery failure/no-device, capability filtering/dedup,
  device source/Codable metadata, no host-screen permission dependency, camera/audio
  permission failures, pause/resume, primary disconnect, empty host event journals,
  real synthetic-buffer shared-clock routing/audio offset/actual ASBD and changed-size
  rejection. Coordinator tests also assert the real audio format is published during
  active recording and at stop. Actual CMIO+AV discovery returned zero devices.
  Native iOS frame delivery, A/V sync, orientation, input format selection, unplug
  behavior and core/editor open/export remain UNVERIFIED (no iPhone/iPad here).
- Host discovery command (no app launch, expects this host's no-device state):
  YAPCAM_CAPTURE_DEVICE_TESTS=1 swift test -j 4 --filter actualUSBDiscoveryWithNoConnectedIOSDevice
  With a real connected device, first check QA .app-lock/other instances, then use
  the guarded LaunchServices helper: capture_selftest device:<uniqueID> 60
  (and repeat with final argument 3 for pause). Never run the empty-device assertion
  after attaching hardware. Re-review AVCapture control/sample queue lifetimes before
  merge. Suggested checkpoint: feat(capture): record USB iOS device screens with audio.

## QA F9 — always-write display_name / implementation verified
- Root cause: the window constructor omitted displayName, so synthesized optional
  encoding dropped display_name and the older strict core reader rejected the package.
  Display/area/window constructors now share CaptureGeometry.sourceMetadata and one
  NSScreen ID->localized-name map. Windows use the existing greatest-overlap display;
  area/display use the selected display. Logical point rect/scale remain separate.
- SourceMetadata.encode ALWAYS writes display_name, falling back to "Display" if
  an old package or unavailable screen has no name. Decoding remains optional for
  old missing-field packages. Recovery and every other manifest write also satisfy
  the always-write contract. Window title/bundle ID and other optional keys retain
  their existing serialization behavior. No schema bump or existing-media rewrite.
- Two parameterized regressions cover ALL three kinds: nested manifest JSON must
  name the selected non-primary display (not a different screen), preserve the point
  rect/scale and round-trip; legacy missing-name JSON stays readable and writes a
  fallback on save. Unknown display ID also uses the fallback.
- Validation: capture 108 tests / 6 explicit media skips / zero failures (16.7 s,
  including hour/100-crash simulation); Rust 68 pass / 1 ignored. Canonical app build
  and strict codesign pass: Yapcam Dev Signing / mov.yapcam.Yapcam. Logs:
  /tmp/yapcam-capture-f9-{tests,rust,app}.log. Temporary flag-wrapper directory was
  listed/removed by EXIT trap; no repo copy, live app launch or recording generated.
  Source/test/status gitleaks scans and git diff --check pass.
- Lead: checkpoint these five files; suggested commit:
  fix(capture): always name the containing display in source metadata.
  After the normal app-lock/process checks, use the guarded helper below:
  capture_selftest window:com.apple.Terminal 60
  Confirm session.json source.display_name equals the containing display's localized
  name, then YAPCAM_LIVE_PACKAGE=<new-window-package> swift test -j 4 --filter
  LiveRecordingTests/testOpenRealRecording. Core owns the legacy-reader fallback.

## QA F8 — even-size metadata / implementation and native verified
- Previously a 1627x1015-point scale-1 window requested/stored 1627x1015 pixels but
  produced 1626x1014 NV12/HEVC. CaptureGeometry now rounds positive pixel dimensions
  DOWN to even values (minimum 2) before BOTH SCStream configuration and manifest
  creation. The example is now 1626x1014 in both; at scale 2 it is 3254x2030.
- Logical rect/scale and pointer coordinates stay unchanged; only encoded dimensions
  are quantized. Assumption: use the observed NV12 even-size policy for all capture
  targets, including fractional area rectangles; even dimensions remain unchanged.
  No schema change or existing recording rewrite. Window resume retains the initial
  encoded surface even after resize or moving to a display with another scale.
- Regressions at scales 1/2: odd window, fractional area on a negative-origin display,
  minimum dimensions, unchanged logical geometry/cursor midpoint, and real coordinator
  initial/resumed stream pixel arguments matching persisted tracks.screen.pixel_size.
- Validation on 92b19e9 + owned edits: capture suite 106 tests / 6 media skips /
  zero failures (17.9 s, including hour/100-crash simulation); Rust 68 pass / 1 ignored.
  scripts/build-app.sh and strict codesign pass (Yapcam Dev Signing / mov.yapcam.Yapcam).
  Tiny temporary flag-wrapper directory was listed/removed by EXIT trap; no repo copy,
  no app launched and no recording generated. Logs /tmp/yapcam-capture-f8-{tests,rust,app}.log.
  Source/test/status gitleaks scans and git diff --check pass.
- Lead: after building main with f400c3e, run the guarded capture_selftest function below against an
  odd-sized window, e.g. capture_selftest window:com.apple.Terminal 60.
  Verify session.json tracks.screen.pixel_size equals ffprobe width/height in EVERY
  screen segment, including pause/resume after resize. UPDATE: QA confirms F8 fixed
  on main 3b68bde; the original manifest/file mismatch is closed.
  Suggested commit: fix(capture): align manifest pixels with even NV12 capture dimensions.

## New host evidence — main 529f208 / QA and UI reports
- QA TEST_REPORT (runs on b5d1268): 4 min capture complete, 240.14 s / 13838 frames,
  RSS flat 72 MB. Ten minutes: 600.08 s / 34476 frames, 300/300 flash/beep pairs,
  first/mid/last A/V offsets 2.5/-14.2/9.8 ms, drift 7.3 ms, RSS max 73 MB,
  package 97 MB. These are actual display/system-audio results, not the M3 ledger.
- QA recovery now passes: SIGKILL during a 25 s recording left status recording;
  interruptedPackages found it, recover() finalized one 24.01 s segment (about 1 s
  tail loss), core opened it and ffmpeg decoded the screen track. UI relaunch prompt
  remains untested. Earlier interrupted runs also had readable media (223/223 markers).
- UI's live controller runs: area at (200,150), 800x500 points produced 800x500 video
  and correct content; Terminal window 1627x1015 points produced 1626x1014 video
  (encoder even-size rounding); pause/resume produced 2.16 + 1.93 = 4.09 s of source,
  excluding the 2 s pause. UI verified toolbar/HUD/countdown and cursor absent from
  recorded frames. This is UI's host evidence, not capture's environment-option tests;
  window movement/resize, static tails/startup and .capture.lock cleanup still need checks.
- QA F6 (HIGH) and UI repro: exporting real recordings with audio through the exact
  tail fails; trimming ~100 ms or excluding audio works. System audio ends slightly
  before the screen segment (QA: 600.067 vs 600.083 s). Assigned to core audio_ranges
  / render AudioTimeline; capture must preserve the true per-track starts/durations.
  No capture workaround pads or truncates the screen to hide the export defect.
  UPDATE: main fc29d18 records Lead's verification of the render fix on 529f208:
  LiveRecordingTests 4/4 pass including full edit/export with audio (156 s).
  F6 host acceptance is now confirmed by Lead; older QA failure rows are historical.
- Lead/QA: the signed-app window/area/pause environment hooks requested by QA now
  exist on main; use the guarded commands below. Main also adds UI's --target
  window:<id>/area:x,y,w,h and --pause-after flags, --ui-record-selftest and
  --drive-input-selftest (built-in move/click pattern). Title/no-audio/output/custom
  JSON input flags are not supplied by these hooks. Earlier accessibility=false
  reports are superseded by Lead's 12:12 LaunchServices grant/input verification.

## Lead host commands — lock cleanup / window / area / pause
After checkpoint/build of this worktree, run from a normal host terminal in the repo.
Use one command at a time; guarded open -n -W preserves app TCC attribution and waits
for exit. Helper arguments: target, fps, optional pause-after seconds. Open a disposable
TextEdit document for window cases. A numeric window ID also works after window:.
All output stays in ~/Movies/Yapcam/QA/capture; inspect probe.log for package paths.

```sh
scripts/build-app.sh
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
YAPCAM_CAPTURE_MEDIA_TESTS=1 swift test -j 4 --filter 'actualHEVCWriterAndInterruptedRecovery|NativeFragmentTests'
```

- Every clean package: status complete, NO recording/.capture.lock, screen start 0,
  monotonic video/events, AAC timestamps aligned by track_start_ns. Check with ffprobe.
- Pause: two segments; seg-001.src_start_ns equals seg-000.duration_ns; 0.5 s pause
  excluded. Area: 800x600 pixels on the scale-1 host (rect is display-local points).
- Window: move/resize during capture and during the pause; initial encoded surface
  remains fixed. Inspect first/resumed frames for blank startup and a static tail
  through the stop time. These properties still require the host recordings.
- Native tests: static-tail duration/readback and sparse one-hour HEVC moof/sample
  checks; append CAPTURE_NATIVE_HOUR output here. The latter is a 1 Hz media clock,
  not a real-time 60 fps benchmark. Lead should also run kill/relaunch recovery.

## Temporary disk cleanup — 2026-10-15 03:44 CEST
- Listed exact paths/sizes before deletion and checked open files/cwds with lsof.
  Deleted 14 completed capture-only repo/harness/build/cache/tool directories:
  TMPDIR/yapcam-c1-{harness.i_bkzqya,main.cmsqs41i},
  TMPDIR/yapcam-isolation-{final-build.uxivlpw1,tools.qzyz0s6z},
  TMPDIR/yapcam-m3-{harness.ua3jj4nm,main.xkum3ts6};
  /tmp/yapcam-capture-{main-xxcz46te,module-cache,review-main.JPDnEz,review-tools,
  tools,validation}, /tmp/yapcam-isolation-module-cache and
  /tmp/yapcam-transcription-main.pnEG9w. Removed four stale c1/m3 pointer files.
- Allocated size before deletion: 4952432 KiB (4.72 GiB); observed available-space
  increase: 4737284 KiB (4.52 GiB), to 33379928 KiB. Other teams may be writing
  concurrently. Retained small validation logs and the exact deletion manifest at
  /tmp/yapcam-capture-cleanup-plan.json. No generic tmp.* or other-team dirs touched.
- Still in use, NOT deleted: TMPDIR/yapcam-isolation-main.o0iym76c (PIDs 75979,
  76125) and TMPDIR/yapcam-isolation-harness.igb_95s6 (PIDs 77512, 77831), about
  0.95 GiB combined. These are old stalled capture test runs; sandbox signal denial
  was already established. Lead: terminate those runs outside the sandbox, then
  capture can delete their directories after confirming no remaining users.
- Future temporary-directory scripts must install EXIT/HUP/INT/TERM cleanup traps,
  keep artifacts under one capture run root and wait for children before cleanup.
  Tests README has the shell template; Swift fixtures already use defer. No new
  harness copy or build was needed for this cleanup/documentation change.

## M3 long-session / crash hardening
- LongSessionTests drives production SegmentWriter routing and InputEventRecorder
  without SCStream/event taps: genuine reusable 64x64 video + 48kHz PCM buffers,
  one hour of 60 Hz timestamps, 10 Hz pointer motion plus per-second click/up/key.
- Observed: 216000 screen buffers; 215999 each mic/system buffers (stop clipping);
  46800 events, 2380305 JSONL bytes. Per-track simulated ledgers contain 1800 bounded
  fragment records / 43208 bytes each, with 2 s cadence and exact stop-time tails.
  Ledgers are explicitly SIMCAP01 test doubles, NOT native MOV/AAC or bitrate estimates.
- 100 deterministic crash points (seed 0x59415043414D), including zero, just before/
  at/after the first fragment and near the hour end. Prefix snapshots contain torn
  fragment/event tails, backwards/out-of-range rows and every-third torn manifest.
  Production Recovery restores host origin/track offsets and exact bounded source
  durations, trims events byte-for-byte, keeps crashed event bytes in events.jsonl.prev,
  releases locks, and is
  idempotent. 98 readable trials recover; 2 before any fragment preserve originals
  and return an error. Completed-fragment loss is <2 s IN THE SIMULATOR ONLY.
- The seeded hour test passed in 39.5 s initially, 23.5 s with the capture suite and
  32.3 s in the final main-based run. It checks persisted-file sizes/counts and
  recovery correctness; it is not an RSS, real-time encode or
  power-loss benchmark. Scratch packages are removed after each trial/test.
- Shared CaptureMediaPolicy supplies production's unchanged 2 s fragment/keyframe
  target. MediaTrackWriter is internal for the native test wrapper (no public API
  change). NativeFragmentTests adds a real HEVC hour clock with 1 Hz injected video,
  compressed-sample monotonicity/keyframe checks, MOV moof count and file bounds.
  This is sparse VFR, not a 60 fps throughput test; no screen grant is required.
- Native probe was attempted: AVAssetWriter fails with writerFailed("The operation
  could not be completed") after IOSurface sandbox errors. Lead must run the README
  host command; native fragment cadence/size/duration is NOT verified by the ledger.
- Final validation 2026-10-15 03:31 CEST: signed scripts/build-app.sh passes with
  Yapcam Dev Signing / mov.yapcam.Yapcam; strict codesign passes. Rust 61 pass.
  Full Swift attempted: Swift Testing 259 tests / 36 issues (34 Metal preview,
  2 UI missing snapshots); XCTest 97 tests / 34 skips / 6 E2E Metal failures.
  No capture failure, including persisted fragment sample totals and source-sidecar
  checks. This is not a green full suite; Lead's earlier host baseline is separate.
- Logs: /tmp/yapcam-m3-{app-build,capture-all,full-swift,rust,native}.log.
  Source/test gitleaks scans and git diff --check pass. No generated media, credentials
  or dependencies added. All three assigned M3 implementation items are handled;
  native acceptance/re-review remains open. Suggested checkpoint:
  test(capture): stress hour-long routing and 100 crash recoveries.

## Capture limits / hardware acceptance
- macOS 15+ / Apple Silicon product target. Screen maxFPS accepts 30 or 60 only;
  ScreenCaptureKit uses that minimum frame interval, with half-frame jitter tolerance
  in the writer limiter. VFR is preserved; backpressure drops samples rather than
  queuing unbounded media. No promise of sustained 60 fps at every resolution/device.
- Screen/camera: HEVC in MOV, no frame reordering; separate AAC M4A audio at 192 kb/s
  requested per track. System audio requests 48 kHz stereo; mic requests 48 kHz mono;
  writer audio settings use the actual incoming format. Capture offers no H.264/ProRes
  or audio-codec choice (export settings are a separate subsystem). Camera uses the
  active device format, requests 30/60 fps and falls back to 30 when 60 is unsupported.
- Screen requests 8-bit NV12, native points×display scale, cursor excluded from video.
  Encoded dimensions round down to even pixels (minimum 2); logical rects retain
  full point coordinates. This prevents implicit encoder rounding from disagreeing
  with the declared pixel_size (QA F8).
  Geometry rejects nonfinite/nonpositive scale, rectangles below 2 logical points,
  and >32768 pixels per dimension. That validation ceiling is NOT an encoder/GPU
  capability guarantee. HDR capture is not configured/verified. Window resize keeps
  the initial encoded surface with fitted content; area rectangles are display-local.
- Movie fragment and maximum keyframe targets are 2 s. Real fragment closure depends
  on delivered samples, encoder/backpressure and filesystem behavior: there is no
  unconditional native 2 s crash-loss guarantee, especially for static/VFR sources.
  Event JSONL streams incrementally and synchronizes at segment close; it is not
  fsynced per event and has no power-loss durability claim.
- No explicit one-hour duration cap is configured; nanosecond source ranges use
  checked Int64 arithmetic. Only simulated one-hour behavior is established here;
  real file growth is VBR/content/device dependent. Start/resume and ongoing checks
  stop on <1 GB free; injected low-disk tests do not predict worst-case encoder bursts.
- Screen Recording is now granted and Lead's short display capture passed. Remaining
  host acceptance: window/area/pause variants, native HEVC/AAC fragments and
  kill/relaunch recovery; sustained live 30/60 fps, static
  tails, event-to-video alignment and A/V drift; camera/mic sync/loss (no devices here);
  Retina and multi-display capture (scale 1/2/negative-origin math is tested, only one
  non-Retina display here). Also native Speech and AUSoundIsolation quality/latency.

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
  and says track offsets must not be applied a second time. Main includes caption
  import/list/lane, AppDelegate.installTranscriber wiring and the Speech usage key.
  Real recognition and host permission acceptance remain pending.
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
- Earlier UI/QA SCStream -3801 reports are superseded by Lead's 10:25 grant and
  successful short display capture. No camera/mic; one non-Retina display. Unit and
  display-baseline checks do not establish device sync/loss, Retina/multi-display,
  or the remaining window/area/pause acceptance.

## Next
No remaining capture module implementation item in the integrated gap list.
Address findings from native acceptance or API integration. UI reports its
preset/test isolation fixed on main eacbd4d. Core marker mapping is delivered; UI
forwarding/options/prompts, editor presentation and hardware acceptance remain.
Dispatch note for Lead: capture needs a new concrete assignment or native failure
report to continue implementation; the unchanged consumer rows are already handed off.

## External handoffs / Lead requests
1. Lead: checkpoint this status refresh and rebase capture e268f6a onto main 3dd0d3b
   (Git remains read-only here). UI reports isolation fixed; consume the capture
   audio/camera/preflight APIs and forward marker actions to RecordingSession.addMarker. Core's exact
   event marker query/TimelineMarker is complete; editor uses tlNs for display and
   snapping. Lead: document public capture additions/optional derived UI sidecar in
   SWIFT_API/FORMATS. QA's GAP-CAP module statuses are now reconciled; consumer and
   native acceptance remain open. CAP-4 is a documented extra; CAP-7 belongs to UI.
2. Host: YAPCAM_CAPTURE_MEDIA_TESTS=1 swift test -j 4 --filter NativeFragmentTests.
   Record CAPTURE_NATIVE_HOUR output (actual bytes/moofs/duration) here. Also run
   the signed-app variants above plus static-tail/sync. Library kill/recover now
   passes in QA; app-level recovery prompt still needs acceptance.
   Re-review C1 warnings and M3 policy/test boundaries; full host suite is still needed.
3. Present C1 warnings and rerun the opt-in say tests on an authorized host with
   local models. Main already includes UI's Speech usage key, production transcriber
   hook, permission request and JSON encoding; real Speech remains unverified.
   Append host results here; capture will address findings.
4. Add transcript JSON including optional C1 warnings and existing timing sidecars/lock
   to FORMATS.md; document the even-pixel encoded-size policy (logical rect unchanged)
   and expose the warnings in the app's caption flow.
   Core already documents source-time import; complete consumer integration is outside
   capture ownership. QA should reconcile AUD-10 and fault/geometry rows
   from this evidence without marking real recognition or capture as verified.
5. Core/render: integrate explicit enhanced-mic selection using the AUD-06 contract
   above. Lead arrange real AUSoundIsolation noisy-speech and latency acceptance on
   the host; append findings here. UI must expose unavailable errors until supported.
