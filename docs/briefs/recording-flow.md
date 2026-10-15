# Brief: recording flow (user feedback 2026-10-15)

Owner: ui (capture only if an API is missing). Reference behaviour observed by the user in
Screen Studio 4.0.4; we build our own design, vertical toolbar stays.

## Source → start, in one step
- **Display:** clicking the Display button immediately shows an overlay on the display
  under the cursor: dimmed display, centered card with display name (e.g. "SyncMaster"),
  "1680×1050 · 60 fps" and a prominent **Start recording** button with a small chevron for
  options (fps, countdown, system audio). Moving the mouse to another display moves the card
  there. Click Start → countdown (if enabled) → recording. Esc cancels.
- **Window:** hovering highlights the window under the cursor (tinted fill + outline) with
  the same card (app + window title + size, Start recording). Click the window or the button
  to start.
- **Area:** drag a rectangle (handles, size label, aspect presets); the card with Start
  recording sits next to the selection. Enter starts.
- The toolbar's Record button still works and starts with the last used source.
- All overlays are Yapcam windows → registered with `CaptureExclusions`.

## Stop → editor
- Stop (toolbar, hotkey, menu bar) finalizes the package and opens the editor window right
  away, in front, with the new recording loaded and playing position at 0. No Finder, no
  dialog. This must hold for every way of stopping.

## Remove
- **Device** source: remove from the toolbar until a real device has been tested. Keep the
  capture code; no UI entry.
- Notes stay out of the toolbar.

## Acceptance
- Live self-tests: `--ui-record-selftest` variants for display/window/area that go through the
  overlay + Start path; QA verifies overlay absent from video and editor opens after stop.
- Snapshot renders of each overlay state, light and dark.
