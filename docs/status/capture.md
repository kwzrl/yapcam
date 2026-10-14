READY b75ea0a capture review fixes integrated in main 4a1cee5; capture suite green; host acceptance / follow-up review pending

# capture status

## Current handoff
- Lead checkpointed the review fixes as b75ea0a and integrated them into main
  4a1cee5. Only this status file has local changes. Capture source/tests match main
  exactly; the validated review fixes are preserved in the checkpoint.
- Local HEAD remains b75ea0a. Requested `git rebase main` from the clean tree failed
  creating .git/worktrees/capture/rebase-merge (Operation not permitted). Lead owns
  Git rebase/push under the agreed sandbox workflow; no workaround attempted.
- Backlog audit 2026-10-15 00:56 CEST: brief, main capture feature rows and latest
  UI/QA status checked. No new capture review or host result. No independent capture
  implementation item is open. Existing validation is unchanged; no tests repeated
  for this documentation-only update. Main remains 4a1cee5, the review directory
  still has round 1 only, and QA/UI still report the current-signing-identity TCC gate.
- Capture has no runnable work package at this point. Resume implementation when
  follow-up review, host capture/media findings or a changed integration contract
  arrives; the external gates in Next cannot be closed from this sandbox.
- Main now wires LiveEngine.openEditor to EditorWindows.open; that integration
  request is closed. Icon/notification forwarding, format documentation, follow-up
  independent review and real capture/media gates remain open below.

## Review fixes / regression evidence (2026-10-15)
- H2: pass the captured segment stop time to track finalization and call
  AVAssetWriter.endSession(atSourceTime:) before finishing. Static screen/camera
  tails extend to stop, while lost optional devices keep their natural truncated
  tails. Unit regression verifies both screen and camera receive the full stop time.
  The opt-in HEVC test now writes only three frames, ends at 2 s and reads at 1.8 s.
- H3: start SCStream before optional devices; wait (cancellable, maximum 10 s) for
  the first written screen frame. Its PTS becomes host_start_ns, screen offset is 0,
  duration is stop minus that origin, and retained audio/device offsets use that
  origin. Pre-screen samples are discarded. Input monitoring starts with the same
  origin. A backpressured first frame cannot anchor an unwritten prefix.
  Regression tests exercise a 40 ms startup delay at both start and resume,
  persisted host/track/source timing and event timestamps, preroll, backpressure,
  timeout/cancellation, and recovery before the manifest catches up.
- M1: cadence deadlines tolerate half-frame timing jitter instead of comparing
  strictly with the last PTS. Tests retain all 600 jittered slightly-fast 60 Hz and
  30 Hz frames while still rejecting double-rate input and enforcing the stop cutoff.
- M2: renumber recovered survivors to indices 0..N-1 and rebuild contiguous source
  starts while preserving directory/file paths. Tests skip the first, middle and
  last screen segment independently, then check continuity and idempotent recovery.
- Input risk: CGEvent.timestamp is no longer used. Stamp input delivery from the
  same CoreMedia host clock as media. Conversion regression uses a non-nanosecond
  24 MHz representation (including integer rounding), checks a stationary-pointer
  click advances time, and checks the live clock against CaptureClock.now.

## Review-fix validation
- Signed integrated app build passed against a temporary b93ce7d export with current
  capture source/tests overlaid: `/tmp/yapcam-capture-review-main.JPDnEz`.
  `scripts/build-app.sh` uses an external Swift shim for --disable-sandbox and -j 4;
  Rust uses CARGO_BUILD_JOBS=4. Tracked build scripts/manifest remain untouched.
  Verified signature: Yapcam Dev Signing / mov.yapcam.Yapcam.
- Capture-only suite in that integration: 59 discovered, 1 explicit HEVC skip,
  zero failures (30/60 Hz and missing-segment tests include parameterized cases).
- Rust: 23 passed, zero failures.
- Full integrated Swift suite was attempted: 124 Swift Testing tests, 12 issues,
  all editor RealStackTests reporting .metal("Metal preview unavailable"). Capture
  tests had no failures. XCTest: 28 discovered, 14 explicit media/GPU skips, no
  failures. Do not treat the full suite as green; Lead must run it on the host.
- The real HEVC static-tail/seek test is compiled but remains opt-in and unverified
  here because the command sandbox lacks the required media services. Lead should
  run it before accepting H2. No real recordings or permission changes made here.
- git diff --check and gitleaks scans passed. These fixes are now represented by
  b75ea0a (Lead checkpoint). No successful local Git writes or push here.

## Verified checkpoint in place (2026-10-15 00:06 CEST)
- Worktree `scripts/build-app.sh` passed: Rust + full integrated Swift app, signed and
  verified using `Yapcam Dev Signing` / `mov.yapcam.Yapcam`, without keychain dialogs.
  Temporary Swift shim adds --disable-sandbox; tracked scripts were unchanged.
- Worktree `swift test --disable-sandbox -j 4`: 82 passed, 8 hardware/media skips,
  zero failures (Swift Testing: 74 pass + 1 skip; XCTest: 8 pass + 7 skips).
  Capture subset: 48 pass + 1 explicit HEVC integration skip.
- Worktree `CARGO_BUILD_JOBS=4 cargo test --manifest-path core/Cargo.toml`: 20 pass.
- `git diff --check` and gitleaks scans of capture source/tests passed.
- New tests simulate device loss, optional/essential writer failures, stop cutoffs,
  VFR caps, cancelled cleanup waiting, stationary-pointer/window reprojection, exact
  audio durations, thumbnail sizing, preference migration, stream exclusion policy,
  recovery timing/sidecar fallback, oversized event lines, write rollback and locks.
  Test media sinks exercise routing; they do not count as real encoder verification.
- Ten additional tests now exercise the real RecordingSession coordinator and disk
  manifests: low disk during capture, revoked screen permission, source loss,
  pause/resume, stale callbacks, cancelled cleanup during startup, failed writer
  finalization, window resize/scale across pause, display resize refusal and missing
  source at startup. They verify interrupted status, cleanup counts and lock release.
- Five input translation tests verify area-relative/outside coordinates, drag/click
  buttons, signed scroll deltas, opt-in Unicode/modifier keys, monotonic timestamps
  and invalid-coordinate rejection without posting events or touching permissions.

## M2 changes since 1f61d47
- Window picker thumbnails from SCScreenshotManager, limited to four concurrent
  requests. A closing window may have a nil image while source discovery still succeeds.
- Backward-compatible recording options for desktop icon / notification capture.
  Icon exclusion is stream-only: Finder preferences stay unchanged and folder windows
  are retained. Filters refresh to retain newly opened Finder folders. Notification
  exclusion targets NotificationCenter and remains subject to macOS limitations.
- Device loss truncates future optional-track samples, warns once and resets mic
  metering while screen capture continues. AVCapture configuration is balanced on error.
- Fixed an AV sync bug: output PTS/DTS are converted from the session's
  synchronizationClock, not the input port's native clock. Exact PCM durations such
  as 1/48000 are retained, avoiding nanosecond rounding of every audio sample.
- Stop/pause rejects later sample timestamps. Delayed callbacks belong to their
  segment, so they cannot fail or change a resumed session. Cancel cleanup still
  waits for in-flight work if its calling Task has already been cancelled.
- Cursor positions update when a window moves beneath a stationary pointer.
  Window resume accepts resize/display changes using the original fixed output
  surface; display/area resume still refuses changed dimensions/scale.
- Recovery keeps finalized segment durations authoritative (audio packets can extend
  past stop), falls back to the previous sidecar, streams bounded event-tail repair,
  retains previous logs, and rejects segment symlinks leaving the package.
- An advisory recording/.capture.lock prevents recovery of live/paused sessions.
  OS process death releases it automatically; an empty stale file is harmless.
- Internal live-service injection makes session failure acceptance tests deterministic;
  the public initializer still selects the real Apple framework implementations.

## Capture feature handoff / assumptions
- REC-01/02/03/08/10/11, AUD-01 and CUR-01/02: implementation present; host media
  checks pending. REC-19: full session fault simulation passes, including finalized
  segment metadata and preserved interrupted package below 1,000,000,000 free bytes.
- REC-12: scale/multi-display unit math passes; hardware gate remains limited.
- REC-13/15: additive stream-filter options implemented and policy-tested; UI wiring
  and actual Finder/banner behavior remain open. Assumption: hiding icons means
  excluding them from the recording; desktop preferences never need restoration.
- REC-18: recovery implementation/fixtures pass; UI relaunch prompt and real process
  kill/reopen are external acceptance gates. CUR-10: opt-in key capture tested;
  rendering the overlay belongs to render.
- AUD-02/03, CAM-01/06: capture/device-loss code and simulated routing pass; actual
  hardware timing/disconnects remain limited. REC-17 stays limited without a device;
  an available iPhone Mirroring window uses ordinary window capture.
- Window recordings keep the initial encoded dimensions across a resize or resume;
  content and cursor coordinates fit that surface. Display/area geometry changes
  across a pause require a new recording. These are reversible policy decisions.
- FEATURES.md capture rows were rechecked after the checkpoint. QA owns the file;
  please reconcile statuses from the evidence above.

## Additive APIs for UI / QA
- `CaptureSources.load()` now supplies thumbnails.
  `load(includeWindowThumbnails: false)` avoids screenshots for device polling.
  `thumbnail(for: windowID, maxSize: CGSize(width: 320, height: 200))` refreshes one.
- `RecordingOptions.hideDesktopIcons` defaults false; `captureNotifications` defaults
  true. Old serialized options decode with those defaults. UI needs to forward both.
- `CaptureSelfTest.run` retains existing calls and additionally accepts
  hideDesktopIcons, captureNotifications and recordKeystrokes. Existing parameters
  cover window/area target, camera/mic, 30/60 fps, and pauseAfter.

## Private recording files — Request for Lead / FORMATS.md
- Keep optional `recording/seg-XXX/track-starts.json`, for example:
  `{"screen":0,"system_audio":10000000,"mic":20000000,"camera":30000000}`.
- Keys are the session track keys; values are nonnegative signed Int64 nanoseconds
  relative to that segment's host_start_ns. They use the same meaning as track_start_ns.
- Written synchronously on the sample queue when each track's first sample is accepted,
  using temporary file -> fsync -> atomic rename; prior version is .prev.
  This makes offsets durable before the main-actor session.json update can run.
- Recovery prefers valid session offsets, fills gaps from the sidecar, then its .prev.
  Readers can ignore these optional files; session.json has no new required keys.
- With H3, new segments always use screen offset 0; legacy segments can retain
  nonzero screen offsets. Recovery still supports those older packages.
- Also document optional `recording/.capture.lock`: an empty advisory lock file only,
  never recording metadata. Its presence alone does not mean a recording is active.
- H3 additionally needs optional `recording/seg-XXX/host-start.json`: a JSON Int64
  containing the first written screen PTS in absolute host nanoseconds. Written
  once atomically on the sample queue before track-starts.json. Recovery reads it
  to correct a stale session host_start_ns and recover screen offset 0 even if the
  offset sidecar has not been written yet. Existing packages without it still work.

## Real verification / hardware limits
- Lead runs signed --capture-selftest and YAPCAM_CAPTURE_MEDIA_TESTS=1 outside the
  command sandbox, and appends results here. Main b93ce7d now wires the self-test flag.
- UI/QA's host result is still a failure before capture: SCStream -3801, screen access
  false for the new signing identity (QA F2 / UI Blockers). This is reported evidence,
  not a new local test. Lead must resolve the grant externally; no TCC reset or
  permission request was attempted here. No successful package verification yet.
- Still verify display/window/area outputs, pause/resume, own-window exclusion,
  desktop icons + visible Finder folders, notifications, first-track offsets/events,
  kill/recover, and a resized/moved window across a pause with ffprobe/playback.
- No camera/mic, one non-Retina display: device-loss routing and geometry are simulated;
  actual device sync/loss, Retina and multiple-display hardware remain unverified.
- No permission resets, sudo, recordings, credentials, new dependencies or other
  teams' source changes. Independent Claude round 1 received; fixes need re-review.

## Integration requests found on b93ce7d
- UI: LiveEngine.Session does not forward hideDesktopIcons/captureNotifications to
  RecordingOptions. Instead RecordingController calls DesktopIcons.hide(), which
  writes Finder CreateDesktop and restarts Finder. Please use capture's stream-only
  icon option and remove those global side effects; restarting Finder can terminate
  a selected Finder source window. Keep any restoration of existing legacy markers
  as a migration concern. Actual filter behavior still needs host acceptance.
- Closed on main 4a1cee5: self-test wiring, recovery prompt and editor handoff
  (LiveEngine.openEditor now calls EditorWindows.open).
- Lead: sidecar / advisory-lock additions are still absent from FORMATS.md.

## Next
1. Lead: finish this worktree's rebase onto main 4a1cee5, arrange follow-up independent
   review and push team/capture. Review fixes are already checkpointed/integrated as
   b75ea0a; no new source checkpoint needed. Shared Git metadata is read-only here.
   Full Swift suite needs the host Metal gate before marking this new commit ready.
2. Lead: resolve the reported current-identity screen-recording grant externally,
   then run the host checks above and opt-in HEVC static-tail/recovery test. Confirm
   duration/seek through a static tail and no startup/resume flash. Append results here;
   capture will fix findings. Self-test entry point is now wired on main.
3. UI: forward icon/notification options using the capture API; align desktop-icon
   behavior. Editor handoff is closed. Lead: document optional track/host sidecars and lock.
   QA: reconcile feature rows from the recorded evidence.
4. Hardware follow-up: camera/mic, Retina and a second display. No independent
   capture implementation item remains before host results or integration feedback.
