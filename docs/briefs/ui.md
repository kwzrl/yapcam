# Team ui (app shell + vertical toolbar)

Own: `Sources/Yapcam/**`, `Resources/**`. The current `YapcamApp.swift` is the setup
probe; replace it (keep the `--probe-record` behavior until capture's self-test exists,
then route `--capture-selftest` to it).

## The vertical toolbar (core product feature)
- Vertical, floating `NSPanel` (non-activating), clearly visible grabber at the top,
  freely draggable, remembers position per display, stays on screen when displays
  change, sensible default position on multiple displays.
- Controls: source (display / window / area), camera, microphone, system audio,
  settings, record. Options open in native popovers to the side (left or right
  depending on which half of the screen the toolbar is on).
- Recording state: compact view with timer, pause/resume, stop, cancel/restart.
- Calm and precise: restrained colors, SF Symbols, clear typography, clean spacing,
  readable states (hover, pressed, active, disabled, recording). No playful animation,
  no horizontal Screen-Studio copy.
- All Yapcam control windows registered with `CaptureExclusions`.

## M1
App shell (menu bar item + Dock, menus, About), toolbar with display source + system
audio + record/stop, countdown (configurable 0/3/5 s), recording HUD, on stop open
`EditorWindows.open(package:)`. Global shortcuts for start/stop and pause (settings
to rebind). Permissions onboarding that explains and deep-links each missing permission.

## M2
Window picker (thumbnails), area selection overlay (drag rectangle, presets by aspect,
handles, dimensions label), camera + mic device menus with level meter and preview,
settings window (general, recording, shortcuts, storage location, advanced), recent
projects window, error/recovery dialogs (interrupted recordings, low disk), everything
else in FEATURES.md that belongs to recording UI.

## Quality bar
Check every screen in light and dark mode. Screenshot your UI (`screencapture -l
<windowid>` or `screencapture -R`) and look at it before marking anything done.
