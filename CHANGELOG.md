# Changelog

## 0.9.0 — release candidate

Yapcam records and edits screen videos locally on Apple Silicon Macs running
macOS 15 or later. Projects, media and exports stay on the Mac; no account,
cloud service or watermark is required.

- Record a display, window or selected area, with pause/resume and optional
  system audio, microphone and camera tracks. Use recording shortcuts, a floating
  recording widget, countdown options and speaker notes.
- Keep screen, audio and input data in recoverable project packages. Reopen
  projects, restore interrupted edits and relink missing media.
- Cut, split, trim and speed up recordings with undo/redo. Generate zooms from
  clicks, follow the cursor, adjust manual zooms and review typing suggestions.
- Style the canvas with backgrounds, padding, corners, directional shadows and
  insets. Adjust cursor appearance, smoothing, click effects and motion blur.
- Add camera layouts, sensitive-area masks, keyboard overlays, text, reactions,
  captions, music and intro/outro effects. Caption data supports font families
  and timed word reveal; advanced visual controls depend on the renderer and
  editor integration, as listed in the known limitations.
- Export local MP4/MOV videos and GIFs with size, frame-rate and compression
  choices. Preview controls, audio processing and project presets support the
  editing workflow.
- Package an optimized app and a signed disk image with version/build metadata,
  integrity checks and an explicit Developer ID notarization workflow.

### Notes for testers

This is a release candidate, not a claim that every workflow has passed manual
acceptance. Read [Known limitations](docs/KNOWN_LIMITATIONS.md) and follow the
[first-install and update checks](docs/RELEASE.md). Some older entries in the
limitations document are labeled historical; use the latest test report for
current verification evidence.

The local `Yapcam Dev Signing` disk image is **not distributable**: it has no
Apple-trusted signature, secure timestamp or notarization ticket. Public
distribution requires Developer ID signing, notarization and native install
acceptance. Switching from a development signing identity may require macOS to
ask for capture/input permissions again.

Real camera and microphone capture, voice quality, USB recording, Retina and
multiple displays are **untested (no hardware)** on the current test machine
(one non-Retina display). On-device captions depend on native language/model
availability; recognition and noisy-speech quality need separate host testing.
Experimental variable-frame-rate export stays opt-in. Native GPU/codec and
interactive checks must be distinguished from synthetic and model tests.

There are no cloud sharing, account, telemetry or automatic update features.
