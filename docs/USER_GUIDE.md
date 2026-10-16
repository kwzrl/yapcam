# Yapcam user guide

Yapcam records your screen on a Mac and lets you polish the result, all locally. No account,
no cloud, no watermark. This guide covers what works on `main` today. Things I could not
test on real hardware are marked **(untested live)**; see `docs/KNOWN_LIMITATIONS.md` for the full list.

## Install and build

Requirements: macOS 15+, Apple Silicon, Xcode 26 (or matching Command Line Tools), Rust stable.

```sh
scripts/install-hooks.sh     # once: secret/media guard for commits
scripts/build-app.sh         # builds and signs build/Yapcam.app
open build/Yapcam.app
```

The build signs with a local identity called `Yapcam Dev Signing`. Keep using the same
identity: macOS ties privacy permissions to the signature, so a different one means granting
everything again. There is no installer yet; run the app from `build/`.

## Permissions

On first launch Yapcam shows a permissions window. Each row explains why it is needed:

| Permission | Needed for | Required |
|---|---|---|
| Screen & System Audio Recording | recording the display, windows, system audio | yes |
| Microphone | recording your voice | no |
| Camera | camera overlay | no |
| Accessibility | following window focus and the cursor precisely | no |
| Input Monitoring | clicks (and keystrokes, if enabled) for zoom and effects | recommended |

The first press on **Allow** asks macOS; after that the button opens the right System Settings
pane. Screen recording changes only apply after you quit and reopen Yapcam. Reopen the window
any time from **Yapcam → Permissions…**. If macOS says screen recording is denied for Yapcam
even though you turned it on, you probably rebuilt with a different signing identity: toggle
Yapcam off and on again in System Settings and restart the app.

## Recording with the toolbar

A narrow floating toolbar sits at the right edge of your screen. Drag it by the dotted grabber
at the top; it remembers its position per display and stays on screen when displays change. The **×**
at the top hides it (bring it back from the menu bar item or by clicking the Dock icon). Yapcam's own
windows are excluded from the recording.

Top to bottom:

- **Display / Window / Area**: one click picks the source and shows its overlay with a big
  **Start recording** button (the chevron next to it has frame rate, countdown and system audio: Off, All apps or Selected apps).
  *Display* dims the display under your pointer and shows its name and size (move to another display and
  the card follows). *Window* highlights the window under the pointer; click it or press Start recording.
  *Area* lets you drag a rectangle (aspect presets Free, 16:9, 4:3, 1:1, 9:16; arrow keys move it,
  Shift+arrows resize, Option moves by 10); Start recording or Return begins. Esc cancels any overlay.
  The toolbar's own Record button starts with the last used source. Recording a USB iPhone/iPad exists in
  the code but has no toolbar entry until it has been tested with a real device.
- **Camera**, **Mic**, **System**: toggles (blue = on). The small chevron opens the device menu in a
  side popover; with no device it says "No camera" / "No microphone" and recording continues without.
  Not tested with real mic/camera devices **(untested live)**.
- **Folder** opens the recordings folder; **Settings** opens a menu: Settings, Recordings, Speaker Notes,
  Permissions, Hide Toolbar, Quit.
- The big **Record** button.

Speaker notes (Settings menu or Recording → Speaker Notes…) open a small window; its **Teleprompter**
button shows the notes large in a floating window that never appears in the recording, with text size
and auto-scroll speed. Notes are saved into the project when you stop.

Press Start recording: if a countdown is set (None by default; 3, 5 or 10 s in Settings → General or the card's chevron), a "Get ready" card with a filling ring appears (Continue or Return starts at once, Esc cancels). Then the toolbar
turns into a compact view with the timer, **Pause/Resume**, **Stop**, **Marker** (a flag at this moment, saved with the recording), **Restart** (discard this take and start over) and
**Cancel** (delete the recording); both ask first. While recording, the menu bar icon is a red stop button and the Dock icon shows ●. Stop (button, hotkey or menu bar) saves the recording and opens the editor at once, in front, on the new recording.

**System audio** (speaker button, or Settings → Recording): *Off*, *All apps* (the default) or *Selected apps*, where you tick the running apps to record. Before a recording starts, Yapcam checks for problems (a chosen camera or microphone that is unplugged, a camera with no microphone, a possibly covered microphone, a missing permission, a selected app that has closed) and asks what to do: continue, choose another device, open System Settings, or cancel. Nothing is asked when everything is fine.

Verified live on this Mac (display, window and area capture, pause/resume, system audio): Record → countdown → recording → Stop → the editor
opens on the new recording, and the toolbar, countdown and timer are **not** in the recorded video.
The first time you record, macOS may show a prompt that Yapcam wants to bypass the system window
picker and capture your screen directly; choose **Allow** (macOS asks again from time to time).

## Shortcuts

Global (work from any app) unless noted; all can be rebound or cleared in **Settings → Shortcuts**, which
says "Not able to register" or "Already used" when a combination can't be used.

| Action | Default |
|---|---|
| Start / finish recording | ⌃⌘↩ |
| Record display / window / area | ⌥⌘3 / ⌥⌘4 / ⌥⌘5 |
| Pause / resume | ⌥⌘P |
| Restart recording (asks first) | ⌥⌘⌫ |
| Add marker | ⌃⌥⌘F |
| Show / hide toolbar | ⌥⌘' |
| Teleprompter play / pause | ⌥⌘. |
| Show / hide speaker notes (in Yapcam) | ⌥⌘/ |
| Open last recording, quick export copy / save (in Yapcam) | ⌥⌘Z, ⌥⌘C, ⌥⌘S |
| Cancel recording | not set |

Keys are physical positions: the character printed on screen follows your keyboard layout.

Other menu shortcuts: ⌘, Settings · ⇧⌘R Recordings window · ⌘O Open Recording · ⌘I Import Video ·
⌘Z / ⇧⌘Z undo/redo · ⌘B split at playhead · ⌘K command palette in the editor.

## After recording

The chevron on the Record button chooses what happens at Stop: **Create project** (default, the editor opens at
once), **Export and copy to clipboard**, or **Export and save to file** (1080p MP4 with audio, no editor). The
button then reads "Start recording", "Record & Copy" or "Record & Save". Optionally a small quick-export widget
(Copy, Save…, Edit) appears instead of the editor (Settings → Quick export). New recordings also get automatic
zooms from your clicks (Settings → Editing). These new after-recording paths are unit-tested but **untested live**.

## Settings

- **General**: countdown, Dock icon, menu bar item.
- **Recording**: frame rate (30/60), hide desktop icons while recording, start/stop sounds, keystroke
  recording. Hiding icons restarts Finder briefly and restores icons afterwards, even after a crash
  **(untested live)**. Sounds play before capture starts and after it stops, never inside the recording.
- **Shortcuts**, **Storage** (recordings folder, free space), **Advanced** (reset toolbar position,
  show onboarding again, export diagnostics, open logs folder).

## Editing basics

Open a recording from the Recordings window, **File → Open Recording…**, or by double-clicking a `.yapcam` package (the Finder association is declared in the app but **untested live**). **File → Import Video…** turns an existing MOV/MP4 into a project (screen track
only, no cursor events).

The editor has a preview, a timeline and an inspector with five tabs: **Look** (background, padding,
corners, shadow, aspect ratio), **Overlays** (text, highlights, captions), **Cursor**, **Camera**, **Audio**.

- **Timeline**: split at playhead (S or ⌘B), delete a selection (⌫), speed up a clip, undo/redo
  (⌘Z / ⇧⌘Z). Cuts shift video, audio and events together. J/K/L shuttle playback.
- **Zoom**: add a zoom at the playhead (Z), drag its focus point on the preview, or let Yapcam
  generate automatic zooms from clicks.
- **Captions**: "Generate captions from speech" uses Apple's on-device speech recognition. It asks for
  Speech Recognition permission the first time; availability depends on the language packs on your
  Mac **(untested live)**.
- **Autosave**: edits are journaled; if Yapcam quits unexpectedly, reopening the project offers to
  restore them.

### Presets

The **Presets** menu saves the current look (canvas, cursor, zoom defaults…) under a name, applies a
saved preset to the open editor, imports/exports preset files for sharing, and opens the presets folder.

## Export

In the editor choose **Export…**: format (MP4 H.264, MP4 HEVC, MOV H.264 or GIF without audio),
resolution (720p up to 2160p), frame rate (24/30/60), quality, include audio. The file is checked after
writing (reopened, duration and tracks verified). Cancelling removes the partial file.

Verified live: a real 8-second recording exported to 1920×1080 MP4 with its audio track, and a scripted
edit session (split, delete, zoom, padding, undo/redo) survived a hard kill and reopened intact.

## Where files live

| What | Where |
|---|---|
| Recordings (`Name.yapcam` packages) | `~/Movies/Yapcam/` (change in Settings → Storage) |
| Presets | `~/Library/Application Support/Yapcam/Presets/*.yapcampreset` |
| Logs | `~/Library/Logs/Yapcam/probe.log` |
| Settings | the app's preferences (`mov.yapcam.Yapcam`) |

A `.yapcam` package is a folder: `project.json` (your edits, written atomically, previous version kept
as `project.json.prev`), `recording/` (raw screen, audio, camera and event files, untouched by edits)
and `autosave/`. In the Recordings window, right-click a recording to rename, duplicate, show in Finder,
**Extract Raw Files…** or move to the Trash. Nothing is ever uploaded.

## Recovery

- **Interrupted recording**: if Yapcam or your Mac stopped mid-recording, the next launch offers to
  recover what was written to disk (also shown as a banner in the Recordings window). If the recording
  stops itself (for example low disk space) you get an alert and the part recorded so far is kept.
  Recovery of the *editor's* unsaved edits after a hard kill is verified live; recovering a recording interrupted mid-capture is covered by capture's tests.
- **Unsaved edits**: the editor offers to restore or discard them when you reopen the project.
- **Missing media**: opening a project whose media files moved offers Locate… to relink them.
- **Low disk**: recording won't start below 1 GB free and warns below 2 GB while recording.

## When something goes wrong

Alerts say what happened and what to do. For anything unclear use **Yapcam → Export Diagnostics…** and
attach the text file to a bug report; it contains versions, permission states, displays and the recent
log, and no recordings.
