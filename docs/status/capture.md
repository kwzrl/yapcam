READY 1f61d47 + uncommitted M2 follow-up: integrated build/tests green; Lead checkpoint required (.git read-only)

# capture status

## Current handoff
- Further M2 work is complete in capture-owned files and ready for Lead's next commit.
  Lead owns commits/push and real media verification under the agreed sandbox workflow.
- Capture's independent implementation backlog is empty. Host acceptance gates and
  cross-team handoffs remain open in Next below; implementation is not hardware verification.
- `git rebase main` was attempted with a clean tree and failed creating rebase-merge
  (Operation not permitted). Please rebase this worktree externally before the next
  checkpoint. Local manifest still predates test registration; no shared files edited.
- Compatibility was verified against a temporary export of main 35ba7c5 with only
  capture source/tests overlaid. Snapshot: `/tmp/yapcam-capture-main-xxcz46te`.

## Verified for this follow-up (2026-10-15 00:04 CEST)
- Snapshot `scripts/build-app.sh` passed: Rust + full integrated Swift app, signed and
  verified using `Yapcam Dev Signing` / `mov.yapcam.Yapcam`, without keychain dialogs.
  Temporary Swift shim adds --disable-sandbox; tracked scripts were unchanged.
- Snapshot `swift test --disable-sandbox -j 4`: 82 passed, 8 hardware/media skips,
  zero failures (Swift Testing: 74 pass + 1 skip; XCTest: 8 pass + 7 skips).
  Capture subset: 48 pass + 1 explicit HEVC integration skip.
- Snapshot `CARGO_BUILD_JOBS=4 cargo test --manifest-path core/Cargo.toml`: 20 pass.
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
- FEATURES.md exists on main but not this stale worktree; read via `git show main`.
  QA owns its rows; please reconcile statuses from the evidence above.

## Additive APIs for UI / QA
- `CaptureSources.load()` now supplies thumbnails.
  `load(includeWindowThumbnails: false)` avoids screenshots for device polling.
  `thumbnail(for: windowID, maxSize: CGSize(width: 320, height: 200))` refreshes one.
- `RecordingOptions.hideDesktopIcons` defaults false; `captureNotifications` defaults
  true. Old serialized options decode with those defaults. UI needs to wire both.
- `CaptureSelfTest.run` retains existing calls and additionally accepts
  hideDesktopIcons, captureNotifications and recordKeystrokes. Existing parameters
  cover window/area target, camera/mic, 30/60 fps, and pauseAfter.

## Private recording files — Request for Lead / FORMATS.md
- Keep optional `recording/seg-XXX/track-starts.json`, for example:
  `{"screen":12000000,"system_audio":10000000,"mic":20000000,"camera":30000000}`.
- Keys are the session track keys; values are nonnegative signed Int64 nanoseconds
  relative to that segment's host_start_ns. They use the same meaning as track_start_ns.
- Written synchronously on the sample queue when each track writer is first created,
  using temporary file -> fsync -> atomic rename; prior version is .prev.
  This makes offsets durable before the main-actor session.json update can run.
- Recovery prefers valid session offsets, fills gaps from the sidecar, then its .prev.
  Readers can ignore these optional files; session.json has no new required keys.
- Also document optional `recording/.capture.lock`: an empty advisory lock file only,
  never recording metadata. Its presence alone does not mean a recording is active.

## Real verification / hardware limits
- Lead runs signed --capture-selftest and YAPCAM_CAPTURE_MEDIA_TESTS=1 outside the
  command sandbox, and appends results here. UI is wiring the flag per latest sync.
- Still verify display/window/area outputs, pause/resume, own-window exclusion,
  desktop icons + visible Finder folders, notifications, first-track offsets/events,
  kill/recover, and a resized/moved window across a pause with ffprobe/playback.
- No camera/mic, one non-Retina display: device-loss routing and geometry are simulated;
  actual device sync/loss, Retina and multiple-display hardware remain unverified.
- No permission resets, sudo, recordings, credentials, new dependencies or other
  teams' source changes. Other-model-family review remains required before merge.

## Next
1. Lead: checkpoint all capture-owned working-tree changes, rebase onto main, run
   required cross-family review and push team/capture. Shared Git metadata remains
   read-only here; no new local main integration beyond 35ba7c5 was visible.
2. Lead/UI: finish --capture-selftest wiring, then run the host checks listed above
   and the opt-in HEVC recovery test. Append results here; capture will fix findings.
3. UI: wire icon/notification options and recovery prompt. Lead: add the optional
   sidecar and advisory lock descriptions to FORMATS.md. QA: reconcile feature rows.
4. Hardware follow-up: camera/mic, Retina and a second display. No independent
   capture implementation item remains before host results or integration feedback.
