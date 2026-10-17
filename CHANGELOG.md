# Changelog

## 0.10.1 — fixes from the first hands-on test

- Fixed a crash when pressing Start on the display/window source overlay (settings observer used
  `objectWillChange.values`, which traps on back-to-back changes; now a debounced Combine sink).
- The scissors tool now splits zooms, camera layouts and highlights at the click, not only clips.
- Reel preview (TikTok/Instagram safe areas) is offered and drawn only on portrait canvases.

## 0.10.0 — release candidate (Screen Studio 4.0.4 parity pass)

Rebuilt the workflow, layout, defaults and option sets to match Screen Studio 4.0.4 closely,
with Yapcam's own code, artwork, wallpapers, music, cursors and sounds. Parity audit: 127 of 129
in-scope reference items match in code and tests (cloud features stay out of scope).

- Editor: dark stage with a floating inspector card, one rail icon per section (Background, Cursor,
  Camera Layout, Camera Style, Captions, Edit by transcript, Audio, Keyboard shortcuts, Animations),
  pill option groups, colour rows with hex field and eyedropper, ⌘K command menu, prominent Export,
  Reel preview (Instagram/TikTok safe areas, preview only), preview quality menu, centred transport,
  audio waveform in the clip track, "Click or drag to add zoom on cursor", rename in the top bar.
- Timeline keys: C split, X ripple delete, Backspace remove, copy/paste of item settings; fits the
  project length on open; area after the end is set off.
- Masks: Sensitive data blurs (strength 32) or covers; Highlight dims the rest (0.5); masks with motion
  keyframes can be trimmed and moved.
- New projects: dark wallpaper background, 10 % padding, 16 pt corners, directional shadow, captions at
  0.05 with expanding growth, reference springs and cursor defaults.
- Cursor: Original and Touch plus 12 own sets with per-type variants; sharp large system cursors.
- Camera: smart framing keeps the camera off the cursor, hide during silence, fullscreen-camera and
  screen-only layouts; layouts re-arrange when the aspect ratio changes.
- Audio: background music library (4 categories, 18 own tracks), library folder, drag-and-drop.
- Recording: two-step Esc in the picker, quick export widget with summary, Hide Desktop Icons through the
  capture filter (Finder is no longer restarted), recording saved to disk about every 2 s.
- Export: MP4 720p/1080p/4K up to 60 fps, GIF up to 1080p, clipboard export, queue status, separate
  remembered settings for the export dialog and quick export, optional software encoder
  (Settings > Advanced).
- Settings: autosave switch, appearance (dark default), variable frame rate, rebindable shortcuts.

Not verified on this build: real mouse/keyboard use, camera, microphone, Retina and multiple displays,
first install on another Mac, notarization, 4K seek/export speed (F17/F18).

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
