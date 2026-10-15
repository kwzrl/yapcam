READY ui: live record→stop→editor verified, toolbar/HUD absent from video; BUG for core+render: export with audio fails on real recordings (see status)

# ui status

## Done (verified)
Verification method "snap" = `build/Yapcam.app/Contents/MacOS/Yapcam --snapshot-ui <dir>` renders our own windows/popovers to PNGs in light + dark and I looked at them. "build" = `scripts/build-app.sh` + `swift test` green, app launches and stays up, global hotkeys register without error.
- App shell: AppKit windows, menu bar item + Dock (both switchable), main menu (File/Recording/Window), About, quit-while-recording guard. (build)
- Vertical floating non-activating toolbar: grabber, source, system audio, mic, camera, record, settings; compact recording view with timer, pause/resume, stop, restart, cancel; countdown state; low-disk/device warnings. (snap, light+dark)
- Countdown overlay 0/3/5 s on the target display. (snap of view; timing logic by reading only)
- Global shortcuts via Carbon hotkeys, default ⌥⌘R start/stop, ⌥⌘P pause/resume, rebindable in Settings → Shortcuts. (build: registered)
- Permissions onboarding explaining and deep-linking screen, mic, camera, accessibility, input monitoring. (snap)
- Settings window: General, Recording, Shortcuts, Storage, Advanced. (snap)
- Source popover with Display / Window (thumbnail grid) / Area; area selection overlay (drag, move, 8 handles, dimension label, aspect presets Free/16:9/4:3/1:1/9:16, Return/Esc) plus click-through outline while idle. (snap of overlay + popovers; mouse interaction NOT exercised)
- Mic and camera popovers: device list, Off, level meter, camera preview, permission prompt, "no device" and "selected device not connected" states. (snap of no-permission state only; no devices on this Mac)
- Recordings window (thumbnails, open, reveal, trash) with interrupted-recording banner + Recover; launch-time recovery alert; low-disk check before start (<1 GB blocks) and during recording (<2 GB warns). (snap of empty state)
- Toolbar position remembered per display as fraction of display frame; clamped to visible frame on display changes; default right edge, vertically centred.

## Done since integration (build + unit tests, 48 green)
- Rebased on main 35ba7c5. UI split into library `YapcamUI` + thin `Yapcam` executable (`main.swift`), test target `YapcamUITests` (key combos, error mapping, rename/duplicate, permission table).
- `LiveEngine` wraps real `RecordingSession` (area = top-left display-local points). Engine failure observed via `state == .failed`: alert + Recordings window (interrupted banner); package is never cancelled.
- `--capture-selftest <seconds>` → `CaptureSelfTest.run`, result in `~/Library/Logs/Yapcam/probe.log`.
- Backlog done (build only, not run live): PRJ-04 .yapcam file association + Open With handler, PRJ-07 rename/duplicate/trash, PRJ-06 extract raw files, REC-16 Import Video… (Project.importVideo), OOS-06 Export Diagnostics…, AUD-09 start/stop sounds (played outside capture), REC-13 hide desktop icons (Finder CreateDesktop with crash-safe restore marker), REC-14 Dock toggle (exists).

## In progress / Next
- REC-21 speaker notes needs a notes field in project.json (core) — request below.

## Not verified (open)
- Real mouse/click interaction with the toolbar and popovers (no screen-recording permission for my shell, so no live screenshots; popover side logic: arrowEdge `.trailing` when toolbar on left half, `.leading` on right half — from Apple docs, not seen).
- Real mic/camera devices (none on this Mac), multi-display behavior, Retina.
- Whole record → stop → editor path (engine is `UnavailableEngine`: starting a recording shows "The capture engine is not integrated in this build yet." — explicit, not simulated).

## Blockers
- Signing identity changed to `Yapcam Dev Signing` on main; macOS TCC grants made for `Yapcam Local Dev` do not carry over. `--capture-selftest 3` fails with SCStream -3801 (screen recording not granted; app logs `screen access false`). Needs one manual grant in System Settings → Privacy → Screen & System Audio Recording for build/Yapcam.app (I did not touch TCC). Until then no real record → stop run from UI.
- `YapcamCapture` / `YapcamEditor` are empty stubs on all branches at the time of writing.

## Assumptions
- App talks to capture/editor only through `Sources/Yapcam/Recording/Engine.swift` (`RecordingEngine`, `EngineSession`). Area rect is display-local points with top-left origin (SCStream `sourceRect` convention); capture should interpret `CaptureTarget.area` the same way — please confirm in SWIFT_API.md.
- Permissions, displays, window list, device lists are UI-local (CoreGraphics/AVFoundation/ScreenCaptureKit) until `CapturePermissions`/`CaptureSources` exist; trivial to swap.
- Window thumbnails use `SCScreenshotManager` (needs screen permission).
- Default storage `~/Movies/Yapcam`.

## Requests (to Lead)
- Grant screen recording (and mic/camera/input monitoring/accessibility as wanted) to the `Yapcam Dev Signing` build, then run `open -n build/Yapcam.app --args --capture-selftest 3`.
- Editor: provide `EditorWindows.open(package:)` per SWIFT_API.md.
- Core: a `notes` field in project.json (+ `set(path:)` support) for REC-21 speaker notes.
- SWIFT_API.md: confirm `CaptureTarget.area` rect is top-left-origin display-local points.
- SWIFT_API.md: `RecordingSession` should expose a way to observe an engine-initiated failure (state `.failed` is enough; UI polls `state`).
- When capture lands: add `Tests/YapcamUITests`-style testability? Executable target `Yapcam` cannot be imported by tests; consider splitting UI into a library target `YapcamApp` + thin executable (Package.swift is yours).

## LIVE end-to-end (screen recording granted, main b5d1268)
Driver: `Yapcam --live-e2e <dir>` (`Support/LiveE2E.swift`) runs the real controller path the toolbar buttons use (toolbar shown, 3 s countdown, record 5 s with cursor motion, stop, editor opens, export) and screenshots the whole display at each step with ScreenCaptureKit (own windows NOT excluded). Screenshots live in the session scratchpad `…/scratchpad/e2e*/01-idle…05-after-export.png`; they show your desktop, so not committed.
Results:
- idle toolbar, countdown (toolbar shows "2" + Cancel, big "2" overlay centered), recording HUD (00:02, Pause/Stop/Notes/Restart/Cancel), editor opening on the new recording: all work. Package: HEVC 1680×1050, ~290 frames/5.03 s, system.m4a, events.
- Toolbar, HUD and countdown overlay are ABSENT from the recorded screen.mov: extracted frames at 0.3 s, 2.0 s and 4.0 s with ffmpeg (the full-screen screenshot at the same moment shows them, the recorded frames don't). Cursor also absent from video (as designed).
- macOS shows a one-time "Yapcam wants to bypass the system window picker" prompt on first capture (visible in the screenshots); documented in the user guide.
- BUG (not in my files): export with audio fails: `RenderError.decode("The operation could not be completed")`; model and direct `Exporter` both. Export without audio succeeds. Root cause confirmed by experiment: `audio_ranges` for system_audio says `file_end_ns` 5 027 856 333 but the real `system.m4a` is 4.98 s long (raw AVAssetReader on both files is fine); trimming 100 ms off the project tail makes export-with-audio succeed. The audio file is ~50 ms shorter than the segment (normal for SCStream audio). Fix belongs in core (clamp audio range to the real file duration when building ranges) and/or render (`AudioTimeline`: clamp `insertTimeRange` to the asset's actual duration, never fail the whole export). Repro package kept: `~/Movies/Yapcam/Recording-2026-10-15T082900-2CD84F.yapcam` (delete when fixed); run `Yapcam --live-e2e /tmp/x` or open it and Export with audio.
- More live runs through the toolbar controller (`--live-e2e <dir> area|window|pause`, countdown 0, 2 s + 2 s each):
  - Area 800×500 at (200,150): video is exactly 800×500, content is the selected region (frame viewed). Confirms the top-left display-local convention end to end.
  - Window (Terminal): video 1626×1014 for a 1627×1015 pt window (capture rounds down to even sizes; harmless), content is the window.
  - Pause/resume: toggled via `togglePause` (phase paused → recording): 2 segments, 2.16 s + 1.93 s = 4.09 s, the 2 s pause is excluded.
  - Test recordings deleted afterwards.
- Global hotkeys: `--live-e2e <dir> hotkey` registers the real shortcuts and presses ⌥⌘R / ⌥⌘P with synthetic CGEvents. Result here: the events do not trigger the hotkey (posting synthetic key events needs the Accessibility permission for Yapcam, which is not granted; onboarding shows it as "Allow"). So hotkey-driven recording stays unverified. After granting Accessibility to build/Yapcam.app, rerun that command; or press ⌥⌘R by hand.
- Requests: core + render: the audio range clamp above (high: blocks exporting any real recording with audio).
- Deleted my other four test recordings.

## Visual polish pass + user guide (main e007d36)
`--snapshot-ui` now writes every window at 1× and 2× (`<name>.png`, `<name>@2x.png`) in light + dark, 84 images, and also renders each settings pane and the notes popover. Reviewed all of them against docs/briefs/ui.md. Before → after:
- BUG (found via the review): toolbar was stuck at 300 pt tall (SwiftUI size read with `sizingOptions = []` returned the frame), so the idle toolbar with 7 controls clipped its top/bottom. After: sized from `intrinsicContentSize`, refit again after first layout; idle 66×408, recording 66×326, countdown 66×126.
- Window popover rendered as a blank panel while loading → "Looking for windows…" spinner.
- Notes editor had no hint → placeholder text. Recordings empty state said "saved in Yapcam" → shows `~/Movies/Yapcam`. Storage pane showed `/Users/<name>/…` → `~/…`.
- Snapshot harness fixes (not app bugs): pre-fills the backdrop so dark windows render properly at 2×; each popover is built right before it is written so the Window/Area modes are really shown.
- Checked and left as is: spacing/typography consistent (11 pt uppercase section headers, 14 pt popover padding, 13 pt body), active/hover/pressed states readable in both appearances, record button states clear, onboarding rows aligned, 2× shows no blur or clipping. Known limit: translucent material blur and the area overlay's dim hole aren't reproducible in a bitmap snapshot.
- `docs/USER_GUIDE.md` written from what exists on main; untested live paths are marked in it.

## M3 hardening (main a02a89e)
1. Accessibility (code + helper tests; VoiceOver itself not run):
   - Labels/hints/selected traits on every toolbar button, source/mic/camera rows, window cells, level meter (percent value), teleprompter controls, shortcut recorder, onboarding rows ("Allow for Microphone"). Decorative icons hidden. Toolbar is one labelled group with VoiceOver actions "Move toolbar left/right/up/down" (keyboard-equivalent of dragging). Recording time has a spoken value ("1 minute 5 seconds"); state changes are announced (started, paused, resumed, stopped, countdown).
   - Area overlay is keyboard-operable (arrows move, ⇧ resizes, ⌥ ×10, Return/Esc) and exposes role/label/value/help.
   - Reduce Motion: level meter and teleprompter scroll stop animating (teleprompter steps once a second). Reduce Transparency: panels use solid backgrounds (`PanelSurface`). Increase Contrast: stronger outlines/fills (`ContrastOpacity`).
   - Tests: `AccessibilityTests` (contrast helper, spoken times, keyboard move stays on screen). NOT verified: the SwiftUI accessibility tree can't be built headlessly, so labels weren't asserted. Manual check list: VoiceOver on, ⌃⌥→ through the toolbar; Full Keyboard Access Tab order top→bottom; System Settings → Accessibility → Display (Reduce motion/transparency, Increase contrast) and re-snapshot.
2. Multi-display and scale math: placement/clamp/relocation rules extracted to pure `ToolbarGeometry` + `AreaGeometry` (`Support/Geometry.swift`); toolbar controller and area outline now use them. `GeometryTests` simulate 1×/2× displays and arrangements left, right, above (negative and offset origins): default placement, saved-fraction round trip, clamping to menu bar, display removal (last used → main → saved spot), resolution shrink, popover side per display, area local↔global conversion, pixel size per scale, clipping/rejecting a saved area when the display changes (recording now clips or says "the saved area no longer fits on …").
3. Error messages: `UserMessage` turns errors into what happened + what to do (permission → exact System Settings pane + "Open System Settings" button on the alert; disk full → Settings → Storage; SCStream -3801 → permission text instead of the raw localized TCC string; os-error suffixes and NSError dumps never shown; fallback points to Export Diagnostics). All alert sites use it. `UserMessageTests`.
Tests: 252 pass.

## Review round 2 fixes (review-claude-2.md)
- prior #2: import reservations are case-insensitive/Unicode-normalized; the UI no longer deletes anything on import failure (core's `importVideo` removes only what it created). Test `reservationIsCaseInsensitive`.
- new #2: "Add Preset File to Library…" is a no-op for the library's own file and replaces through a temp copy (`PresetStore.addToLibrary`), so a failed copy never loses a preset. Tests `addingLibraryPresetToItselfKeepsIt`, `failedAddKeepsExistingPreset`.
- new #4: applying a preset (menu routes) now refreshes the editor's cached project wrapper, redraws the preview, nudges observers and saves (`PresetStore.apply(_:to: EditorDocument)`). Test `applyingPresetUpdatesEditorAndSaves` (model value + saved project.json). Request to editor: a public `EditorDocument.applyPreset(from:)` that does this via `perform`/`didEdit` (undo + dirty tracking); my version marks no undo state.
- new #5: `EditorWindows.transcriber` is installed at launch, running capture's `TranscriptionService` (asks for Speech Recognition on first use; `NSSpeechRecognitionUsageDescription` added to Info.plist). Test `transcriberIsInstalled`. Real transcription not run live (needs speech permission + a recording with audio).

## After main f640b35
Rebased. REC-21/PRJ-02/smoke test were already done (see below); added the teleprompter part of REC-21: floating, capture-excluded `TeleprompterController` panel (large notes text, font size, auto-scroll speed, back to top) opened from the Notes popover, hidden when a recording ends; included in `UISmokeTests` (light + dark). 200 tests pass. All ui-owned FEATURES.md rows are implemented; open: live verification (TCC grant), EXP-10 quick share belongs to the editor's export sheet.

## Backlog from Lead (main 6d91a7f)
1. Review #10 (editor commands in AppKit menu): already on main since the previous merge: Edit menu (Undo/Redo/Split/Add Zoom/Palette) → key editor via `EditorBridge`. `git log main..team/ui` was empty at rebase, so the editor's "still open" note is stale.
2. PRJ-02 preset UI done: "Presets" menu (Save Current Look as Preset…, Apply "<name>", Apply Preset File…, Export Preset File…, Add Preset File to Library…, Show Presets Folder); library in `~/Library/Application Support/Yapcam/Presets/*.yapcampreset`, using core `exportPreset/importPreset`. Test `saveListApplyRoundTrip` (core round trip + name cleaning). Menu click-through not exercised live.
3. REC-21 notes UI: done earlier (below).
4. UI smoke test done: `UISmokeTests` renders every window/popover (toolbar ×4 states, onboarding, settings, source ×3, audio, mic, camera, notes, recordings, area overlay) in light + dark and fails on missing/tiny/flat-colour PNGs; one test in-process (`UISnapshot.render`), one launches `build/Yapcam.app` with `--snapshot-ui` (skipped if the app isn't built). Both pass.
Known limit: snapshots draw our own views (no real screen), so material blur isn't judged.

## REC-21 speaker notes (done, unit-tested)
Notes button in idle + recording toolbar (popover editor; visible while recording). On stop, `ProjectActions.attachNotes` writes `notes` into project.json via `.set(path:"notes")` before the editor opens; failure shows an alert without losing the recording. Test `notesPersistInProject` (fixture package). Live path unverified (no screen TCC). Notes request to core is resolved. 147 tests pass.

## Review fixes (review-ui-editor-1.md)
- #1 fixed (done earlier): `LiveEngine.openEditor` → `EditorWindows.open`; no Finder placeholder left.
- #2 fixed: imports reserve their destination (`ProjectActions.reserveURL/release`), failure only removes the reserved package. Test: `reservedImportDestinationsDoNotCollide`.
- #6 fixed: pause/resume/stop/cancel/restart are serialized through one op chain and UI state changes optimistically, so Pause→Stop can't overlap capture calls or strand the controller. No unit test (needs screen permission to reach `begin()`); reasoned only.
- #7 fixed: Discard and Quit now returns `.terminateLater` and replies after `cancelAndWait()` finishes deleting. Not unit-tested.
- #8 fixed: `PermissionsModel.act` asks macOS on the first press (remembers it asked, since screen/accessibility/input report `.denied` before asking), then opens Settings. Test: `permissionButtonAsksBeforeOpeningSettings` (state only).
- #10 fixed: AppKit Edit menu (Undo/Redo/Split/Add Zoom/Palette + standard Cut/Copy/Paste) routed to the key editor window via `EditorBridge` (reads `EditorWindowController.editorDocument` by reflection; ⌘Z inside a text field still goes to the field). Tests: `bridgeFindsEditorDocumentProperty`, `mainMenuHasEditorCommands`. Request to editor: a public `EditorWindows.keyModel` accessor to replace the reflection.
- `swift test`: 119 pass.

## After integration b93ce7d
- Rebased; build green. Still open: live record → stop → editor unverified (screen TCC for `Yapcam Dev Signing` missing).

## Backlog check (earlier)
Main unchanged (35ba7c5), branch already rebased. Re-ran `--capture-selftest 3`: still SCStream -3801 (no screen-recording grant for `Yapcam Dev Signing`). Every remaining ui item depends on something outside my files: live record/stop verification (TCC grant), editor hand-off (`EditorWindows.open`), speaker notes (core field). Nothing else open in docs/briefs/ui.md or FEATURES.md rows owned by ui.

## Temp cleanup (Lead request, main 0df4bbb)
Listed `$TMPDIR` for ui-created dirs (`yapcam-ui-*`, `yapcam-notes-*`, `yapcam-preset-*`, `yapcam-r2-*`, `yapcam-smoke*`, `yapcam-case-*`): none left (every test removes its temp dir with `defer`). Deleted my scratchpad snapshot dir (548 KB). I create no repo copies or harness dirs and have no scripts; any future script gets an `EXIT` trap. Did not touch other teams' dirs, `~/Movies/Yapcam/{Probes,QA}` (not mine) or my worktree `.build` (468 MB, in use).
