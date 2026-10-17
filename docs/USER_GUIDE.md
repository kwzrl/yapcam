# Yapcam user guide

Yapcam records your screen on a Mac and lets you polish the result, all locally. No account,
no cloud, no watermark. This guide covers release candidate 0.9.0. Things that were not
tested on real hardware or by real mouse/keyboard use are marked **(untested live)**; see
`docs/KNOWN_LIMITATIONS.md` for the full list.

## Install from the disk image

Open `Yapcam-0.9.0-<build>.dmg`, drag **Yapcam** onto **Applications**, eject the image and start Yapcam
from Applications. Compare the image with its `.sha256` file first (`shasum -a 256 -c <file>.sha256`).
Release candidates that are not notarized by Apple show a Gatekeeper warning on first launch; open the
app once with right-click → **Open**. See `docs/RELEASE.md` for how packages are built and signed.

## Build from source

Requirements: macOS 15+, Apple Silicon, Xcode 26 (or matching Command Line Tools), Rust stable.

```sh
scripts/install-hooks.sh     # once: secret/media guard for commits
scripts/build-app.sh         # builds and signs build/Yapcam.app
open build/Yapcam.app
```

The build signs with a local identity called `Yapcam Dev Signing`. Keep using the same
identity: macOS ties privacy permissions to the signature, so a different one means granting
everything again. A development build runs from `build/`;
a release package is made with `scripts/release/make-release.sh` (`docs/RELEASE.md`).

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

## Recording with the picker

Yapcam opens a floating bar (the recording picker), by default at the bottom center of your screen.
Drag it by the dotted grabber on its left; it remembers its position per display and stays on screen when
displays change. The **×** on the left (or **Esc**) closes it; bring it back from the menu bar item or by
clicking the Dock icon. Yapcam's own windows are excluded from the recording.

Left to right:

- **Display / Window / Area** (keys **1 / 2 / 3** while the picker is open): one click picks the source and
  shows its overlay with a big **Start recording** button; its chevron holds the after-recording action
  and the countdown. Click the highlighted mode again, or press Esc, to deselect it; Esc with no mode
  selected closes the picker. *Display* dims the display under your pointer and shows its name, size and
  refresh rate (right-click the Display button to choose a display directly). *Window* highlights the window
  under the pointer with a card (app icon, name, size and **Resize**): Resize sets an exact window size
  (16:9, 4:3, 9:16, 16:10, square, only sizes that fit your display, **Custom…**, **Save current size**)
  and needs Accessibility; **Adjust recording area** turns the window into an area; the ⋯ menu has Ignore
  this window, Reset ignored windows, Select window, Bring to front, Record entire display.
  *Area* ("Drag area you want to record") lets you drag a rectangle (minimum 150×150; aspect Any, 16:9, 4:3, 1:1,
  3:4, 9:16 or Custom; X/Y/W/H fields; **Saved sizes**); arrow keys move it by 1 point, ⇧ by 10, ⌘+arrows
  resize by 1, ⌘⇧ by 10. Start recording or Return begins; Esc cancels. Recording a USB iPhone/iPad exists in
  the code but has no picker entry until it has been tested with a real device.
- **Camera, Microphone, System audio**: one button each, showing the current choice ("No camera", the device
  name, "Record system audio", "Sound from 3 apps", "No system audio"). A click opens the menu: devices
  (the system default is marked), **Don't record …**; the camera menu also has **Max camera resolution**
  (720p, 1080p default, 4K: a maximum, not a promise) and **Hide camera preview**; the microphone menu shows a live level.
  A floating camera preview shows while you pick. System audio is off by default; *Record system audio from
  selected apps* lists the running apps to tick. Not tested with real mic/camera devices **(untested live)**.
- **Recover** appears when unfinished recordings exist. **Recent** lists your recent projects with search
  and stays open next to the picker if you leave it open. The **gear** menu is described below.

Speaker notes (gear menu, Recording → Speaker Notes…, ⌘⌥/) open a small window; its **Teleprompter**
button shows the notes large in a floating window that never appears in the recording, with text size
(12–32), auto-scroll speed (0–25) and notepad opacity (0.4–1); ⌘⌥. plays and pauses. Notes are saved into the
project when you stop.

**Gear menu**: *While Recording*: Hide Desktop Icons (off), Hide Dock Icon (on), Highlight Recorded Area (on),
Show Speaker Notes. *After Recording*: Open Quick Export Widget (on) and the after-recording action.
*Recording Countdown*: None, 3, 5 or 10 seconds. *Advanced → Recording Engine*: Yapcam has one engine,
ScreenCaptureKit. Then Settings…, Projects…, Permissions….

Press Start recording: a short start sound plays first (Settings → Recording; recording begins when it
ends, after at most about half a second, even if sound playback fails; the sound is not recorded).
If a countdown is set (None by default), a "Get ready" card with a filling ring appears (Continue or Return starts at once, Esc cancels). Then the picker
turns into the recording widget (48 pt tall): **Stop** with the timer, **Pause/Resume**, **Restart** (discard this take and start over), **Marker** (a flag at this moment, saved with the recording) and
**Cancel** (delete the recording); restart and cancel ask first. While recording, the menu bar icon is a red stop button; the Dock icon is hidden (Hide Dock Icon) or shows ●. Stop (button, hotkey or menu bar) saves the recording and opens the editor at once, in front, on the new recording.
Your take is written to disk as it records, so it can be recovered after a crash.

Before a recording starts, Yapcam checks for problems (a chosen camera or microphone that is unplugged, a camera with no microphone, a possibly covered microphone, a missing permission, a selected app that has closed) and asks what to do: continue, choose another device, open System Settings, or cancel. Nothing is asked when everything is fine.

Verified live on this Mac (display, window and area capture, pause/resume, system audio) with the earlier vertical toolbar: Record → countdown → recording → Stop → the editor
opens on the new recording, and the toolbar, countdown and timer are **not** in the recorded video. The horizontal picker of this version has been tested offscreen only **(untested live)**.
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

The after-recording action (gear menu, the chevron on the Start recording button, or Recording → After Recording) chooses what happens at Stop: **Create project** (default, the editor opens at
once), **Export and copy to clipboard**, or **Export and save to file** (no editor). The
button then reads "Start recording", "Record & Copy" or "Record & Save". By default a small quick-export widget
(preview, "Will export …", Copy, Save…, Edit, and a settings button) appears bottom left instead of the editor (turn it off in the gear menu or Settings → Quick export). Quick export uses the format,
resolution, frame rate, compression and codec you set in Settings → Quick export. New recordings also get automatic
zooms from your clicks (Settings → Recording). These after-recording paths are unit-tested but **untested live**.

## Settings

Tabs: **General**, **Recording**, **Editing**, **Quick export**, **Shortcuts**, **Experimental**, **Advanced**.

- **General**: Start Yapcam at login (works from the installed app), Hide Dock Icon, menu bar item, review permissions, Reset preferences (keeps your recordings, the recents list and the recordings folder).
- **Recording**: Save new projects to (recordings folder, free space), Highlight recorded area, Create zooms automatically, Show recording widget, Countdown, Max camera resolution, start/stop sounds (on), keystroke recording (on; needs Input Monitoring).
- **Editing**: Use last project settings as default for new recordings, autosave every 30 s, Save presets in.
- **Quick export**: format, resolution, frame rate, compression, codec, audio; the widget toggle; the after-recording action.
- **Shortcuts**: *Recording* (rebindable; "Not able to register" when macOS refuses a combination) and *Editing* (the editor's fixed keys, for reference).
- **Experimental**: variable frame rate export. **Advanced**: frame-rate cap, hide desktop icons (restarts Finder briefly and restores icons afterwards, even after a crash **(untested live)**), reset picker position, onboarding, diagnostics, logs.

## Editing basics

Open a recording from the Recordings window, **File → Open Recording…**, or by double-clicking a `.yapcam` package (the Finder association is declared in the app but **untested live**). **File → Import Video…** turns an existing MOV/MP4 into a project (screen track
only, no cursor events).

The editor has a top bar (project, undo/redo, Presets, Export), a large preview, a timeline and an
inspector with an icon rail on the right. Sections, selectable with ⌘1…⌘0: **Background** (wallpaper,
gradient, colour, image, padding, corners, shadow, inset), **Cursor** (cursor set — Original, Touch and
12 own styles — size 16–128 px, smoothing, rotation/tilt, shake removal, hide when idle, click effect),
**Camera layout** and **Camera style** (only with a camera track), **Captions** and **Edit by transcript**
(only with speech), **Audio** (volumes, voice clean-up: Voice, Noise reduction, Podcast; background music,
click sounds), **Keyboard shortcuts** overlay, **Animations**, and **Text, regions & intro/outro**.

- **Timeline**: split at playhead (S or ⌘B), delete a selection (⌫), speed up a clip, undo/redo
  (⌘Z / ⇧⌘Z). Cuts shift video, audio and events together. J/K/L shuttle playback.
- **Zoom**: add a zoom at the playhead (Z), drag its focus point on the preview, or let Yapcam
  generate automatic zooms from clicks.
- **Captions and transcript**: "Generate transcript from speech" uses Apple's on-device speech
  recognition only (nothing leaves the Mac). Choose the language or Auto, and add **Keyterms** (names,
  product words) to improve recognition. Style: size, font, word/line reveal, growth, entrance, colour,
  position. **Edit by transcript**: delete words (cuts the video), hide words (captions only), correct a
  word, remove filler words, tighten pauses. **Export transcript…** writes SRT, WebVTT or text with the
  edited timing; **Regenerate** asks first because it discards transcript edits. Measured on generated
  German and English speech files: about 9 % word error rate; Apple's recogniser often drops filler
  words like "äh"/"um", so filler removal finds fewer than are spoken. Not tested with a real microphone
  **(untested live)**.
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
| Recordings (`Name.yapcam` packages) | `~/Movies/Yapcam/` (change in Settings → Recording) |
| Presets | `~/Library/Application Support/Yapcam/Presets/*.yapcampreset` |
| Logs | `~/Library/Logs/Yapcam/probe.log` |
| Settings | the app's preferences (`mov.yapcam.Yapcam`) |

A `.yapcam` package is a folder: `project.json` (your edits, written atomically, previous version kept
as `project.json.prev`), `recording/` (raw screen, audio, camera and event files, untouched by edits)
and `autosave/`. In the Recordings window, right-click a recording to rename, duplicate, show in Finder, **Save As…**,
**Copy and Zip** (a zip of the project goes on the clipboard), **Remove from Recents**, **Extract Raw Files…** or move to the Trash. The search box filters by name; the magnifier button finds `.yapcam` packages elsewhere on your Mac. **File → Open Recording…** accepts several packages at once. Nothing is ever uploaded.

## Recovery

- **Interrupted recording**: if Yapcam or your Mac stopped mid-recording, the next launch offers to
  recover what was written to disk (also **File → Recover Recording…**, the picker's **Recover** button and a banner in the Recordings window). If the recording
  stops itself (for example low disk space) you get an alert and the part recorded so far is kept.
  Recovery of the *editor's* unsaved edits after a hard kill is verified live; recovering a recording interrupted mid-capture is covered by capture's tests.
- **Unsaved edits**: the editor offers to restore or discard them when you reopen the project.
- **Missing media**: opening a project whose media files moved offers Locate… to relink them.
- **Low disk**: recording won't start below 1 GB free and warns below 2 GB while recording.

## When something goes wrong

Alerts say what happened and what to do. For anything unclear use **Yapcam → Export Diagnostics…** and
attach the text file to a bug report; it contains versions, permission states, displays and the recent
log, and no recordings.
