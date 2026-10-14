READY (d475be3) M1+M2 UI complete against the engine seam; end-to-end recording/editor open blocked only on capture+editor integration (Requests)

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

## In progress / Next
- `LiveEngine` mapping `RecordingEngine` → capture/editor APIs as soon as they exist on main (one file, one line to set `RecordingController.engine`).

## Not verified (open)
- Real mouse/click interaction with the toolbar and popovers (no screen-recording permission for my shell, so no live screenshots; popover side logic: arrowEdge `.trailing` when toolbar on left half, `.leading` on right half — from Apple docs, not seen).
- Real mic/camera devices (none on this Mac), multi-display behavior, Retina.
- Whole record → stop → editor path (engine is `UnavailableEngine`: starting a recording shows "The capture engine is not integrated in this build yet." — explicit, not simulated).

## Blockers
- `YapcamCapture` / `YapcamEditor` are empty stubs on all branches at the time of writing.

## Assumptions
- App talks to capture/editor only through `Sources/Yapcam/Recording/Engine.swift` (`RecordingEngine`, `EngineSession`). Area rect is display-local points with top-left origin (SCStream `sourceRect` convention); capture should interpret `CaptureTarget.area` the same way — please confirm in SWIFT_API.md.
- Permissions, displays, window list, device lists are UI-local (CoreGraphics/AVFoundation/ScreenCaptureKit) until `CapturePermissions`/`CaptureSources` exist; trivial to swap.
- Window thumbnails use `SCScreenshotManager` (needs screen permission).
- Default storage `~/Movies/Yapcam`.

## Requests (to Lead)
- SWIFT_API.md: confirm `CaptureTarget.area` rect is top-left-origin display-local points.
- SWIFT_API.md: `RecordingSession` should expose a way to observe an engine-initiated failure (state `.failed` is enough; UI polls `state`).
- When capture lands: add `Tests/YapcamUITests`-style testability? Executable target `Yapcam` cannot be imported by tests; consider splitting UI into a library target `YapcamApp` + thin executable (Package.swift is yours).
