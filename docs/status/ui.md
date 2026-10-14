READY ui: review findings 1,2,6,7,8,10 fixed; 119 tests green; live recording still unverified (screen TCC grant missing)

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

## Review fixes (review-ui-editor-1.md)
- #1 fixed (done earlier): `LiveEngine.openEditor` → `EditorWindows.open`; no Finder placeholder left.
- #2 fixed: imports reserve their destination (`ProjectActions.reserveURL/release`), failure only removes the reserved package. Test: `reservedImportDestinationsDoNotCollide`.
- #6 fixed: pause/resume/stop/cancel/restart are serialized through one op chain and UI state changes optimistically, so Pause→Stop can't overlap capture calls or strand the controller. No unit test (needs screen permission to reach `begin()`); reasoned only.
- #7 fixed: Discard and Quit now returns `.terminateLater` and replies after `cancelAndWait()` finishes deleting. Not unit-tested.
- #8 fixed: `PermissionsModel.act` asks macOS on the first press (remembers it asked, since screen/accessibility/input report `.denied` before asking), then opens Settings. Test: `permissionButtonAsksBeforeOpeningSettings` (state only).
- #10 fixed: AppKit Edit menu (Undo/Redo/Split/Add Zoom/Palette + standard Cut/Copy/Paste) routed to the key editor window via `EditorBridge` (reads `EditorWindowController.editorDocument` by reflection; ⌘Z inside a text field still goes to the field). Tests: `bridgeFindsEditorDocumentProperty`, `mainMenuHasEditorCommands`. Request to editor: a public `EditorWindows.keyModel` accessor to replace the reflection.
- `swift test`: 119 pass.

## After integration b93ce7d
- Rebased; build green. Still open: live record → stop → editor unverified (screen TCC for `Yapcam Dev Signing` missing); speaker notes (REC-21) needs core field.

## Backlog check (earlier)
Main unchanged (35ba7c5), branch already rebased. Re-ran `--capture-selftest 3`: still SCStream -3801 (no screen-recording grant for `Yapcam Dev Signing`). Every remaining ui item depends on something outside my files: live record/stop verification (TCC grant), editor hand-off (`EditorWindows.open`), speaker notes (core field). Nothing else open in docs/briefs/ui.md or FEATURES.md rows owned by ui.
