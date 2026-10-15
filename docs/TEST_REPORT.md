# Yapcam test report — structure (draft; fill at handover)

Build under test: `<main sha>` · date · machine (Mac mini M4, macOS `<ver>`, 1680x1050) ·
signing identity · permissions granted: `<list>`.
Build and signing setup: see `docs/SETUP.md` (`scripts/setup-signing.sh` creates the local
"Yapcam Dev Signing" identity; `scripts/build-app.sh` builds and signs `build/Yapcam.app`).
A fresh clone builds without manual steps (Lead check 05:05, main aa70d91).

## 1. Summary
Status 2026-10-15 ~12:35, main 3b68bde (Mac mini M4, 1680x1050, signed build, all permissions granted).
- **Automated:** Rust 68 pass (1 ignored); Swift: XCTest 129 pass (9 skipped, 0 failures), Swift Testing 340 tests in 65 suites pass; render on Metal 86/86 (Lead run); E2E 11/11 plus 5 live-recording tests.
- **Live (real captures):** display, window, area, pause/resume, 10-minute recording with A/V sync (drift 7.3 ms), crash recovery, scripted input (max 15 ms / 0.98 pt), auto-zoom from real clicks, toolbar/HUD/countdown excluded, export with audio of a real 10-min recording at 1080p (4.3x realtime): all PASS.
- **Defects found:** F6 export with audio failed on real recordings (**fixed, re-verified**); F8 window `pixel_size` mismatch (**fixed, re-verified with a 201x151 window: pixel_size [200,150] == video**); F9 completed window recordings could not be opened in core (**fixed on main badc4e4, re-verified**); F4 absolute home path in docs/status/editor.md (low, open).
- **Also verified live now:** hotkey-driven recording (start/pause/resume/stop), UI-driven editor sequence (split, delete, zoom, padding, undo/redo via menu), crash after autosave and crash with only the journal (edits restored on reopen), UI export with audio (1920x1080).
- **Not tested:** real camera/mic, Retina/multi-display, permission-revoked and low-disk live (deliberately not done: injected-fault tests only), mouse-level toolbar/editor clicking (self-tests call the same actions), reference observation of Screen Studio.
- **Go/no-go:** M1 (record -> edit -> export 1080p) works end to end for display and area recordings. **Window recordings are blocked by F9** until capture/core fix `display_name`; all other recording modes pass. M2 rows: 113 in FEATURES.md (38 verified, 47 integrated, 18 implemented, 10 limited, 0 todo). M3 hardening: long export, soak, recovery, sync verified; see section 9 for limits.

## 2. Automated suites
Run 2026-10-15 12:30 on main 3b68bde outside any sandbox.
| Suite | Command | Result | Skips (why) |
|---|---|---|---|
| Rust core | `CARGO_BUILD_JOBS=4 cargo test --manifest-path core/Cargo.toml` | 68 passed, 0 failed | 1 ignored (intentional) |
| Swift, whole package | `swift test --disable-sandbox -j 4` | XCTest 129 run, 0 failures; Swift Testing 340 tests / 65 suites passed; 22 s + 26 s | 9 XCTest skipped (live tests needing `YAPCAM_LIVE_PACKAGE`, hardware gates) |
| Render on Metal (strict) | `YAPCAM_REQUIRE_RENDER_HARDWARE=1 swift test --filter YapcamRenderTests` | 86/86 (Lead run 03:15) | none |
| E2E pipeline (fixture) | `scripts/qa/run-e2e.sh` | 11/11 | - |
| Live-recording tests | `YAPCAM_LIVE_PACKAGE=<pkg> swift test --filter LiveRecordingTests` | 4/4 on the real 10-min package (+ testAutoZoomFromRealClicks 1/1 on a drive-input recording) | need a real package |
| Crash recovery check | `scripts/qa/run-recover-check.sh <interrupted pkg>` | PASS (kill -9); fails on window packages because of F9 | needs a package |
| Privacy scan | `scripts/qa/privacy-scan.sh` | FAILED: 1 finding, absolute home path in docs/status/editor.md (F4) | - |
| Benchmark line (from the full run) | `RENDER_BENCHMARK` | 1080p export 6.3x realtime, 4K 1.9x (synthetic source, 60 frames, no audio) | - |
| UI self-tests | `--editor-selftest`, `--editor-reopen-check`, `--editor-export-selftest`, `--live-e2e hotkey` | all PASS (section 4) | - |

## 3. Definition of Done checklist (docs/TESTING.md)
| # | Check | Result | Evidence / owner |
|---|---|---|---|
| 1 | Toolbar shows, modes switch, no crash | PASS (controller level) | `--ui-record-selftest`, `--live-e2e` default/area/window/pause/hotkey drive the real controller; physical mouse clicking on the toolbar not automated |
| 2 | Record display + system audio + events -> valid package | PASS | section 4, verify-package ok |
| 3 | Pause/resume duration = active time, A/V in sync | PASS | 10.18 s + 14.02 s, 12/12 pairs, drift 2.8 ms |
| 4 | Cursor/click events at scripted times (+-50 ms) | PASS | 38/38, max 15.4 ms, 0.98 pt |
| 5 | Editor opens package; preview matches background/padding | PASS for display/area; **FAIL for window (F9)** | LiveRecordingTests, `--live-e2e` editor opened; window: core refuses the package |
| 6 | Manual zoom, cut, undo/redo exact | PASS | E2E testCutUndoRedoDuration, 300-edit no-drift, real 10-min edit test; UI menu actions via --editor-selftest |
| 7 | Autosave: kill -9 then reopen, edits intact | PASS | `--editor-selftest --crash-after-autosave` and `--crash-now` then `--editor-reopen-check`; recording kill -9 + recover PASS |
| 8 | Export 1080p MP4: duration +-1 frame, tracks present | PASS | 599.1 s vs 599.08 expected, video+audio, 4.3x realtime |
| 9 | Export vs preview frame diff small | PASS | 0.50/255 mean abs luma at 720p |
| 10 | A/V sync on 10-minute recording | PASS | 300/300 pairs, -15..+24 ms, drift 7.3 ms over 10 min |
| 11 | Failure paths: no mic/camera, missing media, low disk, permission denied, source lost | PARTIAL | no devices: unit/injected; missing media: E2E PASS; source lost live: PASS (window closed mid-recording -> failed(sourceUnavailable), 5.79 s package kept as interrupted); low disk and permission revoked: capture injected-fault tests only (not done live by design) |
| 12 | Yapcam windows absent from exported file | PASS | frames of the recording viewed; export derives from them |
| 13 | Privacy scan | FAIL (low) | F4: docs/status/editor.md home path (editor) |

## 4. Live-capture tests (signed build, main b5d1268 -> c504858, 2026-10-15 10:25-12:25, Mac mini M4, 1680x1050)
Method: the app's own launch flags (`--capture-selftest N [--target window:<id>|area:x,y,w,h] [--pause-after S]`, `--ui-record-selftest`, `--drive-input-selftest`, `--live-e2e`), started with `open -n -W` under `~/Movies/Yapcam/QA/.app-lock` (my shell itself has no Accessibility/Screen Recording grants). Analysis with `scripts/qa/verify-package.sh`,
`scripts/qa/analyze-sync.py`, `Tests/E2E/LiveRecordingTests.swift`.
| Test | Result | Evidence |
|---|---|---|
| Display record + system audio + events | PASS | 8 s package: HEVC 1680x1050, 470 frames, AAC audio, events.jsonl; verify-package ok |
| 4-min recording stability | PASS | status complete, 240.14 s, 13,838 frames, RSS flat 72 MB (sampled every 10 s) |
| 10-min recording + A/V sync (flash+beep every 2 s, `sync-marker.swift`) | PASS | complete, 600.08 s, 34,476 frames; 300/300 flash/beep pairs; offsets first/mid/last 2.5/-14.2/9.8 ms, range -15.2..24.1 ms (frame quantisation 16.7 ms), mean 12.2 ms, **drift 7.3 ms over 10 min**; RSS max 73 MB; package 97 MB |
| kill -9 mid-recording, then `RecordingSession.recover` (`scripts/qa/run-recover-check.sh`) | PASS | 25 s recording, app killed with SIGKILL: package left at status=recording; `interruptedPackages` lists it; `recover` -> status complete, 1 segment, 24.01 s (<= ~1 s tail lost); opens in core (24.01 s); screen.mov decodes with ffmpeg. App-level relaunch prompt (UI) not exercised |
| Interrupted recording tail readable (earlier 7.5-min runs killed externally) | PASS (indirect) | two runs killed by other processes (7.5 min); the partial fragmented MOV was still analyzable: 223/223 pairs, drift 1.3 ms; session stays status=recording (needs RecordingSession.recover, not run) |
| Open real package in core, cut/zoom/padding edits, undo/redo, save/reopen | PASS | testOpenRealRecording (duration 600.083 s == recorded) |
| Export vs preview frame diff (real recording, 720p, t=2 s) | PASS | mean abs luma diff 0.50/255 (threshold 6) |
| Export 1080p of real recording with edits and audio | **PASS after F6 fix** (was FAIL) | main 529f208: 10-min package, cut + zoom + padding + undo/redo + save, export 599.1 s (expected 599.08), 1080p video + audio, 4.3x realtime; reopened project keeps edits; tail diagnostics all OK |
| Window capture via `--capture-selftest --target window:<id>` (200x200 marker window) | PASS | video exactly 200x200, 13 frames/8.2 s (VFR, changes only on flash), luma 16..235 = only that window |
| Area capture via `--capture-selftest --target area:100,100,640,360` | PASS | video exactly 640x360, 350 frames, complete |
| Area capture (`--live-e2e area`) | PASS | 800x500 selection -> video 800x500, 241 frames, complete |
| Window capture (`--live-e2e window`) | PASS (minor F8) | Terminal 1627x1015 pt -> video 1626x1014 (even-size rounding); session.json pixel_size says 1627x1015 |
| Pause/resume (`--live-e2e pause`) | PASS | 2 segments 2.15 s + 1.93 s, pause excluded |
| Default flow via the UI controller (`--live-e2e`: toolbar, 3 s countdown, record 5 s, stop, editor opens, export with audio) | PASS (F6 fixed) | main c504858: editor opened on the new package, export state done (verified by Exporter reopen); earlier run on b5d1268 failed with decode error |
| Toolbar/HUD/countdown excluded from video (`--ui-record-selftest 6`) | PASS | qa viewed frames at 0.4 s (countdown phase) and 4.5 s (recording): none of the Yapcam windows visible; frames deleted (they show the desktop) |
| Pause + resume with A/V sync (`--capture-selftest 24 --pause-after 10` with sync-marker) | PASS | 2 segments (10.18 s, 14.02 s); 12/12 flash/beep pairs, offsets 4.1/15.2/6.9 ms first/mid/last, drift 2.8 ms |
| Scripted input vs events.jsonl (`--drive-input-selftest 10`, all permissions granted, launched with `open -n -W`) | PASS | 38 scripted events (34 moves, 4 clicks) all found; time error events.t - sent hostNs: min 0.40 / max 15.43 / mean 2.33 ms; position error max 0.98 pt; down=4 up=4 (`scripts/qa/compare-input.py`) |
| Cursor + click -> auto zoom -> export (same recording, `LiveRecordingTests.testAutoZoomFromRealClicks`) | PASS | 4 clicks -> 4 auto zooms (x2.0, 1.3 s, start 0.3-0.4 s before click), target = click point exactly; frame crop narrower mid-zoom; export 10.2 s video+audio |
| Source disappears (target window closed 6 s into a 12 s window recording) | PASS for capture; **recovery of window packages FAIL (F9)** | state failed(sourceUnavailable), package kept with status interrupted and 5.79 s of media; `recover` finalizes, but core cannot open any window package: `missing field display_name` |
| Completed window recording opens in core | **PASS after F9 fix** (was FAIL; retested on main badc4e4: session now has display_name, opens, edit+export 1080p with audio OK) |  (original failure: `Project.create` on a complete `--target window` package: `status(2, "missing field `display_name`")`; area and display packages open fine |
| Editor UI sequence via real menu/model actions (`--editor-selftest`): split, delete clip, add zoom, padding, undo/redo | PASS | clips 1->2->1, duration 8085 -> 2695 ms, zoom added, padding 48->72, undo/redo 72->48->72 |
| Source overlay + Start (`--drive-input-selftest 12 --source display`, main c1bf553) | PASS | overlay shown (1 window), recording started on Start, overlay gone while recording, stop -> package complete 12.19 s, editor opened; default countdown 0 (None) |
| Editor opens in front after Stop | **PASS after F10 fix** (was FAIL) | `--ui-record-selftest 5 --source display` on main 3dd0d3b: `editorOpened=true editorInFront=true` (LiveEngine.openEditor -> EditorBridge.bringEditorsToFront) |
| Scripted input on the new build | PASS | 47/47 events, time error 0.27-8.67 ms (mean 1.95), position <= 0.98 pt, 5 clicks down+up |
| Auto-zoom rule on a real recording (5 clicks every 2 s) | PASS | one merged range 2.176-11.390 s = first click -300 ms to duration -0.8 s, x2.0, auto, target = click point |
| Area / window / pause on the redesigned controller (`--live-e2e area|window|pause`) | PASS | 800x500 video; window video 1626x1014 with session pixel_size [1626,1014] (F8 fixed); pause 2.17 s + 1.85 s |
| Export option sets (library, `ExportOptionSetsTests`, 5 tests) | PASS | catalogs/defaults/quantisers, default MP4 h264 720p 60 fps, Both = paired h264 + hevc files, GIF 480p HQ and play-once (loop count 1 vs 0) |
| Copy to clipboard (library) | PASS | exported FILE on a private pasteboard, previous-exports list, missing file rejected |
| Inspector order and Cmd+1..0 (editor Swift Testing, model level) | PASS | InspectorSectionOrderTests / ReferenceAlignmentTests pass; no physical key presses |
| Reference hotkey layout, live | **BLOCKED: no in-app hook** | the existing `--live-e2e hotkey` scenario still uses the OLD API (`settings.startStopShortcut`, hardcoded Option-Command flags): it cannot press the new table (start Ctrl-Cmd-Return, display/window/area Opt-Cmd-3/4/5, pause Opt-Cmd-P, restart Opt-Cmd-Backspace). Needs ui hook `--hotkey-selftest` (see Requests). A second Yapcam instance of the main checkout also registers the same global hotkeys: collision risk |
| After-recording choices (create project / export+copy / export+save) and quick-export widget, live | **BLOCKED: no in-app hook** | `--ui-record-selftest` always uses the default (create project); needs `--after-recording create|copy|save [--quick-widget]` that sets the choice and logs the clipboard file URL / saved file and widget state. Library-level clipboard and export verified |
| Autosave then kill (exit 9) then reopen (`--editor-selftest --crash-after-autosave` + `--editor-reopen-check`) | PASS | save state clean before crash; reopened with clips=1 zooms=1 duration 2695 ms padding 72 |
| Kill with only the journal (`--crash-now` + reopen check) | PASS | unsavedJournalPresent=true; restore path recovers clips=1 zooms=1 padding 72 (state dirty = unsaved restore) |
| Editor export via the export model (`--editor-export-selftest`) | PASS | 1920x1080, 2.700 s (project 2.695 s), 1 audio track |
| Hotkey-driven recording (`--live-e2e hotkey`) | PASS | start, pause (paused), resume (recording), stop (idle); package complete |
| Odd-size window 201x151 (F8 re-check) | PASS | session pixel_size [200,150] == screen.mov 200x150; recording/.capture.lock removed after the clean finish |
| Permission revoked / low disk (live) | NOT RUN by design | no TCC reset, no disk filling; capture injected-fault tests cover both (SessionLifecycleTests, SegmentFailureTests) |

## 5. Performance (Apple M4, debug build unless noted)
| Metric | Value | Source |
|---|---|---|
| Export 1080p30, real 10-min recording with audio and edits | 599.1 s output in 138 s = **4.3x realtime** | qa, LiveRecordingTests |
| Export 1080p / 4K, synthetic source, 60 frames, no audio | 6.3x / 1.9x realtime | full-suite RENDER_BENCHMARK, 12:30 |
| Export 10-min synthetic with audio (render team) | 4.4x realtime, peak RSS 137 MB, A/V offset <0.05 ms | docs/STATUS.md |
| Export 30-min soak | 2.2x realtime, RSS growth -2.5 MB (no leak) | docs/STATUS.md |
| Preview with audio, 30 s | 1080p 58.3 fps, 4K 58.9 fps | docs/STATUS.md |
| Scrub latency (real window + Metal view) | median 16.5 ms, p95 20 ms | editor LiveWindowTests |
| Recording app memory | RSS flat 72-73 MB over 4 and 10 min | qa sampling every 10 s |
| Recording size / write rate | 97 MB for 10 min (static desktop plus a flashing square) = about 0.16 MB/s | qa |
| Recording frame rate | VFR HEVC, 57.5 fps average over 600 s (static desktop), 34,476 frames | qa |
| Scripted input latency | events.jsonl timestamp - delivery: mean 2.3 ms, max 15.4 ms | qa |
Not measured: real busy-screen content (static desktop only), release-build speed, thermal behaviour, 4K recording, disk write under load.

## 6. Feature matrix
From docs/FEATURES.md (113 rows): verified 38, integrated 47, implemented 18, limited 10, todo 0. Delta since the first audit (81 todo): all rows moved; live verification added REC-01/02/03/06/08/09/10/11/18, AUD-01, CUR-01/02, ZOM-01, EXP-08/01.

## 7. Findings
| ID | Severity | Owner | Repro | Status |
|---|---|---|---|---|
| F9 | HIGH (FIXED, verified on badc4e4) | capture + core | `--capture-selftest 6 --target window:<id>` then open the package in core (`YAPCAM_LIVE_PACKAGE=<pkg> swift test --filter LiveRecordingTests/testOpenRealRecording`) -> `missing field display_name` | open |
| F6 | HIGH | render + core | export real recording with audio over the final ~100 ms | fixed, verified on main 529f208+ (10-min export, UI default flow) |
| F8 | LOW | capture | window recording: session.json pixel_size 1627x1015, video 1626x1014 | fixed in 3b68bde, verified (201x151 window -> [200,150]) |
| F7 | MEDIUM | process | other processes killed two long runs | resolved by .app-lock rule |
| F10 | LOW | ui | after Stop the editor was not in front | fixed, verified on 3dd0d3b |
| F4 | LOW | editor | privacy-scan flags an absolute home path in docs/status/editor.md | open |
Details and repros: docs/status/qa.md.

## 8. Reference observation (morning session with the user)
Checklist of Screen Studio panels/menus to observe, values captured, rows updated.

## 9. Not tested / limitations
Link docs/KNOWN_LIMITATIONS.md; list anything new.

## 10. Privacy and licence
Scan results (`scripts/qa/privacy-scan.sh`), THIRD_PARTY.md (approved) and THIRD_PARTY_NOTICES.md status, confirmation that no reference assets are included.

## Update log (keep current with each Lead integration)
| Date | Main | What changed in this report |
|---|---|---|
| 2026-10-15 | b90ee0d | Structure only; Metal 86/86, M3 long-export/soak, fresh-checkout build recorded in docs/STATUS.md; live capture still blocked (TCC) |
| 2026-10-15 19:55 | 3dd0d3b | F10 verified fixed (editor in front after Stop); hotkey and after-recording live checks blocked on missing in-app hooks |
| 2026-10-15 19:45 | c1bf553 | Live DoD re-run on the integrated gap list: overlay+Start, scripted input, auto-zoom rule, area/window/pause, export option sets, clipboard, inspector order PASS; F10 editor not in front (low); hotkeys and after-recording buttons not run live |
| 2026-10-15 14:00 | badc4e4 | F9 fixed and verified (window package opens, edit+export OK); default live flow still OK after ui/editor redesigns |
| 2026-10-15 13:00 | 511f831 | F9 retested: still fails; only the decision doc is on main |
| 2026-10-15 12:40 | 3b68bde | Final handover pass: suites re-run (Swift 340 + XCTest 129, Rust 68), editor UI rows PASS (autosave/kill/reopen, export), hotkeys PASS, F8 verified fixed, F9 still open |
| 2026-10-15 12:30 | fc29d18 | Permissions granted: scripted input vs events PASS (max 15 ms / 0.98 pt), auto-zoom from real clicks PASS |
| 2026-10-15 12:00 | 529f208 | F6 fixed and re-verified (10-min export with audio); window/area via selftest targets PASS; pause A/V, toolbar exclusion PASS; scripted input BLOCKED on Accessibility |
| 2026-10-15 11:10 | b5d1268 | Section 4 filled with live results (display, 4/10-min, A/V sync, export diff, F6 tail-export failure) |
| 2026-10-15 | 7d545a1 | Editor export sheet now exposes MP4/MOV/GIF, 4K, 24 fps, quality (EXP-02/04 integrated); no new test results by qa |
