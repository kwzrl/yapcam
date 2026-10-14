READY (pending) M1 UI shell: toolbar, countdown, HUD, settings, onboarding, shortcuts — builds; recording needs capture/editor integration (see Requests)

# ui status

## Done (verified)
- App shell: AppKit-managed windows, menu bar item + Dock (toggle in settings), main menu, About. Verified: `scripts/build-app.sh` builds and app launches.
- Vertical floating non-activating toolbar (grabber, source, system audio, record, settings), compact recording view (timer, pause/resume, stop, restart, cancel). Verified via `Yapcam --snapshot-ui <dir>` PNGs, light + dark.
- Countdown (0/3/5 s) overlay + toolbar countdown state; global shortcuts (Carbon hotkeys, rebindable in Settings → Shortcuts); permissions onboarding with deep links; settings window.
- Position persistence per display (fraction of display frame), clamp on display change.

## In progress
- M2 items (window picker, area overlay, camera/mic menus, recent projects, recovery dialogs).

## Next
- Hook `LiveEngine` once capture + editor are on main.

## Blockers
- None for UI work. `YapcamCapture` / `YapcamEditor` are empty stubs on all branches, so recording cannot run end to end yet.

## Assumptions
- The app talks to capture/editor only through `Sources/Yapcam/Recording/Engine.swift` (`RecordingEngine`). `UnavailableEngine` is the default and fails loudly ("capture engine not integrated"). When capture lands, add a `LiveEngine` mapping 1:1 to docs/SWIFT_API.md and set it in `RecordingController.engine`.
- Permissions, displays and device lists are UI-local (CoreGraphics/AVFoundation) until `CapturePermissions`/`CaptureSources` exist.
- Default shortcuts: ⌥⌘R start/stop, ⌥⌘P pause/resume.

## Requests (to Lead)
- Package.swift: the `Yapcam` target has no test target; request `.testTarget(name: "YapcamTests", dependencies: ["Yapcam"])` is not possible for executable targets without refactor. Fine for now.
