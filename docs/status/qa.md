READY HEAD qa: E2E 11 tests green, run-e2e.sh simplified, FEATURES statuses

# qa status

## Done (verified)
- docs/FEATURES.md first pass: ~110 rows across 10 areas, tagged [docs]/[technical]/[assumption]. Verified how: reviewed against guide section list (screen.studio/guide) and installed-app file inventory.
- docs/TESTING.md Definition of Done; docs/reference/motion-and-export.md.
- scripts/qa: privacy-scan.sh (run: clean), verify-export.sh, verify-package.sh, drive-input.swift (typechecks; not yet run against a live recording).

## Findings (Phase 2, main 35ba7c5)
- F1 [editor/render/ui, HIGH] M1 end-to-end is NOT wired on main: no `EditorDocument`/`EditorView`/`EditorWindows`, `Project` does not conform to `RenderProjectSource`, app never opens the editor after recording; editor runs on Fakes only (docs/status/editor.md Blockers). Repro: `grep -rn EditorWindows Sources/Yapcam` → nothing.
- F2 [lead/env, HIGH] Real capture cannot be tested in this session: `CGPreflightScreenCaptureAccess()` is false for the build signed `Yapcam Dev Signing` (cert is CSSMERR_TP_NOT_TRUSTED, designated requirement uses cert leaf hash). `~/Library/Logs/Yapcam/probe.log` shows SCStream -3801 (TCC denied). The grant for `mov.yapcam.Yapcam` seems to belong to the earlier identity ("Yapcam Local Dev"). I must not reset/grant TCC; user must re-grant Screen Recording for this build once.
- F3 [qa] Library-level M1 verified: fixture → Project → canvas.padding + manual zoom (crop changes mid-zoom) → Exporter 1080p MP4 → ffprobe: height 1080, audio track present, duration 5.0±0.1 s. Cut/undo/redo exact; 300 random cuts then full undo restores duration (no drift); save → reopen → `.prev` kept; missing screen.mov → `CoreError.missingMedia`.

- F4 [core, render; LOW privacy] `scripts/qa/privacy-scan.sh` flags absolute `/Users/<name>/` home paths in docs/status/core.md and docs/status/render.md (personal paths, rule 7). Replace with `~/`.

- F5 E2E now 11 tests green (formats HEVC/MOV/GIF, 60 fps, cut/duration, A/V duration agreement after cut, cancel removes partial file, export crop at zoom). FEATURES.md rows EXP-01/03/05/06/07, EDT-02/05, PRJ-01/05, ZOM-02 marked verified (library level; UI and live capture not covered).
- run-e2e.sh simplified (E2E is a real target on main).

## In progress
- M2 refinement of FEATURES.md values (preset lists, defaults).

## Next
- Tests/E2E/PipelineE2ETests.swift (5 tests, pass) run via `scripts/qa/run-e2e.sh`; Request: Lead register an E2E test target in Package.swift.
- Run verify-package.sh / drive-input against first integrated capture build.

## Blockers
- Screen Studio observation STILL blocked after Lead relayed user authorization: classifier denied `rea open_binary`/`analyze_javascript_application` (integrity mismatch needs record-and-continue) and shell screencapture lacks permission ("could not create image from display"). Needs the user to add Bash/mcp__rea__* allow rules or run the observation themselves. Earlier note: denied by the permission classifier (bundle string search and `rea analyze_javascript_application`). So no [observed] rows and no exact option values/defaults. Needs user decision: allow REA/observation of /Applications/Screen Studio.app. Workaround used: guide pages, asset inventory, own assumptions (marked).
- Bundle strings are obfuscated anyway; REA/observation is the only practical route.

## Requests (to Lead)
- Package.swift: add `.testTarget(name: "E2E", dependencies: ["YapcamRender","YapcamCore"], path: "Tests/E2E")`.
- Re-grant Screen Recording (and system audio) for the current signed build, or tell me how the grant is keyed (F2).
