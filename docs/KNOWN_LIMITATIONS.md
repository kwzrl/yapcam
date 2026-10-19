# Known limitations (release 0.11.0, 2026-10-20)

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
- 0.11.0 is signed with a Developer ID and notarized by Apple (the GitHub release lists the DMG checksum).
- Apple Silicon (arm64) and macOS 15+ only. Intel and macOS 13/14 are not supported.
- Updates come through Sparkle from https://yapcam.app/appcast.xml (EdDSA-signed, no system profile);
  the check runs at launch and can be turned off in Settings.
- Hidden in 0.11.0 (code kept, existing projects still render): the agent chat and its local MCP server,
  the building-blocks bar, and the "Text, regions & intro/outro" panel (no new text items or masks).
- Earlier 0.9.0/0.10.0 packages were signed with the local self-signed identity and were not notarized.

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
- Round 5 parity gaps left (FEATURES.md section R): Settings > Shortcuts cannot yet rebind the editing keys (editor API exists), and the "Disable hardware-accelerated encoding" setting does not reach the editor's export dialog until ui assigns EditorWindows.hardwareEncodingEnabled (quick export honours it). Hide Desktop Icons, Esc two-step and other wave-3 items are code/test verified only, not live.
- Not in 0.11.0 (Lead decision, Round 7b): update check (REC B-18), macOS 13/14 and Intel support (B-19), and a
  Quick Look preview for project files (needs a separate app-extension target that SwiftPM cannot build).
- 4K60 export speed and random seeking in long sources (F17/F18) are unmeasured for 0.11.0 (the user's Yapcam was running, so the benchmark could not run).
- "Camera disconnected" placeholder in the recording preview: needs a capture disconnect signal plus a UI placeholder; in progress.
- Hardware-decoding switch (B-14) and export memory limit (B-15): hooks come from render, the Settings switch from ui; check the
  Settings page of the released build before relying on them.

## Process notes
- Codex-team worktrees cannot write `.git`; Lead commits their work, so history contains
  "checkpoint (committed by Lead …)" commits. Public history is not rewritten.
- Metal/ffprobe test suites only run outside sandboxes (`YAPCAM_REQUIRE_RENDER_HARDWARE=1` for strict).

## History
- 2026-10-15: live capture was blocked until Screen Recording was re-granted for the
  `Yapcam Dev Signing` build (resolved 10:25). F9 (window recordings could not be opened) was fixed
  on badc4e4. REA analysis of the reference was limited until the user extracted the bundle locally.
