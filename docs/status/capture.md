# capture status — M1 + M2 implemented; verification/integration gates below

No READY commit yet: local Git index writes and GitHub write-tool approval are
blocked. All work is in capture-owned files on team/capture. Lead can commit/review
from an unrestricted context; do not interpret compilation as a verified real capture.

## Latest Lead sync
- Main is at 129c5f6 (signing-keychain unlock fix). Retried the requested commit:
  git add still fails creating the shared worktree index.lock (Operation not permitted).
  `git rebase main` refuses the remaining unstaged changes. No commit/rebase occurred.
- Validated main's 129c5f6 build script against this worktree through a temporary
  script copy (build-root override only; ad-hoc fallback disabled). Build, signing
  with `Yapcam Dev Signing`, and signature verification all passed without dialogs.
- Re-ran repository Swift/Rust suites and capture harness: all enabled tests pass
  (15 capture passes, 1 hardware integration skip). Patch snapshot for Lead:
  `/tmp/yapcam-capture-handoff.patch` (all capture-owned source/tests/status changes).

## Done (verified)
- Public discovery, source/options/error types, permissions, exclusions and complete
  RecordingSession API compile under Swift 6/macOS 15.
- Main's `scripts/build-app.sh` compiles the Rust library and Swift app and signs/
  verifies with `Yapcam Dev Signing` / `mov.yapcam.Yapcam` (see latest sync above).
  SwiftPM's nested sandbox is unavailable, so an external temporary `swift` shim
  adds `--disable-sandbox`; tracked build scripts were not edited by capture.
- Existing repository `swift test --disable-sandbox -j 4` and
  `CARGO_BUILD_JOBS=4 cargo test --manifest-path core/Cargo.toml` passed.
- Capture tests run in a temporary standalone SwiftPM harness until Lead registers
  the target: integer host-time conversion, exact JSON keys/round trips, atomic
  previous-version writes, event serialization/tail repair, low-disk threshold,
  invalid lifecycle transitions/cancel, unavailable devices, recovery traversal
  rejection, target/options persistence, 10,000 pause-removed segments without drift,
  and Retina/multi-display/window projection math, normalized microphone RMS,
  and ScreenCaptureKit error mapping. Final harness run: 15 passed, 1 hardware HEVC
  integration test explicitly skipped (16 discovered). No tests requested permissions.
- `gitleaks dir` on capture source, tests and status: no leaks. No media assets or
  dependencies were added.

## Implemented (real capture verification still open)
- M1: display ScreenCaptureKit stream → native-size cursor-free HEVC `screen.mov`
  (2 s movie fragments), separate AAC `system.m4a`, timestamp offsets, start/finish
  manifests, listen-only CGEventTap + NSEvent fallback, mouse/click/scroll and opt-in
  keys, deduplicated system cursor PNGs/metadata, app exclusions, pause/resume to
  new segments, stop, cancel/delete and signed-app self-test helper.
- M2: window/area targets, ScreenCaptureKit-native scale, global point coordinates,
  frame-metadata mapping for moving/resizing windows, AVCapture camera/mic with
  host-clock conversion and separate files, mic RMS meter, unavailable-device and
  runtime/disconnect warnings while screen continues, 30/60 fps, source/permission
  monitoring, low-disk clean finalization, interrupted-package discovery/recovery.
- Recovery preserves original media, salvages readable tracks, repairs event tails,
  rebuilds pause-removed offsets, and refuses recovery if no screen track is readable.
  `track-starts.json` is an additive per-segment crash sidecar so first-sample offsets
  survive even if the app dies before a main-actor manifest update.

## Assumptions
- Screen/Input Monitoring preflight APIs cannot distinguish never requested from
  denied; report denied until granted, with explicit request APIs.
- Missing/denied optional mic/camera warn and continue. Writer failures in optional
  device tracks are isolated from screen recording; screen/system-audio failures
  finalize what is possible and preserve an interrupted package.
- Media files start at each track's first host PTS; `track_start_ns` retains the
  offset relative to segment host start. Events use segment-relative nanoseconds.
- Capture dimensions are fixed during a segment; moved/resized window events map
  into its fixed output surface using SC frame metadata. Resume rejects changed
  source dimensions/scale because the v1 contract has one global screen geometry.
- Window thumbnails are optional and currently nil; discovery provides real titles,
  app identity and frames without synchronously screenshotting every window.

## Blockers / verification limits
- `git add` failed: `Unable to create .../.git/worktrees/capture/index.lock:
  Operation not permitted`. Cannot commit locally or produce truthful READY <commit>
  lines here. No main changes, permission resets, or sudo attempted.
- An authorized GitHub alternative was checked: repository push access is available,
  but `github_create_tree` was rejected with `MCP tool call requires approval, but
  approval policy is never`. No remote tree/commit/branch was created. origin has no
  team/capture branch yet. Lead must commit/push from an allowed context.
- Hardware HEVC test was attempted and fails in the command sandbox with IOSurface/
  VideoToolbox service errors (`kIOSurfaceMethodSetCoreVideoBridgedKeys`, AV -11800).
  It remains an explicit opt-in integration test, not counted as passing.
- Signed temporary self-test app verifies its signature but aborts when run from
  this command sandbox; LaunchServices also rejects launch (-10827). No permission
  requests/reset were made. Real ffprobe/event-sync checks must run from the regular
  signed app outside this sandbox.
- No camera/microphone, one non-Retina display: real device loss, Retina and
  multi-display hardware verification remain open. No recordings committed.
- docs/FEATURES.md does not exist yet on this branch; capture M2 follows the brief.

## Requests (to Lead)
- Register `.testTarget(name: "YapcamCaptureTests", dependencies: ["YapcamCapture"])`
  in Package.swift. Capture cannot edit the manifest.
- UI: wire `--capture-selftest <seconds>` to
  `try await CaptureSelfTest.run(seconds:)`, log returned package/error and terminate.
  Helper writes only under Movies/Yapcam/QA/capture by default. Optional arguments
  support window/area, 30/60 fps, camera/mic and pauseAfter for lifecycle QA.
- Run `YAPCAM_CAPTURE_MEDIA_TESTS=1 swift test --filter actualHEVCWriterAndInterruptedRecovery`
  outside the command sandbox after registering the target. Then run signed app
  `--capture-selftest 5`, ffprobe both tracks, compare track_start_ns and event t.
- Document the optional `track-starts.json` crash sidecar in FORMATS.md if retained;
  it adds no required session JSON keys and readers can ignore it.
- Arrange other-model-family critical-code review before merging (TEAMS rule 10).
- Commit capture-owned work and push team/capture from an unrestricted context if
  this environment cannot be granted access to its declared shared Git writable root.
