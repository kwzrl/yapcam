READY R6 11ce970+worktree | queued stop/start serialization, source-loss and malformed-input crash hardening; countdown UI handoff | 179 capture tests / 6 suites pass

## R6 capture hardening (2026-10-17)

- **Start/stop races fixed:** `stop()` now atomically waits for an in-flight start,
  resume, pause, or stop and then completes exactly once. Two stops queued behind
  startup return the same finished package; a second Start while preparing is
  rejected without creating another stream or package. Cancel uses the same atomic
  gate, including when its calling task is already cancelled.
- **Source-loss outcomes covered with fakes:** injected display unplug and window
  close both finalize the stream/writer, persist `interrupted`, release the package
  lease, and publish `sourceUnavailable`. Existing regressions cover SCK failure,
  permission revocation, USB source loss, and camera/microphone loss (auxiliary loss
  warns and leaves screen capture running). No real device or permission change was
  needed.
- **Trap hardening:** capture source point arrays are validated before indexing or
  package creation; malformed geometry now returns a typed writer error. Segment
  stop/preroll/PTS comparisons no longer force-unwrap optionals. Voice-isolation
  buffer/channel allocation and AudioUnit input pointers now fail explicitly rather
  than force-unwrapping; allocation failure has a regression.
- **Crash-class audit:** no Combine async publisher iteration, `fatalError`, `try!`,
  or unguarded user/disk array indexing remains in capture. The retained
  `MainActor.assumeIsolated` sites are main-thread-bound: timers are scheduled by
  main-actor methods, the CG tap source is installed on the main run loop, and
  AppKit's global event monitor delivers on main. The two AX forced casts are safe
  only after exact `AXValueGetTypeID` checks. SCK callbacks hop to MainActor and
  reject stale segment generations; AV callbacks enter locked/writer queues, and
  teardown removes observers and delegates on their control queues. The retained
  `dispatchPrecondition` checks enforce queues explicitly assigned to SCK/AV
  delegates and the private disk worker; no notification callback enters them
  directly. Frame-rate,
  geometry, marker, timeline, camera-area, and voice-latency arithmetic is range
  checked before division, multiplication, addition, or conversion.
- **UI request R6-CAP-UI1 (Lead route, priority):** Stop during the UI-owned
  countdown must cancel the pending countdown and prove through the actual click
  path that `RecordingSession.start()` is never called. Once capture startup has
  been invoked, the engine now queues Stop safely. Capture does not own countdown
  state or the button gesture and made no UI-source change.
- **Validation:** isolated repository runner passed **179 tests in 6 suites** in
  46.517s; eight hardware/native opt-ins remained skipped. `git diff --check`
  passes. No app launch, recording, TCC prompt/change, Finder restart, or files
  outside capture ownership.

READY RV fa01ec3+worktree | review finding 4 fixed: heartbeat cannot suppress newer real pixels; injected timestamp regression + 174 capture tests pass
READY W3 9c67775+worktree | A4.1/W4 desktop-icon filter wired end to end; no recording-time Finder mutation/restart; 173 capture + focused UI tests pass, live permission check untested
READY R5b 9acadbe +8 owned paths | 173 capture tests /127 Rust /signed main app green; 8 incoming requests delivered/resolvable, 3 explicitly blocked
R5b 02:10UTC 9acadbe + owned changes | done: requests pass validated on main a96173e snapshot | next: Lead checkpoint/rebase; named identity/native/hardware handoffs
READY R5 50efc6d + status reconciliation | H/M then L audited: 14 scoped matches, 1 user exclusion, 33 concrete blockers; UI/native gates remain
R5 01:08UTC 50efc6d | done: all 48 rows reconciled, named ownership/native/hardware blockers | next: Lead status checkpoint and listed handoffs
READY dd39be4 F13 verified by Lead on a7d1526 (signed debug, M4): full-file EN/DE speech; weak filler recall measured; F14 owned by render
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

## RV — static-screen heartbeat ordering

Review R5 finding 4 is resolved. `SegmentWriter` now keeps written screen PTS
(real or heartbeat) separate from real-source PTS and cadence state. Heartbeats no
longer advance the real-frame deadline. When a newer real source frame is delivered
after a host-now heartbeat with an earlier PTS, its pixels are kept and only its
written PTS is moved to 1ns after the heartbeat, preserving the media sink's strict
monotonicity.

The injected regression writes a real frame at `t=0`, a copied heartbeat at
`t=1.0s`, then a changed real frame delivered later with source PTS `t=0.9s`. It
asserts output PTS `[0, 1.0s, 1.0s+1ns]` and verifies the third pixel buffer is the
changed real image, not another heartbeat copy. Focused heartbeat/cadence tests
**4/4 pass**; complete `YapcamCaptureTests` **174/174 pass** in six suites. Native
opt-ins remain skipped. `git diff --check` passes; Lead must commit the worktree.

## W3 — A4.1 / W4 Hide Desktop Icons

Resolved on the integrated `9c67775` baseline. `AppSettings.hideDesktopIcons` now
travels through `UIRecordingOptions` and `LiveEngine.captureOptions(for:)` into
`RecordingOptions.hideDesktopIcons`. Display and area capture therefore use
`CaptureFilterPolicy`: Finder desktop-icon surfaces are omitted while normal Finder
folder windows remain visible. Window capture is desktop-independent and unchanged.

Recording start, failure, stop, cancel, and restart no longer call
`DesktopIcons.hide/restore` or modify Finder preferences. `DesktopIcons` is retained
only to restore the marker left by older builds at launch/termination; new recordings
never create that marker. Settings copy now describes capture filtering and no Finder
restart. Default remains off.

Verification: `git diff --check`; focused desktop-filter run **4/4 pass**; complete
`YapcamCaptureTests` **173/173 pass** (six suites, native opt-ins skipped). The full
UI target reached an unrelated pre-existing `StartSoundGateTests` leaked-continuation
abort; the focused `SystemAudioChoiceTests` suite passes **6/6**, including both new
settings-to-UI and UI-to-capture boundary regressions. Live acceptance remains **untested**: it needs Screen Recording
permission and a live display, and the user's running app was not touched. Lead must
commit this worktree because capture cannot write `.git`.

## R5 incoming requests

Read **all five other teams' status files from main a96173e** (ui370, core1048,
render1000, editor340, qa286 lines), including historical requests. Worktree source
is9acadbe; capture source/tests matched main before the additions below. `git rebase main` is denied
creating rebase-merge, so Lead must rebase. Validate additions in a disposable
main snapshot rather than editing other teams' files in this worktree.

| ID | Priority | From | Request / state |
|---|---|---|---|
| R5-CA01 (also CUR-06 sidecar) | H | render:64,105,464 | SOURCE IMPLEMENTED; BLOCKED global coverage — Render/Lead R5-CA01-IDENTITY: AppKit currentSystem guarantees image/hotspot, not semantic type or standard-instance identity across apps. Optional shape IDs now emitted only for registered standard-object identity; unknown/custom/fallback omit, even with identical PNG bytes. Do not certify universal system-cursor replacement from this sparse signal. Request Render/Lead accept this conservative contract or provide a positively identified semantic source; no private/numeric/bitmap guessing. |
| UI-R5-DESKTOP | M | ui:44,94,103 | RESOLVED W3: the toggle is forwarded through UIRecordingOptions/LiveEngine; recording-time DesktopIcons mutation/restoration and Finder restarts are removed. Existing legacy markers are restored only during app migration. Default stays false; filter and boundary regressions pass. |
| UI-U2-CAMERA-SIZE | M | ui:132 | RESOLVABLE: public @MainActor CameraFormatPolicy.effectiveSize(deviceID:maximum:fps:) returns optional (width,height); fps defaults60 and uses production30/29.97 fallback. UI can drop its independent largest-image chooser; pass30 when source cap<60. Nil for missing permission/device/compatible format, no prompt/configuration. Injected cap/rate/missing tests added; live camera remains untested (no hardware). |
| CORE-ED10-LOCALES / E2 | M | core:640; editor:241 | RESOLVABLE: TranscriptionService.supportedLocales() -> [Locale] returns actual native identifiers sorted, without prompting/downloading or claiming installed on-device models. Main UI AppDelegate.swift:160–163 already forwards keyterms/options and native locales; UI may use the shared API. Native enumeration/authorization-unchanged regression added. |
| E2-KEYTERMS-ERRORS | M | editor:25,241 | RESOLVED existing: contextualStrings/locale forwarded and unsupportedLocale/onDeviceModelNotInstalled typed errors are implemented; main UI wiring now present. F13 real EN/DE recognition verified by Lead; no new recognition run requested. |
| CUR-06-PRESSED | M | render:300,947 (historical shared handoff) | RESOLVABLE existing: capture logs down/up independently of optional click-ring settings; Core/Render own pressed evaluation from that data. No new captured pressed field needed. Existing input translation/lifecycle tests cover delivery. |
| QA-SOURCE-INPUT-HOOKS | M | qa:283 | RESOLVED existing: CaptureSelfTest supports display/window-title/area, pause, no-audio/out/drive-input hooks; signed UI wrapper supplies TCC attribution. Prior native QA verifies pause/input; real camera/mic/Retina/multi-display remain no-hardware. |
| QA-F8/F9 | M | qa:257,260 | RESOLVED and native QA verified: actual even encoded pixel_size and always display_name for source kinds; regression tests unchanged. |
| R3-SYNC-FIXTURE | L | render:951 | BLOCKED — Lead/QA native real ten-minute flash/beep fixture with identified marker times not supplied; capture must not launch beside user's app/QA lock. Existing QA ten-minute A/V pass is separate from Render's requested oracle artifact. |
| CORE-AUD06-NATIVE | L | core:908; render:385 | BLOCKED — Apple isolation unit unavailable on this host (-10876); explicit unavailable/fallback behavior retained. F14 own Render DSP native objective results already recorded, no microphone hardware. |
| R5-CAP-DEC1 | L | Lead requests-pass decision | RESOLVED: legacy engine excluded; macOS15+ ScreenCaptureKit only. UI read-only engine label matches decision. Native quality/keyframe certification belongs to Lead, not a capture code blocker. |

Progress: H metadata support implemented with the explicit semantic-identity blocker;
M APIs/handoffs implemented and final main capture gate green. RESOLVABLE means
the capture provider is delivered; requester can adopt/remove its blocker. No
independent capture code request remains without the explicit reason in its row. Historical stubs/TCC-denied notes
are superseded by integrated capture APIs and Lead's granted signed-app permissions;
no permission reset, app launch, or other-team source edit is required.

### R5b validation (final candidate, green)

- **173 standalone capture tests /6 suites pass in34.955s**; seven native opt-ins
  were disabled in that run. Native locale inventory is now an eighth opt-in.
  Includes legacy cursor JSON, identity-only classification,
  identical-PNG known/unknown sidecars with distinct IDs, cap/rate/no-device camera
  query and actual native Speech locale enumeration without authorization changes.
  Simulated hour/100 seeded crash trials still pass. No new native recognition,
  encoder, camera/mic or global cursor-type acceptance claimed.
- Fresh **a96173e snapshot plus only owned capture sources/tests** builds through
  canonical scripts/build-app.sh in debug; strict codesign succeeds with
  **Yapcam Dev Signing / mov.yapcam.Yapcam**. No app launched. Rust **127 pass /1
  intentional ignore (19.18s)**. Final **main-snapshot capture suite173 /6 suites
  passes in18.568s**; all Swift test targets compile. Eight native opt-ins disabled;
  no full/native Swift-suite pass claimed for this candidate. No product-source
  change after the signed build; only the native inventory test was made opt-in.
- Native locale inventory passed in an earlier standalone run, but the first
  final SwiftPM run stalled after testing began and was interrupted through its
  own PTY; no cause proven (sampling the owned runner was denied; no sudo used).
  Explicit native inventory recheck:
  `YAPCAM_CAPTURE_LOCALE_TESTS=1 zsh Tests/YapcamCaptureTests/Tools/run_capture_tests.zsh`.
  This does not prompt/download models or certify native recognition. The current
  default main suite passes with inventory disabled; no claim it caused the stall.
- Logs `/tmp/yapcam-capture-r5b-{portable-final,final-app,final-rust,gate-tests}.log`.
  Own final test rootdXACZup1, main buildCYomCNCX and main gateJjy3TFPS were listed
  then removed by traps/defer, including the interrupted run. Earlier completed
  R5b roots were also removed; no broad cleanup/other team's directory touched.
- **Checkpoint required:** `git add` still denied creating worktrees/capture/index.lock.
  Lead commit/rebase all8 owned paths; no stale-source push or Git metadata
  workaround attempted. Suggested commit: capture: publish cursor provenance and
  camera/speech capability queries. New files are CapturedCursorShape.swift,
  CursorMetadataTests.swift, IncomingRequestTests.swift. No source changes outside
  capture ownership, recordings/credentials committed, icon modification, app
  launch, permission change or unrelated PID signal.

### R5b implementation / handoff details

- Cursor wire addition: `InputEvents.swift:26 (shape), CursorSnapshot and recordCursor` optional `shape`, unchanged
  PNG/hotspot/size_points, legacy decode remains compatible. Dedup includes shape
  provenance. Known and custom image-equivalent samples cannot share an ID and
  accidentally authorize replacement. `CapturedCursorShape.swift` contains only
  public AppKit standard-object references and agreed Core/Render wire names.
  **No universal cross-process shape detection is claimed.** On this sandbox,
  repeated AppKit standard lookups may produce distinct empty objects; system
  rasterization is unavailable. Tests inject retained object identities and CPU cursor snapshots to verify the
  classifier and real sidecar/journal path independently of AppKit initialization.
  This is evidence of safe metadata handling, not successful WindowServer
  classification. Acquisition still reads actual system artwork before recording
  a snapshot; no synthetic artwork is used by the production recorder.
- API limit/source: Apple's [currentSystem documentation](https://developer.apple.com/documentation/appkit/nscursor/currentsystem)
  promises matching image/hotspot only; [current](https://developer.apple.com/documentation/appkit/nscursor/current)
  is this application's stack, not necessarily another app's visible cursor.
  Substituting current or comparing bitmaps/numeric IDs would violate R5-CA01's
  positive-provenance requirement. Named Render/Lead blocker is in the row above.
- Camera query `CameraResolution.swift:33` shares production candidate extraction
  and choose policy; it rejects a tempting4K24-only mode that recording cannot use,
  retains native59.94/29.97 rates, honors portrait caps, and never upscales. Public
  default60 is the camera nominal request, not automatic display FPS; UI should
  pass30 for sources below60. No AVCaptureSession created or device locked by query.
- Locale query `TranscriptionService.swift:108` returns Speech's current locale set,
  not a hand-authored language catalog. Recognition still uses on-device-only
  requests and typed locale/model errors; enumeration is not model-install proof.
- **UI desktop-icon request resolved in W3:** `hideDesktopIcons` is forwarded into
  RecordingOptions in LiveEngine; recording-time DesktopIcons.hide/restore and Finder
  restarts are gone (one-time cleanup of a legacy restore marker remains). Both display/area use the filter;
  normal Finder folders remain visible. A desktop-independent window contains no
  desktop icons. Existing filter/default/old-options regression tests cover policy.
- **Main UI adoption checked at a96173e:** system-audio-off, keys-on, sounds-on,
  quick-widget-on, area modifier map and display refresh card have landed; their
  old50efc6d table observations below are superseded by this note. Still pending
  UI: automatic cap0 (AppSettings:189 still60), shared AX readback API (SourceOverlay
  still bool-only WindowAX), capture-filtered CG window candidates, conditional
  sound wait and camera query adoption. W3 supersedes the prior desktop-toggle note.
- Lead R5b decision resolves legacy engine scope: ScreenCaptureKit only/macOS15+,
  read-only engine label. Native HEVC quality/keyframe certification is **Lead's
  acceptance task, not a code blocker**; command remains in R5-CAP-HOST1 below.
- Lead document additive camera/locale methods in SWIFT_API and optional cursor
  shape in FORMATS, review shape provenance/fallback/dedup before integration, and
  checkpoint all owned new files/tests/status together. No recordings/assets or
  credentials included. No app launch, permission change or unrelated PID action.

## R5 parity

Current audit **50efc6d** (Lead checkpoint, parent/main **10aaca6**),
2026-10-17 01:08UTC. This table replaces the pre-R5 baseline; evidence refers to
this checkout, not unintegrated changes in another team's worktree. `git rebase
main` reports up to date; attempted metadata cleanup still logs sandbox lock errors.
Behaviour sources: supplied reference-spec A2–A6, CAP1–7 gap list, website recording
text and Pickwhattosh screenshot; no reference code/assets copied.

Priority follows the capture gap list: **no H capture rows**; M window/area/input
and CAP1/2/3 first, then L defaults/recording controls/crash acceptance. `match`
means the scoped implementation/evidence in the row, not unperformed live testing.
`BLOCKED` names the missing hardware or a concrete request to the owning team in
that row. Cross-team presentation is not mislabeled product out-of-scope. Only the
explicit user exclusions below are out-of-scope. UI requests are delivered through
this status file, as required by TEAMS ownership.

| Priority | ID | Reference behaviour/value | Yapcam now (file:line) | Current audit / concrete blocker |
|---|---|---|---|---|
| M | A2 Display | Display list, native W×H and refresh FPS; single display auto-selects | YapcamCapture.swift:7,61 supplies refresh/scale/pixels; UI SourceOverlay.swift:227 still displays settings.maxFPS | BLOCKED — UI R5-CAP-UI1: show DisplaySource.refreshRate, retain single-display auto-selection and verify direct display menu/overlays. Capture metadata and refresh policy unit-tested. |
| M | A2 Window filtering | Exclude own/system surfaces from window picker | YapcamCapture.swift:81 filters SC candidates via CaptureWindowControl.swift:149; UI SourceOverlay.swift:34 builds a separate CG list | BLOCKED — UI R5-CAP-UI2: intersect CG hit-test rows with CaptureSources.windows IDs so UI cannot bypass the tested own/system filter; keep normal Finder documents. |
| M | A2 Window bounds | Follow moves/resizes, refresh before start; closed source errors | CaptureGeometry.swift:79,116 refreshes SC bounds; RecordingSession.swift:328 checks source; SegmentWriter.swift:122 remaps events | match capture implementation; injected geometry/source-loss tests and earlier native window-move QA. Encoded surface stays fixed for a take; point rect remains separate. |
| M | A2/A5 Window prep | Raise target before start, then refresh bounds | CaptureGeometry.swift:83 best-effort authorized raise before rediscovery; CaptureWindowControl.swift:29 | BLOCKED — Lead R5-CAP-HOST2: native AX raise/readback acceptance through the signed UI. Injected window-selection/resize checks pass; no GUI interaction attempted from sandbox. Ordinary capture does not require AX. |
| M | A2 Window context | Raise/ignore/reset/adjust-to-area/apps→windows/entire-display actions | UI SourceOverlay.swift:236 owns menu; CaptureTarget supports display/window/area | BLOCKED — UI R5-CAP-UI2: verify all actions and reference menu order; use CaptureWindowControl.raise for real-window actions. Capture target conversion/math is implemented. |
| M | A2 Exact size | Resize real window via AX and confirm actual size | CaptureWindowControl.swift:25 returns actual CGRect; typed permission/ambiguity/clamp errors; UI SourceOverlay.swift:175 still calls WindowAX.resize returning Bool | BLOCKED — UI R5-CAP-UI3: replace bool-only AX path with awaited CaptureWindowControl.resize and display typed errors/actual bounds. Lead R5-CAP-HOST2 runs live AX check. Delayed/clamped/ambiguous/denied unit cases pass. |
| M | A2 Size presets | 16:9 1280×720/1920×1080/2560×1440; 4:3 640×480…1600×1200; 9:16 720×1280…1440×2560; 16:10 640×400…2560×1600; square640…1600; fitting only, custom/save/delete | CaptureWindowSizes.swift:11 exact fitting groups; UI SourceOverlay.swift:168 still aspect-fits | BLOCKED — UI R5-CAP-UI3: consume exact preset provider plus saved/custom UI. QA R5-CAP-QA1: confirm intermediate reference sizes/group mapping; supplied spec only gives endpoints for several groups. Current intermediate choices are assumptions, not certified parity. |
| M | A2 Area geometry | Minimum150×150; stay within selected display | CaptureGeometry.swift:37 enforces minimum/containment and even encoded dimensions | match injected scale1/2 and negative-origin multi-display math. Assumption: overlay dimensions are logical points; encoded pixels use display scale. Real Retina/second-display acceptance remains untested (no hardware). |
| M | A2 Area controls | Position/Size; Any,16:9,4:3,1:1,3:4,9:16,custom x:y≥1; arrows1, Shift10, Cmd resize, Cmd+Shift resize10; Esc; saved/remembered area | UI AreaSelector.swift:68,266 owns editing; current keyboard uses Shift resize and Option10 | BLOCKED — UI R5-CAP-UI4: align modifier map to reference, ratio list/order/minimum and saved/remembered-area controls; capture accepts display-local point rects and validates them. |
| M | A2 Camera-only | No separate camera-only capture source; fullscreen-camera is editor layout | YapcamCapture.swift:110 CaptureTarget has display/window/area/device only | match capture API; fullscreen-camera output belongs to editor. |
| M | A3 Camera devices / CAP2 | Off/native devices/default flag; max720/1080/2160, default1080; largest native size within cap, no upscale | YapcamCapture.swift:96,137; CameraResolution.swift:3,28 selects actual supported format/rate | BLOCKED — untested (no camera hardware). Discovery/default/cap/no-device/device-loss paths are implemented and injected tests pass; live format negotiation is not claimed. |
| M | A3 Camera menu | Device/default list, Max resolution submenu720p/1080p/4K, hide preview, off | UI CameraResolutionInfo.swift:58 and toolbar own presentation; capture exposes devices/cap | BLOCKED — UI R5-CAP-UI5: verify complete camera menu grouping/order/off/default indication and selected resolution forwarding. No camera hardware for a live menu/device check. |
| M | A3 Microphone | Permission when needed; native devices/off; live level | YapcamCapture.swift:96,189; AuxiliaryCapture.swift:28; SegmentWriter.swift:218 meters samples | BLOCKED — untested (no microphone hardware). Permission/no-device/loss/meter routing have injected tests; UI R5-CAP-UI5 owns on-demand permission/off presentation. |
| M | A3 Audio selection / CAP1 | All apps / selected bundle-ID checklist / off; independent of picture | SystemAudioSelection.swift:11; CaptureSessionServices.swift:56 separate audio stream; UI RecordingController.swift:227 forwards selection | BLOCKED — Lead R5-CAP-HOST3: record two distinguishable app audio sources and confirm selected/unselected isolation, including selected apps outside recorded window. Policy/routing tests pass; audible native isolation is unmeasured. |
| M | A3 Audio default / CAP1 | System audio off for new preferences | YapcamCapture.swift:136 default false; UI AppSettings.swift:158 still defaults true | BLOCKED — UI R5-CAP-UI1: default systemAudio false when key absent; preserve explicit saved choices. Capture default already matches. |
| M | A3 System gate | Audio requires modern ScreenCaptureKit and macOS13+ | Package.swift macOS15 minimum; CaptureSessionServices.swift:56 creates SCK audio stream | match supported platform; every supported host has modern engine/audio availability. Legacy selector decision is separately blocked below. |
| M | A6 Markers / CAP3 | Active-only source timestamp, pauses removed, durable before acknowledgement | RecordingSession.swift:89; InputEvents.swift:157; RecordingRecovery.swift:106 | match injected lifecycle/journal/recovery tests; marker independent of key-recording permission, preserved only within recovered media range. Hotkey/widget presentation is a separate UI row. |
| L | A2 Device / CAP5 / continuity | USB device60fps, experimental/permission state, continuity/device-frame flag | DeviceScreenCapture.swift / DeviceScreenDiscovery.swift retained from earlier work | out-of-scope — explicit R5 COMMON user decision excludes iPhone/device source and frames; no new work. Existing API retained, real USB remains untested (no hardware). |
| L | A2 Picker keys | 1/2/3 display/window/area; Esc clears mode then closes | UI SourceOverlay.swift:332 and AppSettings.swift:18 own picker state | BLOCKED — UI R5-CAP-UI4: verify source mode keys and two-stage Escape. No capture API work required. |
| L | A3 Camera preview | Floating preview, default square, hide toggle | UI CameraResolutionInfo.swift:58 and preview controller own view/settings; own app excluded | BLOCKED — UI R5-CAP-UI5: implement/verify square default and hide behavior; untested live (no camera hardware). |
| L | A3 Preflight / CAP6 | Muted-camera confirmation, disappeared devices, closed-lid built-in mic warning, permissions/settings path | CapturePreflight.swift:18,33 supplies issues; UI Recording/Preflight.swift:42 resolves choices | BLOCKED — untested (no camera/mic/laptop hardware). All injected issue/continuation cases pass; UI R5-CAP-UI5 verifies prompts before countdown/start cue. |
| L | A3 Resize preflight / CAP6 | AX permission required only for actual window resize | CapturePreflight.swift:23; CaptureWindowControl.swift:34 enforces permission | BLOCKED — UI R5-CAP-UI3: call windowResizeIssue before resize and offer settings; ordinary capture must not demand AX. Denied-permission injection passes. |
| L | A4 Icons | Hide desktop icons off by default; filter capture, no Finder preference changes | RecordingController.swift:231; LiveEngine.swift:32; CaptureFilterPolicy.swift:14,19 retains ordinary Finder windows | match end-to-end forwarding/filter/default tests; recording lifecycle has no Finder mutation or restart. Live permission/display acceptance remains untested. |
| L | A4 Dock/highlight | Hide Dock icon on; dim unrecorded area on | UI AppSettings.swift:177,181 and AreaOutline.swift own behavior | BLOCKED — UI R5-CAP-UI6: verify hide-Dock default/recording lifecycle and dim-outside default; these controls do not belong in capture engine. |
| L | A4 Notes exclusion | Notes/teleprompter invisible in recording | CaptureFilterPolicy.swift:14 and CaptureGeometry.swift:107 exclude entire own app | match capture policy; newly created own overlays remain excluded, not just the initial window list. |
| L | A4 Notes controls | Off; speed0…25, opacity0.4…1, font12…32; Cmd+Alt+/ | UI Toolbar/NotesWindow.swift owns controls and bounds | BLOCKED — UI R5-CAP-UI6: verify notes defaults/ranges/shortcut and section order. Capture exclusion implemented in previous row. |
| L | A4 After recording | Quick widget on by default; settings command Cmd+, | UI AppSettings.swift:187 defaults showQuickExportWidget false | BLOCKED — UI R5-CAP-UI6: set new-preference quick-widget default on and verify after-recording section/Settings action; cloud account gating remains out-of-scope. |
| L | A4 Countdown values | None/3/5/10, default None | UI AppSettings.swift:170; SourceOverlay.swift:136 | match stored allowed values/default in current source. Countdown interaction/visual acceptance is separately assigned below. |
| L | A4 Engine | Auto modern / force modern / force legacy | CaptureSessionServices.swift:42 supports ScreenCaptureKit; macOS15 baseline | out-of-scope — Lead R5b R5-CAP-DEC1 explicitly excludes legacy; ScreenCaptureKit-only/macOS15+ with a read-only engine label. No fake selectable legacy mode. |
| L | A4 FPS / CAP4 | No FPS picker; initial display refresh for display/window/area; device60 | CaptureFrameRate.swift:11; CaptureGeometry.swift:128; RecordingSession.swift:115 persists initial cap; UI AppSettings.swift:173 still60 | BLOCKED — UI R5-CAP-UI1: new-preference cap0, forward automatic unchanged, remove FPS picker from reference controls (SourceOverlay.swift:135 / SettingsWindow.swift:63); explicit saved30/60 may remain Advanced extras. Capture24…240Hz and resume policy tests pass; >60Hz live untested (no hardware). |
| L | A4 Input | Mouse/keyboard on; cursor re-rendered by editor | YapcamCapture.swift:137 default keys true; RecordingSession.swift:229 permission gate; CaptureGeometry.swift:133 cursor false; UI AppSettings.swift:172 keys default false | BLOCKED — UI R5-CAP-UI1: keys on only when preference absent, keep explicit false and granted Input Monitoring gate. Capture default/denied-permission tests pass; cursor exclusion/rerender policy retained. |
| L | A4 Screen encoding / CAP4 | HEVC quality0.85; keyframe interval2× refresh (2s) | SegmentWriter.swift:284 requests quality/expectedFPS/keyframes; :315 native fragments; canApply validates requested settings | BLOCKED — Lead R5-CAP-HOST1: native writer/decoder gate, command below. Sandbox encoder returns -12903; requested dictionary tests pass but effective HEVC quality acceptance is not verified. |
| L | A4 Camera encoding / CAP2 | HEVC quality0.6; resolution cap | SegmentWriter.swift:284 requests0.6 camera quality and30/60fps; CameraResolution.swift:28 caps actual formats | BLOCKED — Lead R5-CAP-HOST1 checks synthetic camera encoder track; real camera acceptance untested (no hardware). Requested quality values are tested, not certified encoder behavior. |
| L | A4 Own windows | Exclude app windows throughout recording | CaptureFilterPolicy.swift:14; CaptureGeometry.swift:107; CaptureExclusions in YapcamCapture.swift:265 | match capture policy and prior native toolbar exclusion QA. No reference assets or sounds introduced. |
| L | A4 Unsupported appearance controls | No Do Not Disturb / hide notch / hide menu bar controls | RecordingOptions in YapcamCapture.swift:122 exposes none of these controls | match capture API; any own optional extras remain after reference sections, per Lead decision. |
| L | A5 Start gating | Valid source/area≥150×150 and permissions before recording | RecordingSession.swift:39,46; CaptureGeometry.swift:37,79 | match injected start/permission/disappearance/area tests; no package or active stream created for invalid preflight conditions. |
| L | A5 Countdown interaction | None immediate; ring/remaining seconds; Enter skip; cancel returns picker | UI RecordingController.swift:282 starts capture after countdown/cue | BLOCKED — UI R5-CAP-UI6: verify ring/seconds/continue/skip/cancel and immediate None behavior. Capture only starts when UI calls start; sequencing tests pass. |
| L | A5 Sounds / CAP7 | Own begin cue0.33 before capture; ≤540ms wait only with audio inputs; end cue on stop | UI StartSound.swift:13; RecordingController.swift:289 awaits unconditionally when enabled; CaptureSessionServices.swift:59 excludes own audio | BLOCKED — UI R5-CAP-UI7: await gate only for mic/system audio, play without video-start delay otherwise; retain0.33/540ms and stop cue. Audible playback untested; capture excludes own process audio. |
| L | A5 Dock badge | Recording dot badge | UI AppDelegate.swift owns app activation/Dock state | BLOCKED — UI R5-CAP-UI6: verify recording badge lifecycle; no capture-layer presentation work. |
| L | A6 Widget | 48pt, nonactivating, excluded, avoids captured bounds, saved position, default on; Cmd+Alt+' | UI AppSettings.swift:184 default on; CaptureFilterPolicy.swift:14 excludes own app | BLOCKED — UI R5-CAP-UI8: verify height/nonfocus/avoidance/position persistence/shortcut. Capture exclusion matches and requires no extra window registration race. |
| L | A6 Timer/pause | Total active elapsed survives pause/resume; stop finishes take | RecordingSession.swift:76,103,135,309; UI formats elapsed | match capture active-time/segment tests and prior native pause QA. UI R5-CAP-UI8 must verify timer formats0:00→00:00→0:00:00→00:00:00. |
| L | A6 Restart/cancel | Confirm then restart or delete/reopen picker; rebindable shortcuts | RecordingSession.swift:152 serializes cancel/deletes; UI RecordingController.swift recreates session | BLOCKED — UI R5-CAP-UI8: verify prompts and Cmd+Alt+Backspace restart/cancel bindings. Capture deletion/serialization unit tests pass. |
| L | A6 Busy | Disable actions during work; spinner after3s | CaptureOperationGate.swift serializes operations; UI RecordingController.swift owns busy feedback | BLOCKED — UI R5-CAP-UI8: verify disabled controls and3s spinner; capture nonoverlap/coordinator tests pass. |
| L | A6 Marker shortcut | Cmd+Alt+Ctrl+F; action only while recording | RecordingSession.swift:89 rejects inactive state; UI owns shortcut/widget button | BLOCKED — UI R5-CAP-UI8: verify hotkey/button forwarding and inactive-state disablement. Capture timestamp/durability is the matched M row above. |
| L | A6 Tray / activation | Menubar stop icon/action while active; dock activation asks finish; recording/project drop actions | UI AppDelegate.swift / Support/MainMenu.swift own tray/activation/import dispatch | BLOCKED — UI R5-CAP-UI8: verify stop/activation prompt and supported Yapcam project/preset drops; proprietary reference file import is a Lead scope decision, not implicitly claimed. |
| L | A6 Low disk | Auto-stop with explanation | RecordingSession.swift:328 health check; PackageIO.requireSpace1GB; injected low-disk lifecycle tests | match capture failure behavior; UI presents returned warning/error. No disk-filling live experiment performed. |
| L | A6 Errors/recovery | Finalize/recover retained footage; recover-now option when finish fails | RecordingSession.swift:371; RecordingRecovery.swift:28,106; RecordingPackageLease.swift:5 | match capture injected failure/recovery paths and real-file SIGKILL gate. UI R5-CAP-UI8 verifies recover-now presentation; uncommitted tail can be lost. |
| L | Website crash safety | About2s disk saves, readable recovery after abrupt loss | SegmentWriter.swift:64,315; CaptureDiskCheckpoint.swift:19; InputEvents.swift:171; Tools/run_crash_recovery.zsh | BLOCKED — Lead R5-CAP-HOST1: native HEVC/static fragment kill/recover gate. Three real CPU H.264 producer SIGKILLs pass (4/6/8s recovered, ≤0.700s tail loss); hour simulation/100 trials pass. Physical power failure not tested; no zero-loss/power-loss guarantee. |

### R5 priority closure and assumptions

This reconciliation changes **only this status file**. Whitespace/diff checks pass;
product sources/tests remain exactly50efc6d. `git add docs/status/capture.md` was
denied creating index.lock; Lead must checkpoint this documentation. The167 capture tests,113 Rust tests
and signed debug app results below were already collected; no new live/full-suite
pass claimed and no app launched.

- **M: 17 rows — 5 match, 0 out-of-scope, 12 concrete blockers; zero unassigned mismatch/missing rows.**
- **L: 31 rows — 9 match, 2 out-of-scope, 20 concrete blockers; zero unassigned mismatch/missing rows.**

H/M reconciliation completed before the L pass; L pass also completed. No remaining
capture-owned code change can resolve the listed UI ownership/native-service or
hardware blockers. READY is a review/integration handoff with those open gates,
not full live/reference certification. No new scope/defaults introduced by this
reconciliation. Window/area sizes are logical points; encoded pixels remain even
and source point rect is separate (F8/F9). Exact intermediate preset lists still
need QA evidence; no guessed list is marked verified. Capture's old explicit30/60
values remain compatible extras after reference controls.

### R5 Requests (current; IDs used in rows)

- **UI R5-CAP-UI1:** adopt new automatic cap0, show display refresh, default new key
  recording on (permission gated) and system audio off, preserve explicit saved
  choices. Remove FPS selectors from reference controls; explicit caps may remain
  Advanced extras. API: `DisplaySource.refreshRate`, `RecordingOptions.maxFPS = 0`,
  `recordKeystrokes = true`. Manifest max_fps stays resolved positive and fixed
  across pause/resume.
- **UI R5-CAP-UI2:** apply capture's filtered window IDs to the separate CG picker
  and reconcile complete context actions/order; retain normal Finder documents.
- **UI R5-CAP-UI3:** use `try await CaptureWindowControl.resize(windowID:to:) -> CGRect`,
  typed actual-size/ambiguity/permission errors, `CaptureWindowControl.raise`,
  `CaptureWindowSizePreset.fitting(in:)`; use resize preflight/settings path.
  Replace old first-bounds-match bool AX writes and aspect-fit preset labels.
- **UI R5-CAP-UI4:** area modifier map is arrows1/Shift10/Cmd-resize/Cmd+Shift10;
  verify ratio/custom/saved/remembered area and picker1/2/3/Escape behavior.
- **UI R5-CAP-UI5:** camera/mic menu order/default/off/preview and preflight prompts;
  device code/injections pass, physical camera/mic/laptop checks remain no-hardware.
- **UI R5-CAP-UI6:** recording gear defaults/order, Dock/highlight/notes controls,
  after-recording quick-widget default on, countdown behavior and Dock badge.
- **UI R5-CAP-UI7:** own sound0.33/540ms policy already exists; await only when
  mic/system audio records, otherwise play without delaying video start.
- **UI R5-CAP-UI8:** widget48pt/nonfocus/avoidance/saved position, elapsed formatting,
  busy spinner3s, restart/cancel/marker shortcuts, tray/activation/recovery UI.
- **QA R5-CAP-QA1:** confirm full intermediate window-size lists/group mapping
  (supplied reference spec explicitly says partly inferred). Known16:9 values and
  other groups' endpoints/fitting behavior implemented; exact intermediate parity
  remains blocked on this request.
- **Lead + UI R5-CAP-DEC1 RESOLVED (R5b):** legacy engine excluded; retain
  SCK-only macOS15+ read-only engine label. Separate request: decide
  proprietary reference-format drop/import scope; own format drop remains UI.
- **Lead R5-CAP-HOST1 — native encoder/crash gate, no app launch needed:** from
  capture checkout run `zsh Tests/YapcamCaptureTests/Tools/run_crash_recovery.zsh`.
  Fresh signed CLI injects64×64 screen/camera frames, waits for native fragments,
  SIGKILLs only its own child at three seeded points (including static-screen
  heartbeat), recovers and decodes both tracks. Requires ≤2.1s lost tail, contiguous
  source time, retained marker and unchanged original media bytes. Own temp tree
  listed/deleted by trap. Sandbox encoder fails **-12903**, not a pass. Requests
  HEVC0.85/0.6 and2xfps/2s keys; no claim that requesting quality proves support.
  Physical power-loss durability is not measured by a process-kill fixture.
- **Lead R5-CAP-HOST2:** after UI adopts exact-size API, native AX raise/resize a
  known resizable window, check requested/actual bounds and app-clamped error.
  Already-granted signed app permissions are not reset. Respect QA `.app-lock`,
  user's existing instances and LaunchServices launch rule; no live action here.
- **Lead R5-CAP-HOST3:** selected-app audio isolation with two native sound sources;
  confirm unselected source excluded even when its window is the picture source.
- **Lead:** checkpoint this status reconciliation; capture code already committed
  by Lead in50efc6d. Document public additions/defaults in SWIFT_API; arrange
  other-family review of critical writer/recovery changes per TEAMS rule10, and
  full native Swift suite (six E2E Metal-unavailable failures in sandbox).
- **Lead process cleanup:** capture-owned obsolete SwiftPM PID25886 and the second
  capture test waiting on its lock (`r5-checkpoint-tests.log`) were reported
  previously; sandbox denied SIGINT of own PID. No app/other-team process touched.
  Fresh validation used isolated capture test/build roots with cleanup traps.

**Available sandbox gate:** same native script with `--software-fixture` passed
three CPU H.264 SIGKILL/production-recovery/decode trials:4/6/8s,120/180/240 frames,
2/3/4 complete fragments, missing tails0.467/0.367/0.700s. Original media hashes
unchanged, stale events trimmed, retained marker preserved, monotonic PTS and
≤2.05s keyframe gaps. This is actual real-file recovery, **not native HEVC writer
acceptance**. Installed FFmpeg is test tooling, no bundled dependency. All owned
fixture/build roots listed/deleted. Log `/tmp/yapcam-capture-r5-software-crash.log`.

### R5 M package (historical validation; now checkpointed in50efc6d)

Baseline c6ae74a + owned changes, **debug**, M4 macOS26.3 sandbox. Full capture
**157 tests /6 suites pass, 19.036s** (native Speech/media opt-ins still disabled);
Rust **113 pass /1 intentional ignore**. Canonical `scripts/build-app.sh` debug
build + strict codesign pass, **Yapcam Dev Signing / mov.yapcam.Yapcam**. No app
launched. Logs `/tmp/yapcam-capture-r5-{m-tests,m-app,rust}.log`.

- Public `try await CaptureWindowControl.resize(windowID:to:) -> CGRect` uses
  fresh CG ownership/bounds + public AX APIs, rejects ambiguous matches, checks
  resizability, waits for readback and throws typed `sizeNotApplied` when an app
  clamps the request. Explicit `try CaptureWindowControl.raise(windowID:)` and
  best-effort already-authorized raise before window preparation; capture itself
  still works without Accessibility. Negative multi-display origins remain points.
- Public `CaptureWindowSizePreset.fitting(in:)` returns exact sizes/group order,
  never aspect-fits a differently-sized window under a preset label. Canonical
  16:9 sizes match the known list. Intermediate classic/wide/square presets are
  conservative own choices within the reference's known endpoints (not asserted
  as extracted exact values); UI can append its saved/custom sizes.
- Picker omits own/system/nonstandard-layer surfaces but retains ordinary Finder
  documents. Area validation enforces150x150 logical points at scales1 and2.
- Tests exercise delayed successful resize, app clamp, ambiguity, title-based
  disambiguation, permission refusal, nonresizable/invalid requests, exact preset
  filtering, picker inclusion and area minimum. **Live AX resize remains untested**:
  no launch/interaction attempted from sandbox. UI: consume the public exact-size
  API instead of assuming AX write success implies the requested size took effect.

### R5 final implementation and verification (00:42UTC)

**Code checkpointed by Lead as50efc6d**, parent/main10aaca6. Evidence below
was collected before that checkpoint on c6ae74a + the same owned R5 sources,
**debug**, Mac mini M4 / arm64 macOS26.3, Swift6.3.3. Main advanced to
**10aaca6** during validation (editor/QA changes); Lead included it as the checkpoint
parent. Current main is an ancestor of50efc6d; no rebase is outstanding.
Only capture source/tests/status changed; no app/icon/assets or
other teams' source modified. No Yapcam app launched or user instance signalled.

Final gates on unchanged product sources:

- Fresh standalone **167 capture tests /6 suites pass in19.296s**, seven native
  opt-in cases disabled (not native passes). Includes actual CoreMedia image
  retention/retiming, a queued-heartbeat versus stop race, delayed/clamped AX
  operations, permission-gated default key recording,30/60/120/144Hz limiter
  samples, automatic24…240Hz policy, pause/resume persistence, coalesced slow-disk
  checkpoints and propagation of async disk errors. Simulated hour/100 seeded
  recovery trials still pass. The no-device test now injects discovery failure;
  live code creates an AVCaptureSession only after identifying an authorized,
  connected device, avoiding unnecessary native session work for missing inputs.
- Canonical **debug app builds**, including Rust release archive rebuild; strict
  signature verification passes, **Yapcam Dev Signing / mov.yapcam.Yapcam**.
  Built with a fresh owned SwiftPM scratch directory, not old locked artifacts.
  Rust **113 pass /1 intentional ignore**.
- **Three actual CPU-fixture SIGKILL/recovery trials pass**, details above. These
  exercise production recovery on real H.264 fragments and software decoding;
  they do not substitute for native HEVC writer acceptance.
- Full Swift suite was also attempted against c6ae74a + R5 sources: all targets
  compile, but **six E2E export tests fail with Metal unavailable** in this sandbox;
  the run subsequently did not finish around renderer speech tests and was
  interrupted through its own PTY. **No full-suite pass claimed.** Its scratch
  directory was listed/removed. Lead runs the full suite on the native host.
- Logs: `/tmp/yapcam-capture-r5-{capture-final,app-only,final-rust,software-crash,all-swift}.log`.
  Fresh final test/build and CPU fixture roots were listed/deleted by traps; unit
  runner scopes its temporary media under its own cleanup root. Two earlier
  plain-pipe SwiftPM processes still require Lead cleanup as requested above.

| Baseline gaps | R5 result | Remaining acceptance/owner |
|---|---|---|
| A2 exact resize/presets | Public AX API confirms actual bounds or explicit failure; exact fitting presets; safe unique target selection | UI consume API; live AX untested in sandbox |
| A2 own/system source list and area minimum | Filter policy +150-point minimum at scales1/2 tested | Live/Retina/multi-display picker acceptance UI/QA |
| A4 display-following capture | Default maxFPS0; display refresh exposed; resolved positive fps retained across pause/resume | UI adopt automatic instead of passing stored60;>60Hz hardware untested |
| A4 keys | Default on; denied Input Monitoring means no key records; persisted false respected | UI default/permission presentation |
| A4 encoding | Request HEVC screen0.85/camera0.6,2xfps keyframes and2s duration; native settings capability checked | Native encoder/quality behaviour not certified in sandbox; strict native command above |
| Website about2s save/crash | Periodic bounded background fsync, durable marker ack/final flush; static images retimed1Hz; real-file SIGKILL recovery tested | Native HEVC/static writer command outside sandbox; physical power failure not simulated |
| CAP1/2/3/6 already present | Existing per-app audio, camera caps, markers, preflight retained, injected tests green | Selected-app native isolation; no camera/mic/laptop/USB hardware |
| CAP7 | Existing own chime gain/timeout inspected | UI fix conditional wait for no-audio case; no sound copied |

Encoding note: AVFoundation/VideoToolbox quality constants **alias the same key**;
using the VT name is not proof of HEVC support. The code requests0.85/0.6 and
requires `canApply` before writing; effective codec behaviour still needs the
native gate. Apple documents the compression property dictionary and codec-specific
quality support: [AVVideoCompressionPropertiesKey](https://developer.apple.com/documentation/avfoundation/avvideocompressionpropertieskey),
[VT quality](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_quality).
No unsupported-key success is counted as a quality measurement. No new package
schema: session.max_fps remains a **resolved positive integer**, logical point rect
and even encoded pixel size remain distinct. Lead update SWIFT_API defaults and
DisplaySource/window-control additions; QA update CAP4 from this scoped evidence.

The current row-level audit above supersedes the old baseline/result table.
No other features or earlier-round leftovers started. All unverified live camera/mic/Retina/second-display/device checks remain
**untested (no hardware)**.

## RC0.9.0 freeze handoff (2026-10-16)

Capture stops at the requested code freeze; no new scope, defaults or contracts.
Worktree **dfcbc9e** is clean before this documentation update. Capture source/tests
match main **ddfd9d4**, with no unfinished capture implementation or uncommitted
code to defer. Latest speech build is the strictly verified **f8a4770 signed debug**
tool, Mac mini M4 / arm64 macOS26.3. No new app launch or code/test change during
this freeze handoff; documentation whitespace check passes. Lead checkpoint of
this status remains required because sandbox Git metadata writes are denied.

**Completed native F14 evidence:** Lead's retained `capture-f14/metrics.json` and
per-language `outcomes.json` now exist. Default Voice DSP improves SI-SDR from
10.00dB input to **15.68dB English / 15.47dB German**. Noise-only final-second
reduction is **34.03 / 29.97dB**; output loudness **-16.13 / -16.10 LUFS**, sample
peak **-1dBFS**, zero clipped samples, original sample counts preserved. These
objective checks pass on the generated speech files; pumping/timbre listening is
still pending. Native word/pause/candidate-filler cut mapping passes; that does
not establish good filler recognition. Apple offline isolation remains explicitly
unavailable on this host, with built-in DSP alternatives offered.

**Open for RC notes (capture/speech acceptance):**

- Automatic filler removal is weak: native labeled hesitation recall **0/3** per
  language; German's one candidate is a grammatical word. Editor owns contextual
  false-positive handling. Do not claim reliable automatic cleanup.
- Speech sentence-boundary medians **45–70ms**, outliers up to **810ms**; interior
  word timing has no independent alignment ground truth. No universal ±200ms claim.
- Speech quality listening, offline/network-disabled acceptance and missing-model
  host acceptance remain open. On-device request enforcement and typed errors have
  deterministic coverage; they do not certify every host/model configuration.
- Real microphone/camera/USB device, Retina and multi-display capture remain
  **untested (no hardware)**; injected failure and geometry tests do not replace them.

**Open-medium, render-owned (Lead's freeze report; not measured by capture):**

- **F17**, main **b1859a4**, native **release**, M4/macOS26.3 synthetic4K60 random
  scrub: **p95 232ms**, improved from466ms; **p50 149ms**. Remains open-medium.
- **F18**, same reported native release benchmark: synthetic4K export **0.98x
  realtime**. Remains open-medium. These render-pipeline measurements are not
  editor interaction tests. Lead/render should carry both into RC notes.

## F14 fresh signed native speech handoff (historical preparation, 2026-10-16)

**Prepared and subsequently run by Lead; objective results above.** Built from the exact clean **f8a4770** source
snapshot, including render's new `SpeechNoiseReduction.swift`, on Mac mini M4,
arm64 macOS26.3 / Swift6.3.3. Rust release archive rebuilt; all Swift modules and
the speech harness rebuilt in **debug**, without skip-build or reused object
files. App strict signature verification passes: **Yapcam Dev Signing**,
**mov.yapcam.Yapcam**. No app launched by capture; native F14 SI-SDR and pause-noise
results are recorded above; listening acceptance remains pending Lead.

App: `~/Movies/Yapcam/QA/speech/capture-f14-tool/Yapcam.app`.
Fresh fixtures: `~/Movies/Yapcam/QA/speech/capture-f14`, prepared with
`prepare_speech_rerun.py` from `capture-round3`. Each language contains only the
five original inputs, verified byte-identical: clean/noisy/noise WAVs, screen MOV,
ground truth. Previous outputs preserved. No recordings committed.

Original host command (already run; do not reuse the populated output directory):

```sh
zsh "$HOME/yapcam-team/capture/Tests/YapcamCaptureTests/Tools/launch_speech.zsh" "$HOME/Movies/Yapcam/QA/speech/capture-f14-tool/Yapcam.app" "$HOME/Movies/Yapcam/QA/speech/capture-f14"
```

Its launcher atomically owns the QA app lock, refuses other running app instances, and uses
`open -n -W` through LaunchServices. Speech permission is already granted; no
permission-request flag needed. After it finishes, measure with:

```sh
python3 -B "$HOME/yapcam-team/capture/Tests/YapcamCaptureTests/Tools/speech_metrics.py" "$HOME/Movies/Yapcam/QA/speech/capture-f14"
```

This harness produces **default Voice** DSP (`dsp.caf`) for both languages,
alongside transcription/edit checks and the optional Apple isolation attempt;
it does not run all three DSP presets. Compare `metrics.json` against the retained
F13 baseline: SI-SDR should not fall below input and final noise-only second should
be reduced at least10dB. Render's separate all-preset objective checks are recorded
in its status; these do not substitute for Lead's native rerun/listening.

Provenance: adjacent `capture-f14-tool/build-provenance.json` records full commit,
source SHA256s, configuration, environment and executable SHA256
`6b9871bbf1e938c6b75462c222ae2874c0d378e7173435ee9b2c09c2be60ca0d`.
Hashes verified against Git blobs at f8a4770. Build log:
`/tmp/yapcam-capture-f14-build.log`. Both capture-owned temporary build directories
were listed and removed by cleanup traps after successful signing.

**Historical rebase handoff at preparation:** `git rebase main` failed creating
`rebase-merge` (sandbox metadata permission). Worktree HEAD was **1a590ae**; no source changes made to
other teams' files. To avoid a stale DSP binary, built via read-only `git archive`
of f8a4770 into the disposable capture-owned directory. Lead should checkpoint this
status and rebase the worktree; the prepared app already contains f8a4770.
Lead subsequently checkpointed the handoff as **38a5ca7** and advanced this worktree
to **dfcbc9e**; no f8a4770 rebase request remains outstanding.

## Round 3 speech verification (2026-10-16)

### F13 native verification complete

Fix commit **dd39be4**, now integrated; current HEAD/main **a7d1526**. Native
verification by **Lead**, signed **debug** speech harness, Mac mini M4 host, Speech
permission granted, on-device recognition, generated English/German clean and
10 dB SNR noisy files. This verifies file processing; microphone capture remains
untested (no hardware), and this is not a user-interaction test. No app launched
by capture. Lead's retained `capture-f13/metrics.json` and `outcomes.json` confirm:

| Language/input | Recognized tokens / reference | WER | Sentence-boundary median / max | Boundary coverage |
|---|---|---|---|---|
| en-US clean | 154 / 162 | 9.26% | 70 / 120 ms | 21 / 24 |
| en-US noisy | 156 / 162 | 9.88% | 45 / 810 ms | 20 / 24 |
| de-DE clean | 163 / 163 | 8.59% | 50 / 790 ms | 20 / 24 |
| de-DE noisy | 163 / 163 | 8.59% | 60 / 790 ms | 20 / 24 |

**F13 truncation is verified fixed by Lead.** Counts are lexical tokens; 163/163
is not 100% accuracy (substitutions/deletions/insertions remain). Timing truth is
10 ms sentence PCM activity bounds, scored on matched first/last words. Interior
word timing is not independently aligned; outliers to 810 ms mean a blanket
±200 ms word-timing guarantee is not established.

**Measured filler limitation:** the shared dictionary finds 0 / 3 candidates in
English and 1 / 3 in German, clean and noisy. Alignment finds **0 / 3 actual labeled
hesitations** in each language. German's one candidate is the grammatical **um**
in **um halb zehn**, not an inserted äh/ähm. Thus the summary "0–1 of 3" is an
upper bound on candidates, not verified true filler recall. Apple on-device Speech
omits the intended hesitations here; filler removal is weak even though cut mapping
works. Do not claim reliable automatic filler cleanup. Editor's locale/context
false-positive request remains open.

Native actual transcript editing path also passes: word cuts, candidate-filler cuts
and pause tightening preserve the expected source ranges. English pause cuts: 9
clean / 8 noisy; German: 6 / 8. Candidate removal being mechanically correct does
not establish good filler detection. Native AU failure presents the explicit DSP
alternative message as intended. **F14 DSP quality is assigned to render**; its
baseline noise/loudness metrics below remain failing evidence, not F13 acceptance.

Root cause in capture: request disabled interim results and discarded every
non-final callback. A final tail-only hypothesis replaced the request's complete
history. The fix enables interim results and merges timed hypotheses per window:
retain the earlier nonoverlapping prefix; replace a revised suffix; publish the
merged history only when final. Each window owns its recognizer/history, preventing
cross-window state/cancellation reuse. Existing midpoint ownership deduplicates
window overlap. Feed Speech independent PCM packets <=4096 frames, preserving all
channels/frames rather than one 45-second packet. No public signature or transcript
schema changes; requests remain on-device-only.

Verification of final source: full capture **150 reported tests / 6 suites, 7 native
opt-in skips, zero failures, 18.107 s**. Includes injected multi-result recognizer
with interim utterances / final-only-last, cumulative corrections, tail revisions,
two-window ownership (words at 1/20/44.6/54/64 s), and byte-exact interleaved/planar
stereo packet tests. Simulated hour / 100 crash trials pass. Python **7 tests**
pass. Rust **104 pass / 1 ignored**. Canonical **release** app build and strict
signature verification pass (Yapcam Dev Signing); new **debug** F13 speech harness
also builds/signs/verifies. No app launched by capture. Logs:
`/tmp/yapcam-capture-f13-{full-tests,app,rust,harness-build}.log`.

Lead completed the native run in `~/Movies/Yapcam/QA/speech/capture-f13` using
`~/Movies/Yapcam/QA/speech/capture-f13-tool/Yapcam.app`. Reports and media remain
outside Git; original baseline and rerun inputs are preserved. The guarded
LaunchServices and metrics commands in the test README reproduce this procedure;
use a fresh input-only destination for any additional run. No F13 rerun is requested.

#### Measured failing native baseline (before fix)

Capture measured Lead's retained native outputs with the deterministic tools.
Timing is matched first/last sentence-word residual (10 ms PCM activity truth), not
interior-word forced alignment. Sparse coverage makes these timing values unsuitable
as a full-file timing pass. WER ignores case/punctuation only. SF segments can contain
multiple lexical tokens, so token counts differ from native segment counts.

| Language/input | WER | Recognized tokens / reference | Timing median / max | Boundary coverage |
|---|---|---|---|---|
| en-US clean | 89.51% | 17 / 162 | 45 / 50 ms | 2 / 24 |
| en-US noisy | 89.51% | 18 / 162 (13 SF segments) | 45 / 50 ms | 2 / 24 |
| de-DE clean | 77.91% | 40 / 163 (38 SF segments) | 50 / 790 ms | 5 / 24 |
| de-DE noisy | 77.30% | 40 / 163 (38 SF segments) | 70 / 790 ms | 5 / 24 |

All three labeled fillers in each language are missed in this failing baseline.
Independent FFmpeg metrics for the native harness's **default render DSP** output:

| Language | Input SNR | LUFS input -> output | SI-SDR input -> output | Noise-only final second input -> output | Peak / clipped samples |
|---|---|---|---|---|---|
| en-US | 10.000 dB | -18.23 -> -16.15 | 10.002 -> 0.450 dB | -28.361 -> -18.601 dBFS (9.761 dB louder) | -1.000 dBFS / 0 |
| de-DE | 10.000 dB | -21.63 -> -16.29 | 10.002 -> 1.992 dB | -31.854 -> -20.084 dBFS (11.769 dB louder) | -1.000 dBFS / 0 |

Exact frames retained: EN 3,181,440 / DE 3,841,920 at 48 kHz. SI-SDR includes
intentional filter phase/compression distortion and is not isolated noise power.
Quiet-tail RMS is measured only after the clean stem proves no speech. Loudness/
clipping pass alone does not establish enhancement quality; **Lead listening for
pumping/voice quality and render review remain required**. These are default-chain
measurements, not separate Noise reduction/Podcast preset measurements. Full JSON:
`~/Movies/Yapcam/QA/speech/capture-round3/capture-f13-baseline-metrics.json`.

#### AUSoundIsolation -10876 / preset paths

SDK identifies -10876 as **kAudioUnitErr_NoConnection**; maximum-frame failure is
-10874, format failure -10868. The host AU reports no input connection despite the
supplied pull callback. Its native offline connection repair is not claimed. Per
F13's allowed fallback resolution, capture now maps this status to a UI-facing
**unavailable** message: offline processing cannot run; choose Noise reduction or
Podcast for built-in processing. It preserves original audio, removes partial
output and publishes no fake enhancement; regression test passes.

Both actual presets use `SpeechEnhancer.prepareMicrophoneFile` / `SpeechProcessor48k`
in render (shared preview/export), **not VoiceIsolationService/AUSoundIsolation**:

| Preset | Actual built-in recipe from core/render |
|---|---|
| Noise reduction | High-pass 80 Hz; expander threshold -42 dB, reduction 18 dB; compressor ratio 1; loudness normalization off; peak ceiling -1 dBFS |
| Podcast | High-pass 90 Hz; expander threshold -45 dB, reduction 12 dB; compressor threshold -20 dB, ratio 4; normalize to -16 LUFS; peak ceiling -1 dBFS |
| Voice | Explicit preset selection disables this DSP; existing original/selected mic source retained |

No automatic switch/fake Apple enhancement was introduced. The default-chain DSP
numbers above do not certify either preset's denoising quality.

#### Remaining handoffs after F13 verification

- Render: **F14 assigned by Lead**. Review default DSP at the external noisy/dsp.caf files and metric
  JSON above. Noise-only tail gets louder by 9.761 / 11.769 dB after processing;
  SI-SDR drops (includes phase/compression). Lead listen; investigate threshold /
  compression / normalization before claiming noise reduction on 10 dB SNR speech.
  Capture does not edit render files. Native AU unavailable remains explicit.
- Editor: `Transcript.swift` uses a shared locale-independent filler dictionary;
  it classifies German **um** in **um halb zehn** as a filler. Exact static repro:
  a German caption word `um` makes `EditorModel.isFiller` return true; removing
  fillers would cut the grammatical preposition. Our generated DE fixture has this
  in sentence 2; true labeled hesitations are only the three sentence-leading
  äh/ähm tokens. Add a locale/context regression and avoid this false removal.
- Lead: F13 native verification is recorded above and in FEATURES AUD-10 by your
  explicit request. No capture code change or repeated native run is needed here.
  Keep reliable filler detection, timing outliers and render's F14 quality work
  distinct from the resolved truncation defect.

### Addendum: keyterms and typed errors

Commit **ef11c61 + follow-up test/docs/tool diff**, **debug**, Mac mini M4 sandbox.
Lead checkpointed/rebased onto main b9c0b08 during this task. Procedure:
`zsh Tests/YapcamCaptureTests/Tools/run_speech_policy_tests.zsh` builds **current**
capture sources into a temporary static library (no SwiftPM lock), then compiles
and runs the real policy/transcription regression files. Result: **29 reported
Swift tests / 2 suites, 3 native opt-in skips, zero failures** in 0.033 s after
compilation. Cleanup trap removed library/module cache/runner. Actual editor/core
contract also passes when linked against the freshly compiled capture module.

Implemented default-empty keyterms forwarding through every segment and native
window to contextualStrings. No package schema change, logging, persistence,
model download, server fallback or permission prompt. Tests prove Unicode/phrases,
default-empty behavior, independent requests, exact Apple missing-assets mapping,
locale-vs-model-vs-service distinction, cancellation/no-speech preservation and
atomic preservation of previous JSON on typed failures. Missing models are inferred
only from Apple's documented native missing-assets callback, not from a generic
availability Boolean. Native contextual-bias accuracy remains unmeasured.

### Requests → editor (Round 3 addendum)

The public API is additive; existing callers compile with the default empty array:

```swift
try await TranscriptionService().transcribe(
    package: package, localeIdentifier: "de-DE", track: .microphone,
    keyterms: ["Yapcam", "Clara Weiß"])
```

Handle `TranscriptionError.unsupportedLocale(String)` for a locale absent from
Apple's supported set, `TranscriptionError.onDeviceModelNotInstalled(String)` for
the documented `kLSRErrorDomain` / 102 missing-assets callback, and the retained
`.onDeviceUnavailable(String)` for unsupported offline capability / transient
service unavailability. Permission errors remain separate and take priority.
Localized messages identify the locale. Apple documents the distinct semantics in
[task errors](https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/error)
and [offline support](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition).

Editor/UI: forward requested keyterms through the app's transcription closure, and
present these error categories distinctly; the current closure already propagates
errors, but the editor module does not directly depend on capture, so typed UI
mapping can live in the app bridge. Lead: add this signature/error addition to
SWIFT_API.md. Capture changes no other team's files. Fresh debug signed tool uses
the new API; native host run remains pending. Test log:
`/tmp/yapcam-capture-round3-addendum-tests.log`; editor/core log:
`/tmp/yapcam-capture-round3-addendum-contract.log`.

### Original Round 3 acceptance evidence

Scope for the original results below: commit **37cc463 + initial capture diff** (now
checkpointed in ef11c61), **debug**,
Mac mini M4 sandbox, no microphone/camera, generated-file processing only. Main
b9c0b08 is UI-only; Lead has now rebased capture onto it. The tools and policy
regressions are ready for Lead to checkpoint; native speech acceptance is BLOCKED.

| Procedure | Result |
|---|---|
| `say` Anna / Daniel / Samantha probes, ffmpeg PCM decode | Each exits 0, but writes zero audio frames (4096-byte AIFF header). Generator rejects empty speech. No fake audio substituted. |
| Native Speech admission probe | Permission denied; actionable error returned in 0.315 ms (de-DE), 0.145 ms (en-US), 0.134 ms (zz-ZZ). No dialog/reset/network fallback. Permission takes priority over locale validation. |
| Shared on-device request/locale/authorization policy regression tests | PASS. Every production window uses `requiresOnDeviceRecognition=true`; unsupported locale, absent local support, unavailable service, permission denial and request timeout/cancellation are tested. Public API/defaults unchanged. |
| Focused capture speech/transcription runner | PASS: Swift Testing reports 26 tests / 3 suites, 4 opt-in native tests skipped, zero failures. Existing built bundle run through Xcode's swiftpm-testing-helper with matching framework/library paths. |
| Measurement regressions | PASS: 4 Python tests for WER alignment/errors, normalization preserving German fillers/numbers, boundary timing coverage and gain-fitted distortion/clipping/length checks. |
| Actual EditorModel → CoreEditingProject → Rust contract | PASS: exact word deletion/source mapping, 2 fillers removed, 2 pauses tightened; retained ranges checked at start/midpoint/end. Explicit synthetic word times, not recognized speech; no interaction or preview playback claimed. |
| Broader speech/DSP XCTest selection | PASS: 15 run, 2 native checks skipped, zero failures. Includes independent FFmpeg loudness comparison. Separate editor caption-document test fails with Metal preview unavailable (environment limitation). |
| Rust core suite | PASS: 104 passed, 1 ignored, zero failures; 12.77 s. |
| Signed debug measurement app | Prepared outside repo; strict signature verification PASS using Yapcam Dev Signing / mov.yapcam.Yapcam. Never launched. |
| Full capture suite / main app rebuild | BLOCKED: native writer test run stalls and holds SwiftPM lock; sandbox denies signal to its exact PID. No full-suite green claim. |
| DE/EN real-file WER, timing median/max, noisy SNR/LUFS, listening, network-disconnected recognition | UNMEASURED: zero-duration `say` output and denied Speech permission. Missing-model/unsupported-locale tests use injected policy conditions, not real installed-pack removal. No mic/camera/USB hardware capture claimed. |

Artifacts/scripts: `Tests/YapcamCaptureTests/Tools/generate_speech.py` writes 162
English / 163 German reference words, 0.3–2 s pauses, seeded 10 dB SNR stems and
sentence activity bounds into an external folder; it enforces 60–90 s actual audio.
`run_speech.zsh` builds the linked debug tool; `launch_speech.zsh` atomically claims
QA/.app-lock, refuses running apps/unreadable process lists, and launches only via
LaunchServices. Explicit `--request-speech` is a host authorization action; library
and normal tests never prompt. Interrupted launch retains the lock for host review.

The tool runs actual capture transcription for clean/noisy tracks, actual editor/core
edits, render DSP, optional Apple AUSoundIsolation and core PCM silence detection.
Per-stage failures are retained in outcomes. Measurements: WER S/D/I + filler recall,
matched first/last-word sentence timing residuals with coverage (10 ms sentence
bounds; no invented interior-word ground truth), input SNR from retained stems,
SI-SDR before/after (includes speech distortion), independent FFmpeg LUFS, peaks,
clipping and exact duration. Pumping/voice quality require Lead's listening check.
See the capture test README for commands and all measurement limitations.

Logs outside Git: `/tmp/yapcam-capture-round3-{generate,harness,focused-tests,contract-direct,rust,signed-harness,tests,capture-tests}.log`.
Completed tool/contract temp directories are removed by traps/defers; earlier signed
harness artifact is listed/checked unused before replacement. The single prepared
app is intentionally retained for Lead under `~/Movies/Yapcam/QA/speech/capture-round3-tool/Yapcam.app`.

### Requests (Round 3)

1. RESOLVED: Lead stopped the stale capture test/build processes. No additional
   signals are requested. SwiftPM is free; full capture tests and canonical app
   build pass, F13 is integrated and capture is rebased onto main a7d1526.
2. RESOLVED: host fixtures exist, Speech permission is granted, and Lead verified
   F13 natively. Preserve the native reports; no repeat run requested.
3. Accuracy/filler/timing limits are measured above. Render owns F14 and listening
   acceptance; a network-disconnected recognition run remains separate. No network
   or TCC settings were changed here.
4. Lead review the shared request-policy refactor before merging. Optionally exclude
   `Tools` from SwiftPM's test target to silence unhandled-script resource warnings
   (Package.swift is outside capture ownership). No production dependency was added.

## Reference gap work (2026-10-15)
- Latest continuation check: 2026-10-15 22:57 UTC; main 66d4166, local HEAD c86f263
  (based on 01f05df). Capture source/tests match main; Lead's next rebase is pending.
  Local Next is empty; no new capture defect or implementation assignment appeared.
- NEW FULL-SUITE HOST EVIDENCE: QA reran main 97b9d82 outside the sandbox at 21:05:
  Rust 100 passed / 1 ignored; XCTest 207 run / 10 skipped / zero failures; Swift
  Testing 501 tests / 99 suites passed. This supersedes the earlier baseline's
  full-suite sandbox limitations. Optional speech/native-media/hardware acceptance
  is still separate. These are QA results, not reruns by capture.
- Main's new controller changes are self-test auto-confirm hooks (F11 support),
  not capture option/marker forwarding. F13 is an editor autosave-hook wait mismatch
  and UI-owned. F12 remains UI's intermittent post-recording save finding. Capture
  sources/contracts/defaults are unchanged; no app launch or tests repeated here.
- NEW QA HOST EVIDENCE on 97b9d82: start/stop, marker shortcut delivery and pause /
  resume PASS; 15 shortcuts register with zero refusals. Completed hotkey recording
  4.72 s, editor front. Marker observation is UI count 0 -> 1, not event persistence.
  After-recording create/widget/copy/save pass; save export has video+AAC. F11
  (restart confirmation / overlay script interaction) and F12 (one unreproduced
  save hang in five runs) are UI-owned. Capture's API contract remains unchanged.
- Read-only artifact check: no retained recording/markers.json found under the QA
  recording root, so no package-level marker-persistence result can be claimed.
  No media changed/deleted, no app launched. Static UI forwarding gap below still
  exists; successful hotkey delivery does not show a durable capture marker.
- CAP-3 editor consumer is now DELIVERED (c143346, reflected in main FEATURES):
  timeline marker flags, snapping/edit points consume Core's mapped marker query.
  UI's exact live recording path is still missing: RecordingController.addMarker
  appends elapsed*1e9 and LiveEngine/EngineSession expose no marker method. Existing
  Project.markers() reads events.jsonl, not the clean-stop UI markers.json. Thus
  newly recorded hotkey marks still need UI forwarding before end-to-end acceptance;
  the integrated CAP-3 row should retain that caveat. Capture's API/wire format is
  ready and unchanged; editor presentation is no longer a missing implementation.
- UI's hotkey/after-recording hooks are now exercised by QA as above; marker
  persistence and capture-option isolation remain distinct checks. No unchanged
  tests rerun here; existing module validation remains current.
- NEW HOST EVIDENCE from QA's TEST_REPORT (main c1bf553, 19:45): display overlay /
  Start / Stop yields a complete 12.19 s package; scripted input 47/47, timing
  0.27–8.67 ms (mean 1.95), position <=0.98 point, 5 paired clicks. Area 800x500,
  window 1626x1014 with matching manifest, pause 2.17 + 1.85 s all PASS. QA also
  reports real auto-zoom and export/clipboard/model checks passing. These are QA
  host runs, not new capture runs here; no new capture failure was reported.
- F10 is VERIFIED FIXED by QA on 3dd0d3b. Later QA hook results on 97b9d82
  supersede the old hotkey/after-recording hook blockers; F11/F12 remain UI owned.
  Selected-app audio isolation, durable
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
R5b incoming requests supersede the old Next list:8 delivered/resolvable provider
contracts and3 explicitly blocked rows (global positive cursor identity, real sync
oracle fixture, native Apple isolation). Main capture gate is green;
Lead checkpoint/rebase all8 owned paths. Subsequent capture work is a concrete
consumer defect or new evidence resolving those blockers; no new feature scope.
Earlier R5 audit/RC Next entries are historical.

## External handoffs / Lead requests
1. Lead: checkpoint ALL8 R5b owned paths (including NEW CapturedCursorShape.swift,
   CursorMetadataTests.swift, IncomingRequestTests.swift), then rebase9acadbe onto
   maina96173e. Canonical validation uses a fresh main snapshot + owned overlay;
   metadata writes remain denied. See R5 incoming requests/validation above.
   Suggested commit: capture: publish cursor provenance and camera/speech queries.
   Prior F14/RC handoffs are checkpointed. Historical consumer requests follow.
   UI reports isolation fixed; consume the capture
   audio/camera/preflight APIs and forward marker actions to RecordingSession.addMarker. Core's exact
   event marker query/TimelineMarker and editor presentation/snapping are complete;
   UI marker forwarding is the remaining implementation step. Lead: document public capture additions/optional derived UI sidecar in
   SWIFT_API/FORMATS. QA's GAP-CAP module statuses are now reconciled; consumer and
   native acceptance remain open. CAP-4 is a documented extra; CAP-7 belongs to UI.
2. Host: YAPCAM_CAPTURE_MEDIA_TESTS=1 swift test -j 4 --filter NativeFragmentTests.
   Record CAPTURE_NATIVE_HOUR output (actual bytes/moofs/duration) here. Also run
   the signed-app variants above plus static-tail/sync. Library kill/recover now
   passes in QA; app-level recovery prompt still needs acceptance.
   QA's full host suite is green (evidence above); the opt-in native-media and
   C1 speech acceptance checks remain pending.
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
