# Team qa (reference inventory first, then QA)

Own: `docs/FEATURES.md`, `docs/reference/**`, `docs/TESTING.md`, `scripts/qa/**`,
`Tests/E2E/**`.

## Phase 1 — reference inventory of Screen Studio 4.0.4-4926 (first 2–3 hours)
Build a complete inventory of all locally available recording, editing, project,
audio, cursor, camera, layout and export functions. Sources, each labeled:
- **[observed]** practical use of `/Applications/Screen Studio.app` (it is installed
  and logged in; use the REA `capture-native-ui-scenario` / `capture-electron-scenario`
  tools or screenshots to look at every panel and menu),
- **[docs]** official documentation (screen.studio guides/changelog),
- **[technical]** REA analysis — the app is Electron: `rea analyze-javascript-application`
  on the installed app for settings schema, project format, export options, defaults,
- **[assumption]** our own inferences/design decisions.
Cloud/account/sharing/payment/website features: list and mark *out of scope*.

Deliverable `docs/FEATURES.md`: one table row per feature —
`ID | Area | Reference behavior | Source tag | Yapcam behavior | Team | Status | Acceptance test`.
Status values: `todo / implemented / integrated / verified (how) / limited (why)`.
Put larger notes (e.g. zoom animation curves, cursor smoothing behavior, export preset
list) in `docs/reference/*.md` in your own words. Never copy their code, strings,
assets or binaries; raw REA output and screenshots stay in
`~/yapcam-ref-local/` (outside the repo). Commit FEATURES.md early (first pass within
~1 hour), then refine; mark READY in your status file each time.

## Phase 2 — QA
Real-use tests of integrated `main` builds following the Definition of Done list in
`docs/TESTING.md` (write it): toolbar, recording, pause/resume, cursor/zoom with
scripted actions (`cliclick`-free: use CGEvent via a small Swift script in
scripts/qa), cut/zoom editing, undo/redo, autosave, reopen, export vs preview
comparison (frame diffs with ffmpeg), A/V sync on a 10-minute recording, failure
paths, exclusion of Yapcam windows in the exported file, repo privacy scan.
File findings in `docs/status/qa.md` with repro steps and the owning team.
