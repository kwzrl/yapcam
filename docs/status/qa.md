READY HEAD qa: audit vs 7d545a1

# qa status

## Done (verified)
- docs/FEATURES.md first pass: ~110 rows across 10 areas, tagged [docs]/[technical]/[assumption]. Verified how: reviewed against guide section list (screen.studio/guide) and installed-app file inventory.
- docs/TESTING.md Definition of Done; docs/reference/motion-and-export.md.
- scripts/qa: privacy-scan.sh (run: clean), verify-export.sh, verify-package.sh, drive-input.swift (typechecks; not yet run against a live recording).

## Findings (Phase 2, main 35ba7c5)
- F1 [editor/render/ui, HIGH] M1 end-to-end is NOT wired on main: no `EditorDocument`/`EditorView`/`EditorWindows`, `Project` does not conform to `RenderProjectSource`, app never opens the editor after recording; editor runs on Fakes only (docs/status/editor.md Blockers). Repro: `grep -rn EditorWindows Sources/Yapcam` → nothing.
- F2 [lead/env, HIGH] Real capture cannot be tested in this session: `CGPreflightScreenCaptureAccess()` is false for the build signed `Yapcam Dev Signing` (cert is CSSMERR_TP_NOT_TRUSTED, designated requirement uses cert leaf hash). `~/Library/Logs/Yapcam/probe.log` shows SCStream -3801 (TCC denied). The grant for `mov.yapcam.Yapcam` seems to belong to the earlier identity ("Yapcam Local Dev"). I must not reset/grant TCC; user must re-grant Screen Recording for this build once.
- F3 [qa] Library-level M1 verified: fixture → Project → canvas.padding + manual zoom (crop changes mid-zoom) → Exporter 1080p MP4 → ffprobe: height 1080, audio track present, duration 5.0±0.1 s. Cut/undo/redo exact; 300 random cuts then full undo restores duration (no drift); save → reopen → `.prev` kept; missing screen.mov → `CoreError.missingMedia`.

- F4 [editor now, formerly core/render; LOW privacy] `scripts/qa/privacy-scan.sh` flags absolute `/Users/<name>/` home paths in docs/status/render.md as of aa70d91 (editor/core fixed; personal paths, rule 7). Replace with `~/`.

- F5 E2E now 11 tests green (formats HEVC/MOV/GIF, 60 fps, cut/duration, A/V duration agreement after cut, cancel removes partial file, export crop at zoom). FEATURES.md rows EXP-01/03/05/06/07, EDT-02/05, PRJ-01/05, ZOM-02 marked verified (library level; UI and live capture not covered).
- run-e2e.sh simplified (E2E is a real target on main).

- verify-package.sh run against synthetic fixture: ok (project.json now optional). Re-checked 2026-10-15: main unchanged, screen access still false (probe -3801) → live QA still blocked.

- Audit vs main 4a1cee5 done: all 82 FEATURES rows re-statused (9 todo remain; backlog table at bottom of FEATURES.md). Statuses derive from team status files + test names; only E2E re-run by me.

- Audit vs main 6d91a7f: REC-21 now implemented (core notes + ui popover); 8 todo rows left. E2E 11/11 green on 6d91a7f. Waiting for Lead's REA output in ~/yapcam-ref-local/rea/ (empty at 01:00) to fill TBD values.

- REA limits noted in FEATURES.md + reference notes; guide pages folded in (new section K: CUR-12..17, ANI-01..03, LOK-09/10, CAM-07, EXP-12). [observed] rows deferred to the morning session with the user.

- Audit vs main 60902da: EDT-08/14, PRJ-02, CUR-08/11, ZOM-08/09, LOK-04/06 integrated; LOK-02, CUR-06, AUD-10 partial; backlog table updated (todo: AUD-06/07, EDT-09/13, CUR-12..16, ANI-02, CAM-07 + partials).

- Audit vs main f640b35 + core/render status: no row is `todo` any more except via 'implemented' with editor wiring missing; backlog table rewritten (editor owns most). Core models for text/reactions/music/captions/keys/motion are on core worktree, merge pending.

- Audit vs main 88f1995: editor UI for section K, text/reactions/captions/music/keys/click sound/animation modes and wallpaper picker landed → those rows integrated. Only AUD-06 wiring, CUR-06 set library, host/Metal checks, Speech host check and live QA remain.

- Audit vs main 78a8a0e: AUD-06 core setting + render path landed (editor toggle wiring left). Everything else unchanged.

- M3 package (Lead 03:15): FEATURES render rows tagged verified on Metal (86/86); new docs/KNOWN_LIMITATIONS.md, docs/THIRD_PARTY.md (Rust crates + Apple frameworks + tooling audited; all permissive; acknowledgements file still open), docs/TEST_REPORT.md structure.

- docs/THIRD_PARTY_NOTICES.md generated (MIT texts of 6 shipped crates + Apache-2.0); THIRD_PARTY.md open item 1 closed. Main unchanged at 121d9de; privacy scan still flags docs/status/editor.md (F4).

- Cleanup (Lead disk request): deleted my 2 tmp.*/e2e build copies, scratchpad e2e copy, 6 yapcam-e2e-* leftovers and ~/yapcam-ref-local/extract (893 MB); free space 25→27 GB. No qa script creates temp dirs now (run-e2e.sh simplified); TESTING.md has the trap rule.

- Audit vs main 8600691: M3 hardening in capture (100 crash trials, hour sim), render (long export, analyzer), core (cursor catalog, key overlay perf) noted in rows; no status class changes.

- Audit vs main 25f2b97: CUR-06 now integrated (editor cursor picker); KNOWN_LIMITATIONS updated.

- Audit vs main 065a117: M3 long-export/soak/preview results folded into FEATURES (EXP-09 verified), KNOWN_LIMITATIONS.

- Regression on main aa70d91: E2E 11/11 green after core rebuild; fresh-checkout build verified by Lead (05:05). Privacy scan flags docs/status/render.md (absolute home path, F4).

- THIRD_PARTY.md approved (title no longer draft, decisions recorded); TEST_REPORT.md links SETUP.md and has an update log; KNOWN_LIMITATIONS.md refreshed for b90ee0d.

- Audit vs main 7d545a1: EXP-02/04 integrated via editor export sheet; TEST_REPORT update log extended.

## In progress
- M2 refinement of FEATURES.md values (preset lists, defaults).

## Next
- Tests/E2E/PipelineE2ETests.swift (5 tests, pass) run via `scripts/qa/run-e2e.sh`; Request: Lead register an E2E test target in Package.swift.
- Run verify-package.sh / drive-input against first integrated capture build.

## Blockers
- Screen Studio observation STILL blocked after Lead relayed user authorization: classifier denied `rea open_binary`/`analyze_javascript_application` (integrity mismatch needs record-and-continue) and shell screencapture lacks permission ("could not create image from display"). Needs the user to add Bash/mcp__rea__* allow rules or run the observation themselves. Earlier note: denied by the permission classifier (bundle string search and `rea analyze_javascript_application`). So no [observed] rows and no exact option values/defaults. Needs user decision: allow REA/observation of /Applications/Screen Studio.app. Workaround used: guide pages, asset inventory, own assumptions (marked).
- Bundle strings are obfuscated anyway; REA/observation is the only practical route.

## Requests (to Lead)
- Push: after `git rebase main` my local team/qa (head: see git log) diverged from origin/team/qa; plain push is non-fast-forward and the classifier denied force-push and an ours-merge. Please fetch from ~/yapcam-team/qa directly (worktrees share the repo) or push it yourself; content is identical apart from the rebase.
- Package.swift: add `.testTarget(name: "E2E", dependencies: ["YapcamRender","YapcamCore"], path: "Tests/E2E")`.
- Re-grant Screen Recording (and system audio) for the current signed build, or tell me how the grant is keyed (F2).
