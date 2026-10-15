READY HEAD qa: F10 verified fixed; hotkey + after-recording live checks need ui hooks (Requests)
READY 930128d qa: scripted input + auto-zoom verified live F9 window packages
READY b6bf19b qa: pause A/V + toolbar exclusion verified live; drive-input needs Accessibility
READY 769e499 qa: live QA results (TEST_REPORT section 4), findings F6/F7

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

- Main fc29d18 includes my live results. Deleted my 10-min test package (F6 verified). Remaining NOT RUN: scripted input (needs Accessibility/Input Monitoring grant), UI-driven undo/redo/autosave (no hook), hotkey-driven recording (Accessibility).

- Permissions granted (launch rule: `open -n -W`): scripted input PASS (38/38, max 15.4 ms, 0.98 pt), auto-zoom from real clicks PASS. Remaining NOT RUN: hotkey-driven recording, UI-driven undo/redo/autosave (no hook).

- F9 retest on main 511f831 (rebuilt app): STILL FAILS (`missing field display_name` for a completed window package). main only has the decision doc (display_name written always, read as optional); capture/core code for it is not on main yet. Retest command: `--capture-selftest 6 --target window:<id>` then `LiveRecordingTests/testOpenRealRecording`.

- Gap list folded into FEATURES.md (section L: 57 GAP-* rows with impact H/M/L, owners, status; section M: extras beyond the reference; 14 existing rows corrected to reference values; per-team backlog by impact). Lead decisions recorded: keep extras, own dark default background (no Apple wallpapers), adopt reference hotkey layout.

- Main badc4e4: F9 verified fixed; `--live-e2e` default flow still passes after ui recording-flow and editor layout redesigns. Open: F4 (editor status home path).

- Main 5328b45: gap rows UI-1..13 and ED-1..17 re-statused from the ui/editor status files (all 'not live-verified by qa'). Live re-verification of the new ui flow (hotkeys layout, countdown, widget, after-recording action) is pending: another Yapcam instance (/Users/larry/yapcam build, pid seen 16:20) is running; global hotkeys would collide and its toolbar would show in my recordings, so I did not launch. Please tell qa when that instance is closed. core/render/capture gap rows not yet re-audited.

- Capture gap rows CAP-1..7 re-audited from capture status (APIs landed, wiring pending). Core and render report no reference-alignment work yet. Main unchanged at 5328b45; the other Yapcam instance (pid 39997) still runs, so live rechecks of ui H items are still pending.

- Audit vs main f611874 (freeze lifted): all gap rows CORE-1..10, RND-1..9, ED-7/8/9/15, CAP-3 re-statused from core/render/editor status (source APIs landed; editor/ui wiring and native acceptance open); backlog table rewritten by team. Live re-verification of ui H items still blocked: another Yapcam instance (pid 74073 from /Users/larry/yapcam) is running.

- Main eacbd4d: UI-5 window options complete (set size, saved sizes, ignore window); preset/default isolation under tests landed. Live recheck still blocked by the running instance (pid 74073).

- Live DoD re-run on main c1bf553 done (see TEST_REPORT section 4): PASS except F10 (low). Not run live: hotkeys (second Yapcam instance running) and after-recording buttons (no hook). Request: ui hook for the after-recording choices; Lead: close other Yapcam instances for the hotkey run.

## In progress
- M2 refinement of FEATURES.md values (preset lists, defaults).

## Next
- Tests/E2E/PipelineE2ETests.swift (5 tests, pass) run via `scripts/qa/run-e2e.sh`; Request: Lead register an E2E test target in Package.swift.
- Run verify-package.sh / drive-input against first integrated capture build.

## Blockers
- Screen Studio observation STILL blocked after Lead relayed user authorization: classifier denied `rea open_binary`/`analyze_javascript_application` (integrity mismatch needs record-and-continue) and shell screencapture lacks permission ("could not create image from display"). Needs the user to add Bash/mcp__rea__* allow rules or run the observation themselves. Earlier note: denied by the permission classifier (bundle string search and `rea analyze_javascript_application`). So no [observed] rows and no exact option values/defaults. Needs user decision: allow REA/observation of /Applications/Screen Studio.app. Workaround used: guide pages, asset inventory, own assumptions (marked).
- Bundle strings are obfuscated anyway; REA/observation is the only practical route.

## Findings (live, main b5d1268)
- F9 FIXED (verified by qa on main badc4e4: window package has display_name, opens, edit+export OK). Original: [capture + core, HIGH] A completed WINDOW recording cannot be opened in core: `Project.create` -> `status(2, "missing field `display_name`")`. session.json source for kind=window has no `display_name` (capture leaves it nil: keys are app_bundle_id, content_rect_points, display_id, kind, scale, window_title); core model.rs `display_name: String` is required. Area/display packages are fine. Impact: window recordings cannot be edited/exported/recovered-then-opened. Repro: `open -n -W build/Yapcam.app --args --capture-selftest 6 --target window:<id>` then LiveRecordingTests/testOpenRealRecording. Fix: capture writes display_name (e.g. the display the window is on) and/or core defaults it to "".
- F6 FIXED (verified by qa on main 529f208: LiveRecordingTests 4/4 on the 10-min package). Original report: [render (AudioTimeline/Exporter) + core (audio_ranges), HIGH] Export of a REAL recording fails with `decode("The operation could not be completed")` when the export range includes the last ~100 ms and audio is on. Repro: record `build/Yapcam.app --capture-selftest 600`, then `YAPCAM_LIVE_PACKAGE=<pkg> swift test --disable-sandbox --filter LiveRecordingTests/testTailExportDiagnostics` -> `full-tail+audio: FAIL | tail-100ms+audio: OK | full-tail,no-audio: OK`. Cause hypothesis: system.m4a (decodes cleanly in ffmpeg) is 16 ms shorter than the segment (600.067 s vs 600.083 s); the audio range is built from segment duration, not the audio file's real end, so AVAssetReader reads past EOF. Fix: clamp audio ranges to the file duration (or treat EOF as silence). Same as Lead's live-e2e "HYPOTHESIS CONFIRMED". Blocks M1 export for every real recording with system audio (the editor's default export).
- F7 [Lead/process, MEDIUM] Two of my long runs (1 s and 7.5 min) were killed by other processes without a crash report (4-min and 10-min runs under the lock file were fine). Lock-file rule works.
- F8 FIXED (verified by qa on 3b68bde). Original: [capture, LOW] Window recording: session.json `tracks.screen.pixel_size` = [1627,1015] but screen.mov is 1626x1014 (even-size rounding). Consumers that trust pixel_size (render source geometry) may be off by 1 px; either write the real file size or document rounding. Repro: `Yapcam --live-e2e <dir> window`.
- A/V sync, 10 min: PASS (drift 7.3 ms). Export-vs-preview: PASS (0.50/255).

- Self-test flags on main 529f208 used: pause+A/V PASS, toolbar exclusion PASS (frames viewed, deleted), drive-input BLOCKED on Accessibility/Input Monitoring grant for build/Yapcam.app (user). Still waiting: F6 fix (render).
- REC-18 recovery: PASS (see TEST_REPORT section 4). Waiting for ui hooks (--capture-selftest target/pause, --ui-record-selftest, --drive-input-selftest) on main; F6 retest pending render fix (package kept in ~/Movies/Yapcam/QA/capture).

- Handover pass (main 3b68bde): editor UI rows PASS (selftest, crash-after-autosave, crash-now journal, export 1080p with audio), hotkeys PASS, F8 fixed + lock cleanup verified, suites re-run (Rust 68, XCTest 129, Swift Testing 340). OPEN: F9 window recordings (capture+core), F4 home path in docs/status/editor.md.

- F10 FIXED (verified on 3dd0d3b: editorInFront=true). Original: [ui, LOW] After Stop the editor opens but `editorInFront=false` in the self-test (main c1bf553). Repro: `open -n -W build/Yapcam.app --args --drive-input-selftest 12 --source display`, read probe.log. May be a self-test activation artifact; ui please confirm with a manual run.

## Live QA log (2026-10-15 morning, main b5d1268)
- Shared machine: Lead's `live-e2e` harness and my live runs collide (one display, one mouse). My first 10-min run was killed ~1 s after start (package stuck at status "recording", no crash report) while live-e2e ran at the same time. Please tell qa when the machine is free, or serialize runs; I log start/end times here.
- My shell has no Accessibility and no Screen Recording permission (AXIsProcessTrusted false), so I cannot drive the UI by CGEvent or screenshot. `scripts/qa/drive-input.swift` events from my shell are NOT delivered. Only code running inside the signed app has the grants.

## Requests (to Lead)
- ui HOOKS for the remaining live rows (qa cannot edit Sources, shell has no Accessibility): (1) `--hotkey-selftest [--only start|display|window|area|pause|restart]`: register the REAL HotkeyManager table, post each default combo with its exact modifiers from inside the app, and log what each did (phase changes, source mode, overlay shown, restart confirm shown); the current `--live-e2e hotkey` uses the old API and hardcoded Option-Command flags. (2) `--after-recording create|copy|save [--quick-widget]` on `--ui-record-selftest`: set the choice, record 4 s, log the created project / clipboard file URL / saved path and quick-widget state. Also run when no other Yapcam instance is up (the main-checkout instance registers the same global hotkeys).
- USER ACTION: grant Accessibility and Input Monitoring to build/Yapcam.app (System Settings > Privacy & Security), then qa reruns `--drive-input-selftest` (scripted clicks/moves vs events.jsonl, CUR-02) and the hotkey scenario.
- Optional: add `YapcamCapture` to the E2E test target deps so recover checks can live in Tests/E2E (today scripts/qa/run-recover-check.sh uses a scratch copy with cleanup trap).
- Live QA hooks in the signed app (ui/capture; I cannot edit Sources): extend `--capture-selftest` with options `--target display|window:<title>|area:x,y,w,h`, `--pause-after <s>`, `--no-audio`, `--out <dir>`, and add `--drive-input <script.json>` (post scripted moves/clicks from inside the app, which has Accessibility) so pause/resume, window/area capture and scripted-input timing can be tested without my shell having permissions.
- Push: after `git rebase main` my local team/qa (head: see git log) diverged from origin/team/qa; plain push is non-fast-forward and the classifier denied force-push and an ours-merge. Please fetch from ~/yapcam-team/qa directly (worktrees share the repo) or push it yourself; content is identical apart from the rebase.
- Package.swift: add `.testTarget(name: "E2E", dependencies: ["YapcamRender","YapcamCore"], path: "Tests/E2E")`.
- Re-grant Screen Recording (and system audio) for the current signed build, or tell me how the grant is keyed (F2).
