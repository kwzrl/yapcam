# Known limitations (release candidate 0.9.0, 2026-10-16)

Honest list of what was **not** verified or is **not** built. Details per row: `docs/FEATURES.md`;
test evidence: `docs/TEST_REPORT.md` (section "Round 3"). Earlier states are under "History" below.

## Not tested by real use
- **No real mouse/keyboard acceptance.** Round 3 ended without real-input tests (user decision): the
  QA input driver never received Accessibility / Screen Recording permission. Every "verified live"
  row was checked with the signed app's own self-test flags or events posted from inside the app, and
  the exported files were checked outside the app. Not exercised by a person: dragging an area, zoom
  bars and trim handles with the mouse, inspector sliders, recent-projects list, Cmd-Q + relaunch.
- **Permission loss during recording**, **VoiceOver** and an accessibility audit: not done (same reason).
- **Side-by-side comparison with Screen Studio 4.0.4** (zoom timing, cursor feel, sharpness): not done.

## Hardware not available
Mac mini M4, one non-Retina 1680×1050 display, no camera, no microphone, no second Mac.
- **Camera and microphone:** code exists and is tested with injected/simulated devices only (device
  choice, max camera resolution, overlay/cutout/split, matting, face framing, mic levels, device
  unplugged mid-recording, pre-flight prompts). Speech processing was tested with generated German and
  English speech *files*, not a microphone.
- **Retina and multiple displays:** coordinate math is unit-tested (non-zero origins, mixed scales);
  never run on such hardware.
- **iPhone/iPad over USB:** capture API exists; the toolbar entry stays hidden until a real device has
  been tested (user decision). Device frames for such recordings (reference: ~148 mockups) are not built.
- **First install on a clean Mac:** not done; the release package was only launched on the build Mac,
  which already holds Yapcam's permissions.

## Distribution
- The 0.9.0 package is signed with the local self-signed identity "Yapcam Dev Signing" and is **not
  notarized** (notarization prepared only, by user decision). Other Macs will show a Gatekeeper
  warning; see docs/RELEASE.md for the Developer ID + notarization steps.

## Quality limits measured in round 3
- **Captions:** Apple on-device speech, measured on generated speech files: German WER 8.6 %, English
  9.3–9.9 %. Apple's recogniser drops most filler words ("äh", "um"), so "Remove filler words" finds few.
- **Speech clean-up** is classic DSP (no ML model): on 10 dB-SNR speech it raises SI-SDR to ~15.5 dB and
  lowers noise in pauses by 30–34 dB. Not judged by ear on real microphone speech.
- **4K:** no 4K capture possible here; 4K numbers use a synthetic 3840×2160 60 fps HEVC source.
  Random seeking in that source and 4K60 export speed are tracked as F17/F18 (TEST_REPORT).

## Not implemented / partial (see FEATURES.md "partial")
- Device frames (GAP-RND-10, see above); recording-engine choice is shown read-only (GAP-UI-9).
- Cloud features (links, comments, accounts, payments, telemetry, auto-update) are out of scope by the
  user's decision; Loom-style sharing is prepared architecturally only.
- GIF has no audio (format limit).

## Process notes
- Codex-team worktrees cannot write `.git`; Lead commits their work, so history contains
  "checkpoint (committed by Lead …)" commits. Public history is not rewritten.
- Metal/ffprobe test suites only run outside sandboxes (`YAPCAM_REQUIRE_RENDER_HARDWARE=1` for strict).

## History
- 2026-10-15: live capture was blocked until Screen Recording was re-granted for the
  `Yapcam Dev Signing` build (resolved 10:25). F9 (window recordings could not be opened) was fixed
  on badc4e4. REA analysis of the reference was limited until the user extracted the bundle locally.
