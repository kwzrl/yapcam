# Known limitations (draft, 2026-10-15, main a02a89e)

Honest list of what was **not** verified or **not** built. Details per row: `docs/FEATURES.md`.

## Hardware and environment
- **No camera, no microphone.** Camera/mic recording code exists; only the "no device" and
  simulated "device lost" paths are tested. Camera matting/face framing run on synthetic input.
  Real devices: open.
- **One non-Retina 1680x1050 display.** Retina scale and multi-display behaviour verified by
  math/unit tests only.
- **iPhone/iPad recording**: not tested (no device); only window capture of an iPhone Mirroring
  window could work.
- Performance numbers are from synthetic, low-resolution sources: export 1080p 4.7x, 4K 1.9x
  realtime; 10-min export with audio 4.4x (A/V offset <0.05 ms, RSS 137 MB); 30-min soak 2.2x
  (no leak); preview ~58 fps. Real 1080p/4K screen recordings and thermal behaviour are unmeasured.

## Live capture not verified (TCC)
- macOS Screen Recording was not re-granted for the `Yapcam Dev Signing` build, so every real
  `ScreenCaptureKit` run fails with -3801. Unverified live: display/window/area capture,
  pause/resume on real streams, system-audio capture, event-tap cursor/click capture,
  exclusion of Yapcam's own windows, countdown/HUD timing, global hotkeys driving a real
  recording, recovery after kill -9, the 10-minute A/V sync test, export-vs-preview diff on a
  real capture. These are covered only by unit tests with injected services and by the
  synthetic fixture pipeline (Tests/E2E).
- Interactive UI (mouse on toolbar, area selector, editor timeline gestures) was checked via
  snapshots and model tests, not by real clicking.

## Reference (Screen Studio) fidelity
- REA analysis of the Electron app was limited (resource limit; truncated graph; obfuscated
  strings; extraction not allowed). Reference behaviour is therefore from official guides,
  the asset/binary inventory and assumptions. **No [observed] rows**; exact defaults, slider
  ranges, preset numbers and animation curves are Yapcam choices, not matched values.
  Observation with the user is scheduled for the morning.
- Guide wording conflicts left open (cursor animation preset names).

## Not implemented / partial
- Cursor sets: original vector cursors with a core catalog and editor palette/shape/size picker
  (CUR-06); no large collection like the reference's ~24 sets.
- Cloud features (links, comments, accounts, payments, telemetry, auto-update) are out of
  scope by design.
- Intro/outro: fade (and modes added by editor); no scene-transform library.
- Speech enhancement is classic DSP (high-pass, noise reduction, compressor, loudness), not an
  ML model; quality on real noisy speech unverified. Captions rely on Apple on-device Speech;
  availability depends on system language packs; real host check pending.
- Native AAC decoding for silence detection is unavailable in restricted sandboxes (explicit
  error); PCM verified.
- GIF: no audio; very short frame delays may be clamped by viewers.
- Third-party licence acknowledgements file not yet generated (docs/THIRD_PARTY.md).

## Process limits
- Codex-team worktrees could not write `.git`; Lead committed their work, so history has
  "checkpoint" commits. Branch `team/qa` is rebased on main and needs fetching from the
  worktree rather than pushing (non-fast-forward after rebase).
- Test suites that need Metal/ffprobe only run outside the sandbox (strict mode:
  `YAPCAM_REQUIRE_RENDER_HARDWARE=1`).
